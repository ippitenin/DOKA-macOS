import Combine
import Foundation

/// Библиотека файловых транскрибаций (бывшие «Недавние»): индекс записей в
/// памяти поверх файлового слоя `TranscriptLibraryFiles`. Намеренно ОТДЕЛЬНА
/// от `HistoryStore` диктовки — пайплайны изолированы (инвариант проекта).
///
/// В памяти — только индекс (`records`); тела (сегменты, слова, анализы)
/// лежат по файлу на запись и читаются лениво, с маленьким LRU-кэшем. Лимита
/// по количеству нет: вытеснение в библиотеке — тихая потеря данных; остаётся
/// только срок хранения, который выбирает пользователь.
@MainActor
final class TranscriptHistoryStore: ObservableObject {
    static let shared = TranscriptHistoryStore(dataFolder: AppDataFolder.currentURL)

    /// Срок жизни результата async-задачи на сервере Nexara: после него
    /// добирать нечего (результат удалён безвозвратно). nonisolated — его
    /// читает чистый `RetryPlanner`.
    nonisolated static let serverResultLifetime: TimeInterval = 12 * 3_600

    @Published private(set) var records: [FileTranscriptRecord] = []
    /// Запись завершилась (готово или ошибка, которую пользователь ждал) —
    /// единая точка для уведомлений: путь контроллера, добор после
    /// перезапуска и повторный опрос.
    let finished = PassthroughSubject<FileTranscriptRecord, Never>()
    /// Тело записи изменилось (правки, анализы) — открытые документы
    /// перечитывают его.
    let bodyChanged = PassthroughSubject<UUID, Never>()

    let files: TranscriptLibraryFiles
    private var migratedFromV1: Bool
    /// Задачи добора результатов по id записи — удаление записи отменяет опрос.
    private var recoveryTasks: [UUID: Task<Void, Never>] = [:]
    /// Архивация исходного звука — принадлежит стору, а не задаче
    /// распознавания: отмена распознавания её не убивает (иначе «Повторить»
    /// было бы не из чего), удаление записи — убивает.
    private var audioTasks: [UUID: Task<Void, Never>] = [:]
    private var bodyCache: [UUID: TranscriptBody] = [:]
    private var bodyCacheOrder: [UUID] = []
    /// После переноса «Папки данных» до перезапуска библиотека ничего не
    /// меняет: стор держит старый путь, а старая папка уже удалена.
    private(set) var isFrozen = false
    private static let bodyCacheLimit = 3

    /// Полнотекстовый поиск: тексты читаются лениво из `text.txt`.
    private(set) lazy var textIndex = TranscriptTextIndex(loader: { [files] id in files.readText(id) })

    /// Загрузка синхронная: `prune`/`resumePendingJobs` в AppDelegate идут
    /// сразу после и должны видеть полный список. Internal ради тестов.
    init(dataFolder: URL) {
        files = TranscriptLibraryFiles(dataFolder: dataFolder)
        let outcome = files.loadOrMigrate()
        records = outcome.records
        migratedFromV1 = outcome.migratedFromV1
        if outcome.indexChanged {
            files.writeIndex(records, migratedFromV1: migratedFromV1)
        }
    }

    // MARK: - Чтение

    func record(_ id: UUID) -> FileTranscriptRecord? {
        records.first { $0.id == id }
    }

    /// Тело из кэша без обращения к диску (свежий результат, только что открытая запись).
    func cachedBody(_ id: UUID) -> TranscriptBody? {
        bodyCache[id]
    }

    func loadBody(_ id: UUID) async -> TranscriptBody? {
        if let cached = bodyCache[id] {
            touchCache(id)
            return cached
        }
        guard let body = await files.readBody(id) else { return nil }
        // Запись могли удалить, пока тело читалось.
        guard record(id) != nil else { return nil }
        cache(body, for: id)
        return body
    }

    /// Архив звука записи, если он есть на диске.
    func audioURL(for id: UUID) -> URL? {
        files.existingAudioURL(id)
    }

    /// В библиотеке есть записи, перенесённые из журнала v1 («Недавних» со
    /// сроком 12 ч), — для однократной плашки «записи теперь хранятся всегда».
    /// Признак — отсутствие `params`: новые записи создаются только с ними.
    /// Флаг индекса `migratedFromV1` не годится: он ставится и тогда, когда
    /// журнала не было вовсе (новая установка).
    var hasRecordsFromV1: Bool { records.contains { $0.params == nil } }

    /// Идёт ли фоновая работа с файлами библиотеки (архивация, добор):
    /// перенос «Папки данных» в это время блокируется.
    var hasBackgroundWork: Bool {
        !recoveryTasks.isEmpty || !audioTasks.isEmpty
    }

    func librarySize() async -> (total: Int64, audio: Int64) {
        await files.librarySize()
    }

    /// id → сниппет совпадения по полному тексту готовых записей.
    func searchFullText(_ query: String) async -> [UUID: String] {
        let ids = records.filter(\.isDone).map(\.id)
        return await textIndex.search(query, among: ids)
    }

    // MARK: - Жизненный цикл записи

    /// Параметры новой записи.
    struct PendingDraft {
        var fileName: String
        var provider: String
        var title: String?
        var params: FileTranscriptionParams?
        var sourcePath: String?
        var parentID: UUID?
    }

    @discardableResult
    func addPending(_ draft: PendingDraft) -> UUID {
        let record = FileTranscriptRecord(
            id: UUID(), fileName: draft.fileName, date: Date(), status: .inProgress,
            provider: draft.provider, title: draft.title, sourcePath: draft.sourcePath,
            params: draft.params, parentID: draft.parentID)
        records.insert(record, at: 0)
        persist(record)
        return record.id
    }

    /// «Повторить» на месте: та же запись снова в работе. Сервис и параметры
    /// — сохранённые (или новые, если вызывающий их передал). `sourcePath` —
    /// новый путь исходника, если пользователь выбрал файл заново; nil —
    /// прежний (повтор из оригинала или из архива звука). `date` не меняется:
    /// запись остаётся в своей группе списка.
    func restartPending(_ id: UUID, provider: String, params: FileTranscriptionParams?,
                        sourcePath: String? = nil) {
        update(id) {
            $0.status = .inProgress
            $0.jobID = nil
            $0.submittedAt = nil
            $0.failure = nil
            $0.provider = provider
            if let params { $0.params = params }
            if let sourcePath { $0.sourcePath = sourcePath }
        }
    }

    /// job_id персистится сразу после сабмита: если приложение умрёт во время
    /// опроса, задача доберётся на следующем старте. От этого момента же
    /// отсчитывается дедлайн 12 ч.
    func setJobID(_ id: UUID, jobID: String) {
        update(id) {
            $0.jobID = jobID
            $0.submittedAt = Date()
        }
    }

    /// Готовый результат → тело записи. Анализ Nexara из того же запроса
    /// становится первым анализом записи (источник правды анализов —
    /// `TranscriptBody.analyses`). Возвращает тело; nil — записи уже нет.
    @discardableResult
    func markDone(_ id: UUID, result: TranscriptResult) -> TranscriptBody? {
        guard let record = record(id) else { return nil }
        var analyses: [StoredAnalysis] = []
        if let llm = result.llmOutput, !llm.isEmpty {
            let preset = record.params?.llmPresetValue
            analyses.append(StoredAnalysis(
                title: preset.map(\.title) ?? L("transcribe.llm.result.title"),
                templateID: preset.map { "nexara.\($0.rawValue)" },
                source: .nexara, markdown: llm))
        }
        let body = TranscriptBody(transcript: StoredTranscript(result).withoutLLMOutput,
                                  analyses: analyses)
        writeBody(body, for: id)
        update(id) {
            $0.status = .done
            $0.result = nil
            $0.language = result.language
            $0.duration = result.duration
            $0.failure = nil
            $0.summary = RecordSummary.make(from: body)
        }
        if let done = self.record(id) { finished.send(done) }
        return body
    }

    /// Ошибка записи. `notify == false` — для безнадёжных записей, погашенных
    /// на старте: пользователь не ждал их в этой сессии, уведомлять не о чем.
    func markError(_ id: UUID, message: String, failure: FailureKind, notify: Bool = true) {
        guard record(id) != nil else { return }
        update(id) {
            $0.status = .error(message)
            $0.failure = failure
        }
        if notify, let failed = record(id) { finished.send(failed) }
    }

    func markError(_ id: UUID, error: Error, notify: Bool = true) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        markError(id, message: message, failure: FailureKind.classify(error), notify: notify)
    }

    /// Отмена осмысленна только для выполняющейся записи: готовую/ошибочную
    /// не трогаем (гонка «задача завершилась в момент отмены»). jobID
    /// сохраняется — «Повторить» заберёт результат без повторной оплаты.
    func markCancelled(_ id: UUID) {
        update(id) {
            guard $0.status == .inProgress else { return }
            $0.status = .cancelled
        }
    }

    func rename(_ id: UUID, title: String?) {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        update(id) { $0.title = (trimmed?.isEmpty ?? true) ? nil : trimmed }
    }

    /// Сохранить изменённое тело (правки, анализы): кэш, сводка, текст для
    /// поиска и файлы — одним вызовом. Коммитить по завершённому действию,
    /// а не на каждое нажатие клавиши.
    func saveBody(_ id: UUID, _ body: TranscriptBody) {
        guard record(id) != nil else { return }
        writeBody(body, for: id)
        update(id) {
            $0.summary = RecordSummary.make(from: body)
            $0.updatedAt = Date()
        }
        bodyChanged.send(id)
    }

    func delete(_ id: UUID) { delete([id]) }

    func delete(_ ids: Set<UUID>) {
        guard !isFrozen else { return }
        let existing = ids.filter { record($0) != nil }
        guard !existing.isEmpty else { return }
        for id in existing {
            recoveryTasks.removeValue(forKey: id)?.cancel()
            audioTasks.removeValue(forKey: id)?.cancel()
            bodyCache[id] = nil
            bodyCacheOrder.removeAll { $0 == id }
        }
        records.removeAll { existing.contains($0.id) }
        // Сначала корзина (атомарный rename), потом индекс: крэш между ними
        // оставит в индексе запись без папки — её отбросит сверка на старте.
        files.trash(Array(existing))
        files.writeIndex(records, migratedFromV1: migratedFromV1)
        // Стирание — после индекса: kill посреди него не вернёт записи.
        files.emptyTrash()
        let index = textIndex
        Task { await index.remove(existing) }
    }

    /// Завершённые записи старше срока — удалить. Выполняющиеся не трогаем:
    /// их судьбу решает добор/опрос.
    func prune(retention: TranscriptRetention) {
        let expired = Self.expiredIDs(records, retention: retention, now: Date())
        if !expired.isEmpty { delete(expired) }
    }

    nonisolated static func expiredIDs(_ records: [FileTranscriptRecord],
                                       retention: TranscriptRetention, now: Date) -> Set<UUID> {
        guard let hours = retention.hours else { return [] }
        let cutoff = now.addingTimeInterval(-Double(hours) * 3_600)
        return Set(records.filter { $0.date < cutoff && $0.status != .inProgress }.map(\.id))
    }

    // MARK: - Исходный звук

    /// Архивировать звук источника в папку записи (m4a 16 кГц mono). Работа
    /// фоновая; результат фиксируется, только если запись к тому моменту жива.
    func archiveAudio(_ id: UUID, from source: URL) {
        // Заморожено: синхронное создание папки ниже прошло бы мимо очереди
        // и воскресило бы удалённую переносом старую папку данных.
        guard !isFrozen, record(id) != nil else { return }
        // Архивация этой записи уже идёт («Повторить» сразу после быстрой
        // ошибки) — пусть доделывает: два кодировщика в один `.part` стёрли бы
        // друг другу файл (архиватор удаляет его при отмене).
        guard audioTasks[id] == nil else { return }
        // Папку создаём сразу: meta пишется очередью асинхронно, а архиватор
        // начнёт писать .part немедленно.
        try? FileManager.default.createDirectory(at: files.folder(for: id),
                                                 withIntermediateDirectories: true)
        let part = files.audioPartURL(id)
        audioTasks[id] = Task { [weak self] in
            do {
                _ = try await SourceAudioArchiver.archive(source: source, to: part)
                guard let self, !Task.isCancelled else { return }
                if await self.files.commitAudio(id) {
                    self.update(id) { $0.audioFileName = TranscriptLibraryFiles.audioFileName }
                }
            } catch {
                if !(error is CancellationError) {
                    NSLog("DOKA: архив звука записи не создан: \(error.localizedDescription)")
                }
                try? FileManager.default.removeItem(at: part)
            }
            // Отменённую задачу из реестра убрал отменивший (удаление,
            // стирание аудио, заморозка) — её место может занимать уже новая.
            guard !Task.isCancelled else { return }
            self?.audioTasks[id] = nil
        }
    }

    /// Архив для «Распознать заново»: копия звука исходной записи (на APFS —
    /// мгновенный clonefile), а не повторное кодирование: перекодирование
    /// AAC → AAC только теряло бы качество. Задача стора, как `archiveAudio`:
    /// её видит `hasBackgroundWork`, удаление записи её отменяет.
    func inheritAudio(_ id: UUID, from parent: UUID) {
        guard !isFrozen, record(id) != nil, audioTasks[id] == nil else { return }
        audioTasks[id] = Task { [weak self] in
            guard let self else { return }
            let cloned = await self.files.cloneAudio(from: parent, to: id)
            // Отменённую задачу из реестра убрал отменивший (см. archiveAudio).
            guard !Task.isCancelled else { return }
            if cloned {
                self.update(id) { $0.audioFileName = TranscriptLibraryFiles.audioFileName }
            }
            self.audioTasks[id] = nil
        }
    }

    /// Стереть звук одной записи (меню записи): расшифровка и анализы остаются.
    func removeAudio(_ id: UUID) {
        guard !isFrozen, record(id) != nil else { return }
        // Идущая архивация иначе закоммитила бы файл уже после стирания.
        audioTasks.removeValue(forKey: id)?.cancel()
        RecordingPlayer.shared.stopIfCurrent(id)
        files.removeAudio([id])
        update(id) { $0.audioFileName = nil }
    }

    /// «Стереть всё аудио транскрибаций»: тексты и анализы остаются.
    func removeAllAudio() {
        for task in audioTasks.values { task.cancel() }
        audioTasks.removeAll()
        if let playing = RecordingPlayer.shared.currentRecordID, record(playing) != nil {
            RecordingPlayer.shared.stop()
        }
        files.removeAudio(records.map(\.id))
        for index in records.indices where records[index].audioFileName != nil {
            records[index].audioFileName = nil
            files.writeMeta(records[index])
        }
        files.writeIndex(records, migratedFromV1: migratedFromV1)
    }

    // MARK: - Перенос папки данных

    /// Дождаться записи всего поставленного в очередь (перед переносом папки).
    func flush() { files.flush() }

    /// После переноса «Папки данных» — никаких записей до перезапуска.
    func freeze() {
        isFrozen = true
        for task in recoveryTasks.values { task.cancel() }
        for task in audioTasks.values { task.cancel() }
        recoveryTasks.removeAll()
        audioTasks.removeAll()
        files.freeze()
    }

    // MARK: - Добор после перезапуска и повторный опрос

    /// Добор незавершённых задач; один вызов на старте (AppDelegate).
    /// Sync-записи без jobID безнадёжны — запрос умер вместе с процессом;
    /// async-задачи старше 12 ч истекли на сервере; остальные опрашиваются
    /// в фоне, результат попадает только в стор (пользователь открывает
    /// запись из библиотеки). Безнадёжные гасятся без уведомлений.
    func resumePendingJobs() {
        let pending = records.filter { $0.status == .inProgress }
        guard !pending.isEmpty else { return }

        let now = Date()
        var recoverable: [(id: UUID, jobID: String, deadline: Date)] = []
        for record in pending {
            guard let jobID = record.jobID else {
                markError(record.id, message: L("transcribe.async.interrupted"),
                          failure: .interrupted, notify: false)
                continue
            }
            let deadline = Self.pollDeadline(for: record)
            guard now < deadline else {
                markError(record.id, message: L("transcribe.async.jobNotFound"),
                          failure: .expired, notify: false)
                continue
            }
            recoverable.append((record.id, jobID, deadline))
        }
        startPolling(recoverable)
    }

    /// Можно ли забрать результат с сервера без повторной отправки файла —
    /// правило одно, у планировщика «Повторить».
    func canRepoll(_ record: FileTranscriptRecord) -> Bool {
        RetryPlanner.canRepoll(record, now: Date())
    }

    /// «Повторить» без повторной оплаты: отмена у Nexara лишь прекращала
    /// опрос — сервер задачу дообработал, результат забираем.
    func repoll(_ id: UUID) {
        guard !isFrozen, let record = record(id), canRepoll(record),
              let jobID = record.jobID else { return }
        update(id) {
            $0.status = .inProgress
            $0.failure = nil
        }
        startPolling([(id, jobID, Self.pollDeadline(for: record))])
    }

    /// Остановить добор/повторный опрос записи (кнопка «Отмена» у записи,
    /// которую добирают не через контроллер). Как и отмена в контроллере,
    /// запись остаётся «Отменена» с jobID — забрать результат можно позже.
    func cancelRecovery(_ id: UUID) {
        recoveryTasks.removeValue(forKey: id)?.cancel()
        markCancelled(id)
    }

    private static func pollDeadline(for record: FileTranscriptRecord) -> Date {
        RetryPlanner.repollDeadline(for: record)
    }

    /// Опрос задач Nexara. Credentials — всегда builtin, а не текущего
    /// сервиса: async-задача — нексаровская, даже если пользователь уже
    /// переключился на свой пресет.
    private func startPolling(_ items: [(id: UUID, jobID: String, deadline: Date)]) {
        guard !items.isEmpty, let endpoint = TranscriptionProvider.builtin.endpoint else { return }
        let config = ProviderConfig(endpoint: endpoint,
                                    model: TranscriptionProvider.builtin.defaultModel)
        Task { [weak self] in
            // Ключ читается лениво и ВНЕ главного потока: Keychain может
            // показать диалог подтверждения (например, после пересборки с
            // новой подписью), и синхронное чтение заморозило бы приложение.
            let apiKey = await Task.detached { KeychainHelper.getAPIKey(for: .builtin) }.value
            guard let self, !self.isFrozen else { return }
            // Пока читался ключ (диалог доступа к Keychain может висеть долго),
            // записи могли отменить или удалить — их не опрашиваем и не трогаем.
            let items = items.filter { self.isAwaitingResult($0.id) }
            guard let apiKey else {
                for item in items {
                    self.markError(item.id, message: L("error.noAPIKey"), failure: .auth, notify: false)
                }
                return
            }
            var startDelay: TimeInterval = 0
            for item in items {
                let delay = startDelay
                startDelay += 0.5   // стаггер стартов: лимит Nexara — 10 запросов/с
                self.recoveryTasks[item.id]?.cancel()
                self.recoveryTasks[item.id] = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(delay))
                    guard !Task.isCancelled else { return }
                    let outcome: Result<TranscriptResult, Error>
                    do {
                        // Детализация не важна: в тело уходят только
                        // rawSegments/words, нарезка выполняется при открытии.
                        outcome = .success(try await FileTranscriptionClient().waitForResult(
                            jobID: item.jobID, apiKey: apiKey, config: config,
                            detail: .server, deadline: item.deadline))
                    } catch {
                        outcome = .failure(error)
                    }
                    // Отменённую задачу из реестра убрал отменивший (удаление,
                    // «Отмена», повторный опрос, заморозка) — её место может
                    // занимать уже новая.
                    guard let self, !Task.isCancelled else { return }
                    self.recoveryTasks[item.id] = nil
                    // Запись, отменённую раньше регистрации задачи, не «воскрешаем».
                    guard self.isAwaitingResult(item.id) else { return }
                    switch outcome {
                    case .success(let result): self.markDone(item.id, result: result)
                    case .failure(let error): self.markError(item.id, error: error)
                    }
                }
            }
        }
    }

    // MARK: - Служебное

    private func isAwaitingResult(_ id: UUID) -> Bool {
        record(id)?.status == .inProgress
    }

    /// Точечное изменение записи; no-op, если записи уже нет (пользователь
    /// удалил её, пока задача завершалась).
    private func update(_ id: UUID, _ mutate: (inout FileTranscriptRecord) -> Void) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        var record = records[index]
        mutate(&record)
        guard record != records[index] else { return }
        records[index] = record
        persist(record)
    }

    private func persist(_ record: FileTranscriptRecord) {
        files.writeMeta(record)
        files.writeIndex(records, migratedFromV1: migratedFromV1)
    }

    private func writeBody(_ body: TranscriptBody, for id: UUID) {
        cache(body, for: id)
        files.writeBody(body, id: id)
        let text = body.plainText
        files.writeText(text, id: id)
        let index = textIndex
        Task { await index.update(id, text: text) }
    }

    private func cache(_ body: TranscriptBody, for id: UUID) {
        bodyCache[id] = body
        touchCache(id)
        while bodyCacheOrder.count > Self.bodyCacheLimit {
            let evicted = bodyCacheOrder.removeFirst()
            bodyCache[evicted] = nil
        }
    }

    private func touchCache(_ id: UUID) {
        bodyCacheOrder.removeAll { $0 == id }
        bodyCacheOrder.append(id)
    }
}
