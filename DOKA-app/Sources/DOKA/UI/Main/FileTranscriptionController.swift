import Combine
import SwiftUI

/// Режим разметки ролей на странице «Транскрибация» (UI поверх `RolesSpec`).
enum RolesMode: String, CaseIterable, Identifiable {
    case off, auto, custom

    var id: String { rawValue }
    var title: String { L("transcribe.roles.\(rawValue)") }
}

/// Пресеты LLM-анализа расшифровки. Тексты промптов — ключи Localizable.strings:
/// промпт следует языку интерфейса, включая язык ответа модели.
enum LLMAnalysisPreset: String, CaseIterable, Identifiable {
    case off, meetingMinutes, summary, actionItems, custom

    var id: String { rawValue }
    var title: String { L("transcribe.llm.preset.\(rawValue)") }

    /// Готовый промпт пресета; off и custom промпта не имеют.
    var promptTemplate: String? {
        switch self {
        case .off, .custom: return nil
        case .meetingMinutes, .summary, .actionItems:
            return L("transcribe.llm.prompt.\(rawValue)")
        }
    }
}

/// Состояние страницы «Транскрибация»: выбор файла, прогресс, результат.
/// Полностью изолирован от пайплайна диктовки — не пишет в историю,
/// статистику и словарь, не вставляет текст в активное приложение.
@MainActor
final class FileTranscriptionController: ObservableObject {
    /// Синглтон: результат и выбранный файл переживают пересоздание вью при
    /// переключении секций (`MainWindowView` рендерит контент с `.id(section)`)
    /// и живут до закрытия приложения.
    static let shared = FileTranscriptionController()

    private let store = TranscriptHistoryStore.shared
    private var cancellables = Set<AnyCancellable>()
    private var documentCancellable: AnyCancellable?

    private init() {
        // Показанную запись удалили (срок хранения, удаление из списка) —
        // скрываем результат, а не показываем карточки несуществующей записи.
        // @Published отдаёт новое значение параметром (willSet).
        store.$records
            .sink { [weak self] records in
                guard let self, let id = self.shownRecordID,
                      !records.contains(where: { $0.id == id }) else { return }
                self.hideResult()
            }
            .store(in: &cancellables)
    }

    enum Phase: Equatable {
        case idle
        case picked(name: String, sizeBytes: Int64)
        case transcribing
        /// Показана запись библиотеки: результат живёт в ней (единственный
        /// источник), а не копией в фазе — правки и анализы видны сразу.
        case done(recordID: UUID)
        case error(String)
    }

    /// Куда писать результат запуска.
    enum Target: Equatable {
        /// Новая запись (для «Распознать заново» — с исходной записью и заголовком).
        case new(parentID: UUID?, title: String?)
        /// «Повторить» на месте: та же запись снова в работе.
        case reuse(UUID)
    }

    @Published private(set) var phase: Phase = .idle {
        didSet { syncShownDocument() }
    }
    /// Документ показанной записи (при `phase == .done`); его изменения
    /// пробрасываются в `objectWillChange` контроллера — страница, наблюдающая
    /// контроллер, перерисовывается, когда тело догрузилось или изменилось.
    @Published private(set) var shownDocument: TranscriptDocument?
    /// Под-статус длинной операции («Разделение по спикерам… 40 %»):
    /// локальная диаризация идёт минутами, неподвижный спиннер выглядел бы
    /// зависанием. nil — показывается обычный текст прогресса.
    @Published private(set) var progressNote: String?
    /// Разделение по спикерам. У встроенного сервиса — серверное (task=diarize),
    /// у остальных — локальный диаризатор на этом Mac.
    /// По умолчанию выключено: дороже и медленнее.
    @Published var diarize = false {
        didSet {
            guard diarize != oldValue else { return }
            ensureDiarizerModel()
        }
    }
    /// Язык распознавания страницы. По умолчанию — как у диктовки, но меняется
    /// независимо (в общие настройки не пишем — это локальный выбор страницы).
    @Published var language: String = SettingsStore.shared.language
    /// Подсказка о числе говорящих. nil — авто. Работает и у Nexara
    /// (`num_speakers`), и у локального диаризатора (точное число кластеров).
    @Published var numSpeakers: Int? = nil
    /// Тип записи для диаризации (только Nexara).
    @Published var diarizationSetting: DiarizationSetting = .general
    /// Детализация тайм-кодов. Нарезка локальная: показанная запись
    /// перенарезается документом сразу, без повторного запроса.
    @Published var timestampDetail: TimestampDetail = .medium
    /// Разметка ролей (только Nexara, только с диаризацией).
    @Published var rolesMode: RolesMode = .off
    /// Свой список ролей: имена через запятую («Клиент, Агент»).
    @Published var rolesText: String = ""
    /// LLM-анализ расшифровки (только Nexara).
    @Published var llmPreset: LLMAnalysisPreset = .off
    /// Свой промпт анализа (llmPreset == .custom).
    @Published var llmCustomPrompt: String = ""

    /// Параметры страницы снимком — ровно то, что уйдёт в запрос и в запись
    /// библиотеки (по ним работают «Повторить» и «Распознать заново»).
    var pageParams: FileTranscriptionParams {
        FileTranscriptionParams(providerID: SettingsStore.shared.providerID,
                                language: language,
                                diarize: diarize,
                                numSpeakers: numSpeakers,
                                diarizationSetting: diarizationSetting.rawValue,
                                rolesMode: rolesMode.rawValue,
                                rolesText: rolesText,
                                llmPreset: llmPreset.rawValue,
                                llmCustomPrompt: llmCustomPrompt)
    }

    /// Ошибка валидации своего списка ролей; nil — всё валидно.
    /// Не-nil блокирует запуск (кнопка задизейблена в UI).
    var rolesValidationMessage: String? { pageParams.rolesValidationMessage }

    /// Nexara-специфичные параметры (diarization_setting, роли, LLM-анализ)
    /// доступны только встроенному сервису: у кастомных OpenAI-совместимых
    /// API таких полей нет, строгий сервер ответит 400.
    var isBuiltinService: Bool { pageParams.isBuiltin }

    /// Разделение по спикерам считается на этом Mac: у локальных моделей
    /// сервера нет вовсе, у пользовательских OpenAI-совместимых сервисов
    /// диаризации нет в API. Ровно этот случай требует модели диаризатора.
    var usesLocalDiarization: Bool { pageParams.usesLocalDiarization }

    /// Диаризация включена, но модель ещё не скачана — запускать нельзя.
    var isDiarizerModelMissing: Bool {
        usesLocalDiarization && !LocalModelStore.shared.isDownloaded(.diarizer)
    }

    /// Ставит модель диаризатора в очередь скачивания, если она нужна и её
    /// нет. Вызывается при включении тумблера и при смене сервиса; повторные
    /// вызовы безопасны (идущая загрузка и готовая модель — no-op).
    func ensureDiarizerModel() {
        guard usesLocalDiarization else { return }
        Self.requestDiarizerModel()
    }

    private static func requestDiarizerModel() {
        if case .notDownloaded = LocalModelStore.shared.state(for: .diarizer) {
            LocalModelStore.shared.download(.diarizer)
        }
    }

    private var pickedURL: URL?
    private var task: Task<Void, Never>?
    /// Запись библиотеки, которая распознаётся прямо сейчас.
    private(set) var runningRecordID: UUID?

    /// Показанная запись библиотеки.
    var shownRecordID: UUID? {
        if case let .done(id) = phase { return id }
        return nil
    }

    /// Поддерживаемые форматы (белый список Nexara) — источник правды для drop,
    /// диалога выбора и валидации.
    static let audioExtensions = ["wav", "mp3", "m4a", "flac", "ogg", "opus", "aiff", "asf"]
    static let videoExtensions = ["mp4", "mov", "avi", "mkv"]
    static var allExtensions: [String] { audioExtensions + videoExtensions }
    /// Лимит Nexara — 3 ГБ (тело запроса уходит потоково, память не зависит
    /// от размера файла — см. FileTranscriptionClient.writeMultipartBody).
    static let maxBytes: Int64 = 3_000_000_000

    /// Имя выбранного файла (для UI), если он выбран.
    var pickedFileName: String? {
        if case let .picked(name, _) = phase { return name }
        return nil
    }

    /// Идёт ли распознавание прямо сейчас.
    var isTranscribing: Bool {
        if case .transcribing = phase { return true }
        return false
    }

    /// Имя файла для зоны загрузки — и когда он выбран, и пока идёт
    /// распознавание (в .transcribing имени в phase нет, берём из pickedURL).
    var activeFileName: String? {
        switch phase {
        case let .picked(name, _): return name
        case .transcribing: return pickedURL?.lastPathComponent
        default: return nil
        }
    }

    /// Размер файла для зоны загрузки (см. `activeFileName`).
    var activeFileSize: Int64? {
        switch phase {
        case let .picked(_, size): return size
        case .transcribing: return pickedURL.map { fileSize(of: $0) }
        default: return nil
        }
    }

    /// Имя без расширения для дефолтного имени файла в диалоге «Сохранить как…»:
    /// заголовок показанной записи (его можно переименовать), иначе имя файла.
    var suggestedBaseName: String {
        if let id = shownRecordID, let record = store.record(id) {
            return Self.sanitizedFileName(record.displayTitle)
        }
        if let base = pickedURL?.deletingPathExtension().lastPathComponent, !base.isEmpty {
            return base
        }
        return "transcript"
    }

    /// Заголовок → безопасное имя файла: разделители путей и управляющие
    /// символы заменяются, длина ограничена.
    static func sanitizedFileName(_ title: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/:\\").union(.controlCharacters)
        let cleaned = title.unicodeScalars
            .map { forbidden.contains($0) ? "-" : String($0) }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let limited = String(cleaned.prefix(80))
        return limited.isEmpty ? "transcript" : limited
    }

    /// Принять выбранный/перетащенный файл: проверить формат и размер.
    func accept(url: URL) {
        let ext = url.pathExtension.lowercased()
        guard Self.allExtensions.contains(ext) else {
            phase = .error(L("transcribe.error.unsupportedFormat", ext.isEmpty ? "—" : ext))
            return
        }
        let size = fileSize(of: url)
        guard size <= Self.maxBytes else {
            phase = .error(L("transcribe.error.fileTooLarge"))
            return
        }
        task?.cancel()
        task = nil
        pickedURL = url
        phase = .picked(name: url.lastPathComponent, sizeBytes: size)
    }

    /// Запустить транскрипцию выбранного файла с параметрами страницы.
    func transcribe() {
        guard let url = pickedURL else { return }
        start(source: url, displayName: url.lastPathComponent, params: pageParams,
              target: .new(parentID: nil, title: nil))
    }

    /// Единая точка запуска: страница, «Повторить» и «Распознать заново».
    /// Параметры — снимок (не глобальный `providerID`), поэтому повтор идёт
    /// сохранённым сервисом, не переключая выбор пользователя. Один файл за
    /// раз: при идущем распознавании запуск отклоняется.
    @discardableResult
    func start(source url: URL, displayName: String,
               params: FileTranscriptionParams, target: Target) -> Bool {
        guard !isTranscribing else { return false }
        // После переноса «Папки данных» до перезапуска новая запись потерялась бы.
        guard !store.isFrozen else {
            phase = .error(L("transcribe.error.restartRequired"))
            return false
        }
        let route: ServiceRoute
        do {
            route = try SettingsStore.shared.resolveRoute(providerID: params.providerID)
        } catch {
            phase = .error(error.localizedDescription)
            return false
        }
        // Локальный сервис: без ключа и конфига, но модель должна быть скачана.
        if case .local(let model) = route, !LocalModelStore.shared.isDownloaded(model) {
            phase = .error(L("transcribe.local.modelMissing"))
            return false
        }
        guard params.rolesValidationMessage == nil else { return false }
        if params.usesLocalDiarization && !LocalModelStore.shared.isDownloaded(.diarizer) {
            phase = .error(L("transcribe.diarize.modelMissing"))
            Self.requestDiarizerModel()
            return false
        }
        let options = params.makeOptions(detail: timestampDetail)
        let localDiarization = params.usesLocalDiarization
        let speakerHint = params.numSpeakers
        let providerTag = SettingsStore.shared.providerTag(for: params.providerID)

        let recordID: UUID
        switch target {
        case let .new(parentID, title):
            recordID = store.addPending(.init(fileName: displayName, provider: providerTag,
                                              title: title, params: params,
                                              sourcePath: url.path, parentID: parentID))
        case .reuse(let id):
            store.restartPending(id, provider: providerTag, params: params)
            recordID = id
        }
        // Архив исходного звука — параллельно распознаванию, задачей стора:
        // отмена распознавания его не убивает (иначе «Повторить» не из чего).
        if SettingsStore.shared.saveTranscriptAudio, store.audioURL(for: recordID) == nil {
            store.archiveAudio(recordID, from: url)
        }

        phase = .transcribing
        progressNote = nil
        runningRecordID = recordID
        let useAsync = params.isBuiltin
        let store = store
        task = Task { [weak self] in
            do {
                let client = FileTranscriptionClient()
                let result: TranscriptResult
                switch route {
                case .local(let localModel):
                    // Локальный путь: движок + извлечение звука (в т.ч. из видео)
                    // + маппинг в TranscriptResult. Роли и LLM-анализ сюда не
                    // попадают — гейт isBuiltin; спикеров, если они запрошены,
                    // проставляет локальный диаризатор.
                    // Загрузка движка и декодирование независимы — перекрываем,
                    // чтобы холодный старт не ждал сумму двух операций.
                    async let engineLoading = LocalEngineManager.shared.engine(for: localModel)
                    let decoded = try await AudioFileDecoder.decodeToWav(url)
                    defer { try? FileManager.default.removeItem(at: decoded.url) }
                    let engine = try await engineLoading
                    guard !Task.isCancelled else { return }
                    let local = try await engine.transcribeFile(
                        wavURL: decoded.url,
                        language: options.language)
                    LocalEngineManager.shared.touch()
                    guard !Task.isCancelled else { return }
                    // Диаризация — по тому же временнóму WAV, до его удаления.
                    let segments = localDiarization
                        ? await self?.applyLocalSpeakers(wavURL: decoded.url,
                                                         numSpeakers: speakerHint,
                                                         words: local.words,
                                                         segments: local.segments) ?? local.segments
                        : local.segments
                    guard !Task.isCancelled else { return }
                    result = TranscriptResult(
                        fullText: local.fullText,
                        language: local.language ?? options.language,
                        duration: decoded.duration,
                        segments: segments,
                        rawSegments: segments,
                        words: local.words,
                        llmOutput: nil
                    ).withDetail(options.timestampDetail)
                case .remote(let apiKey, let config) where useAsync:
                    // Async-путь Nexara: сабмит сразу возвращает job_id,
                    // обработка идёт на сервере. job_id персистится ДО проверки
                    // отмены: задача уже поставлена и будет тарифицирована —
                    // без job_id «Повторить» отправило бы файл второй раз.
                    let jobID = try await client.submitAsync(
                        fileURL: url, options: options, apiKey: apiKey, config: config)
                    store.setJobID(recordID, jobID: jobID)
                    guard !Task.isCancelled else { return }
                    result = try await client.waitForResult(
                        jobID: jobID, apiKey: apiKey, config: config,
                        detail: options.timestampDetail,
                        deadline: Date().addingTimeInterval(TranscriptHistoryStore.serverResultLifetime))
                case .remote(let apiKey, let config):
                    // Пользовательский сервис: запрос к серверу и локальная
                    // диаризация того же файла идут параллельно. Шкала времени
                    // у них общая — сервер распознаёт исходный файл, а
                    // декодирование её не сдвигает.
                    async let remoteResult = client.transcribeRich(
                        fileURL: url, options: options, apiKey: apiKey, config: config)
                    let spans = localDiarization
                        ? await self?.localSpeakerSpans(for: url, numSpeakers: speakerHint) ?? nil
                        : nil
                    let server = try await remoteResult
                    guard !Task.isCancelled else { return }
                    if let spans, !spans.isEmpty {
                        let merged = SpeakerAssignment.apply(spans: spans,
                                                             words: server.words,
                                                             segments: server.rawSegments)
                        result = TranscriptResult(fullText: server.fullText,
                                                  language: server.language,
                                                  duration: server.duration,
                                                  segments: merged,
                                                  rawSegments: merged,
                                                  words: server.words,
                                                  llmOutput: server.llmOutput)
                            .withDetail(options.timestampDetail)
                    } else {
                        result = server
                    }
                }
                self?.progressNote = nil
                guard !Task.isCancelled else { return }
                let saved = store.markDone(recordID, result: result)
                self?.finishRun(showing: saved == nil ? nil : recordID)
            } catch {
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                self?.progressNote = nil
                store.markError(recordID, error: error)
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                self?.runningRecordID = nil
                self?.phase = .error(message)
            }
        }
        return true
    }

    /// Итог успешного запуска: показать запись, если она ещё жива (её могли
    /// удалить, пока шло распознавание), иначе вернуться к файлу.
    private func finishRun(showing recordID: UUID?) {
        runningRecordID = nil
        if let recordID {
            phase = .done(recordID: recordID)
        } else {
            returnToPickedOrIdle()
        }
    }

    // MARK: - Локальная диаризация

    /// Спикеры для уже декодированного WAV (локальный маршрут: файл всё равно
    /// пришлось декодировать для распознавания). При неудаче возвращаются
    /// исходные сегменты — расшифровка ценнее спикеров.
    private func applyLocalSpeakers(wavURL: URL,
                                    numSpeakers: Int?,
                                    words: [TranscriptWord],
                                    segments: [TranscriptSegment]) async -> [TranscriptSegment] {
        guard let spans = await diarizeSpans(wavURL: wavURL, numSpeakers: numSpeakers),
              !spans.isEmpty else { return segments }
        return SpeakerAssignment.apply(spans: spans, words: words, segments: segments)
    }

    /// Спикеры для файла, который распознаёт сервер: звук приходится
    /// декодировать самим. Временный WAV удаляется здесь же.
    private func localSpeakerSpans(for url: URL, numSpeakers: Int?) async -> [SpeakerSpan]? {
        guard let decoded = try? await AudioFileDecoder.decodeToWav(url) else { return nil }
        defer { try? FileManager.default.removeItem(at: decoded.url) }
        return await diarizeSpans(wavURL: decoded.url, numSpeakers: numSpeakers)
    }

    /// Общий вызов диаризатора. Ошибки НЕ пробрасываются: короткая запись,
    /// тишина или сбой моделей не должны обнулять готовую расшифровку —
    /// она просто останется без спикеров (причина уходит в лог).
    private func diarizeSpans(wavURL: URL, numSpeakers: Int?) async -> [SpeakerSpan]? {
        do {
            let diarizer = try await LocalEngineManager.shared.diarizer()
            guard !Task.isCancelled else { return nil }
            progressNote = L("transcribe.diarize.progress", 0)
            let spans = try await diarizer.diarize(
                wavURL: wavURL,
                numSpeakers: numSpeakers,
                progress: { [weak self] fraction in
                    self?.progressNote = L("transcribe.diarize.progress", Int(fraction * 100))
                }
            )
            LocalEngineManager.shared.touch()
            progressNote = nil
            return spans
        } catch {
            progressNote = nil
            if !(error is CancellationError) && !Task.isCancelled {
                NSLog("DOKA: локальная диаризация не удалась: \(error.localizedDescription)")
            }
            return nil
        }
    }

    // MARK: - Отмена, открытие, сброс

    /// Отмена транскрипции: прервать запрос/опрос и вернуться к выбранному
    /// файлу. Async-задачу на сервере остановить нельзя (эндпоинта нет) —
    /// она доработает и тарифицируется; запись остаётся «Отменена», а её
    /// jobID позволит забрать результат без повторной оплаты.
    func cancelTranscription() {
        task?.cancel()
        task = nil
        progressNote = nil
        if let id = runningRecordID {
            store.markCancelled(id)
            runningRecordID = nil
        }
        returnToPickedOrIdle()
    }

    /// Открыть готовую запись библиотеки в карточках страницы. Во время
    /// распознавания запрещено — молча убило бы задачу.
    func open(_ recordID: UUID) {
        guard !isTranscribing, let record = store.record(recordID), record.isDone else { return }
        task?.cancel()
        task = nil
        pickedURL = nil
        phase = .done(recordID: recordID)
    }

    /// Скрыть показанный результат: вернуться к выбранному файлу либо к
    /// пустой странице. Сама запись не теряется — она остаётся в библиотеке.
    func hideResult() {
        guard case .done = phase else { return }
        returnToPickedOrIdle()
    }

    /// Сброс: убрать файл и результат.
    func clear() {
        task?.cancel()
        task = nil
        pickedURL = nil
        phase = .idle
    }

    private func returnToPickedOrIdle() {
        if let url = pickedURL {
            phase = .picked(name: url.lastPathComponent, sizeBytes: fileSize(of: url))
        } else {
            phase = .idle
        }
    }

    /// Документ следует за фазой: один на показанную запись. Инвариант в
    /// одном месте — любой уход из `.done` отвязывает документ.
    private func syncShownDocument() {
        guard case let .done(id) = phase else {
            if shownDocument != nil {
                documentCancellable = nil
                shownDocument = nil
            }
            return
        }
        guard shownDocument?.recordID != id else { return }
        let document = TranscriptDocument(recordID: id)
        documentCancellable = document.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
        shownDocument = document
    }

    private func fileSize(of url: URL) -> Int64 {
        if let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
           let size = values.fileSize {
            return Int64(size)
        }
        if let number = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber {
            return number.int64Value
        }
        return 0
    }
}
