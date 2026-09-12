import Combine
import Foundation

/// Наблюдаемая запись библиотеки — единственный источник показанного
/// результата: деталь библиотеки и результат на странице «Транскрибация»
/// смотрят в один документ (экземпляры раздаёт `LibraryModel.document(for:)`).
/// Тело грузится лениво; перенарезка и словарь для файлов мемоизируются:
/// вью перерисовываются часто, а пересборка часовой расшифровки на каждый
/// рендер ощутима.
@MainActor
final class TranscriptDocument: ObservableObject {
    enum LoadState: Equatable {
        case loading
        case ready
        case missing     // записи нет или тело не читается
    }

    let recordID: UUID
    /// Запись в индексе библиотеки (заголовок, статус, сервис) — следует за
    /// стором; nil — запись удалена.
    @Published private(set) var record: FileTranscriptRecord?
    @Published private(set) var body: TranscriptBody?
    @Published private(set) var loadState: LoadState = .loading

    private let store: TranscriptHistoryStore
    private var cancellables = Set<AnyCancellable>()
    /// Счётчик версий тела — ключ кэша вывода.
    private var revision = 0
    /// Мемо вывода и результата до словаря. Не @Published: пишутся во время
    /// вычисления body вью.
    private var cachedOutput: (key: OutputKey, result: TranscriptResult)?
    private var cachedSource: (key: SourceKey, result: TranscriptResult)?
    /// Отпечаток входа анализа — считается по фиксированной детализации,
    /// мемоизируется по версии тела.
    private var cachedFingerprint: (revision: Int, value: String)?

    private struct OutputKey: Equatable {
        let detail: TimestampDetail
        let dictionary: [ReplacementRule]?
        let revision: Int
    }

    private struct SourceKey: Equatable {
        let detail: TimestampDetail
        let revision: Int
    }

    /// `store` — для тестов; по умолчанию общий стор. Дефолт подставляется в
    /// теле, а не в сигнатуре: дефолтные аргументы вычисляются вне главного
    /// актора, и `.shared` там дал бы предупреждение (гейт сборки).
    init(recordID: UUID, store: TranscriptHistoryStore? = nil) {
        let store = store ?? .shared
        self.recordID = recordID
        self.store = store
        record = store.record(recordID)
        if let cached = store.cachedBody(recordID) {
            // Свежий результат уже в кэше стора — показываем без мигания.
            body = cached
            loadState = .ready
        } else if record == nil {
            loadState = .missing
        } else if record?.isDone == true {
            Task { await reload() }
        }
        // Незавершённая запись тела ещё не имеет: ждём перехода в «готово».

        // @Published отдаёт новое значение параметром (willSet) — читаем его,
        // а не стор.
        store.$records
            .map { [recordID] records in records.first { $0.id == recordID } }
            .removeDuplicates()
            .sink { [weak self] fresh in self?.recordDidChange(fresh) }
            .store(in: &cancellables)
        store.bodyChanged
            .filter { $0 == recordID }
            .sink { [weak self] _ in Task { await self?.reload() } }
            .store(in: &cancellables)
        // Заморозка после переноса «Папки данных» выключает правку — вью
        // должна перерисоваться (`canEdit` читает стор).
        store.$isFrozen
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    func reload() async {
        let loaded = await store.loadBody(recordID)
        // Своё же сохранение правки возвращается сюда через `bodyChanged` —
        // то же тело, пересобирать вывод незачем.
        if loaded != body { apply(loaded) }
        loadState = loaded == nil ? .missing : .ready
    }

    // MARK: - Правки

    /// Правки записи; пустые, если не правили.
    var edits: TranscriptEdits { body?.edits ?? TranscriptEdits() }

    /// Можно ли править: тело загружено и библиотека не заморожена переносом
    /// «Папки данных» (запись на диск до перезапуска молча не дошла бы).
    var canEdit: Bool { body != nil && !store.isFrozen }

    func renameSpeaker(_ id: String, to name: String) {
        mutateEdits { $0.rename(id, to: name) }
    }

    func mergeSpeaker(_ id: String, into target: String) {
        mutateEdits { $0.merge(id, into: target) }
    }

    func unmergeSpeaker(_ id: String) {
        mutateEdits { $0.unmerge(id) }
    }

    /// Итог правки. `stale` — адрес устарел (реплику успели поправить иначе):
    /// редактор не должен терять черновик.
    enum EditOutcome {
        case applied, unchanged, stale, unavailable
    }

    /// Новый текст реплики (до словаря). Пустой не сохраняется.
    @discardableResult
    func setSegmentText(_ text: String, at target: EditTarget) -> EditOutcome {
        mutateEdits(validating: target) { $0.setText(text, at: target) }
    }

    func revertSegmentText(at target: EditTarget) {
        mutateEdits { $0.revertText(at: target) }
    }

    /// «Назначить реплику»: `speaker == nil` — новый спикер со свободным id.
    func reassignSegment(at target: EditTarget, to speaker: String?) {
        guard let rawSegments = body?.transcript.rawSegments else { return }
        mutateEdits(validating: target) { edits in
            let id = speaker ?? SpeakerName.nextID(existing: edits.knownSpeakerIDs(rawSegments: rawSegments))
            edits.setSpeaker(id, at: target)
        }
    }

    func revertSegmentSpeaker(at target: EditTarget) {
        mutateEdits { $0.revertSpeaker(at: target) }
    }

    /// «Сбросить правки»: всё возвращается к результату распознавания,
    /// счётчик правок продолжает расти.
    func resetAllEdits() {
        mutateEdits { $0 = TranscriptEdits() }
    }

    /// Единая точка правок: изменение → счётчик → вывод → сохранение.
    /// Сохраняется по завершённому действию (Return, выбор в меню), а не на
    /// каждое нажатие клавиши. `saveBody` обновляет и текст для поиска, и сводку.
    /// Адрес `validating` проверяется на свежесть: устаревший (реплику успели
    /// поправить иначе) отвергается, а не портит правки.
    @discardableResult
    private func mutateEdits(validating target: EditTarget? = nil,
                             _ change: (inout TranscriptEdits) -> Void) -> EditOutcome {
        guard var body, canEdit, store.record(recordID) != nil else { return .unavailable }
        // Неприменимые к исходникам правки (битые данные) отбрасываются: иначе
        // `isValid` навсегда блокировал бы соседние реплики.
        let before = (body.edits ?? TranscriptEdits())
            .sanitized(rawSegments: body.transcript.rawSegments, words: body.transcript.words)
        if let target, !before.isValid(target) { return .stale }
        var edits = before
        change(&edits)
        guard !edits.hasSameContent(as: before) else { return .unchanged }
        edits.revision = before.revision &+ 1
        body.edits = edits
        apply(body)
        store.saveBody(recordID, body)
        return .applied
    }

    private func apply(_ newBody: TranscriptBody?) {
        body = newBody
        revision += 1
        cachedOutput = nil
        cachedSource = nil
        cachedFingerprint = nil
    }

    // MARK: - Анализы

    var analyses: [StoredAnalysis] { body?.analyses ?? [] }

    /// Отпечаток текущей расшифровки (правки применены, словарь — нет).
    /// Считается мимо кэшей вывода: у них ключ — пользовательская
    /// детализация, а вход анализа берётся на фиксированной.
    var analysisFingerprint: String? {
        guard let body else { return nil }
        if let cachedFingerprint, cachedFingerprint.revision == revision {
            return cachedFingerprint.value
        }
        let input = TranscriptLLMInput.build(
            title: record?.displayTitle ?? "",
            result: body.makeResult(detail: TranscriptLLMInput.detail))
        cachedFingerprint = (revision, input.fingerprint)
        return input.fingerprint
    }

    /// Расшифровку правили после этого анализа. У анализа Nexara отпечатка
    /// нет (он пришёл из того же запроса, что и расшифровка) — такой анализ
    /// устаревшим не помечаем.
    func isStale(_ analysis: StoredAnalysis) -> Bool {
        guard let printed = analysis.inputFingerprint, let current = analysisFingerprint else {
            return false
        }
        return printed != current
    }

    /// Удалить анализ. Тело перечитает `bodyChanged` — своей копии документ
    /// не правит, чтобы не разойтись со стором.
    func deleteAnalysis(_ analysisID: UUID) {
        guard canEdit else { return }
        Task { await store.deleteAnalysis(analysisID, from: recordID) }
    }

    /// То, что пользователь видит и забирает: нарезка под детализацию плюс
    /// словарь для файлов, если он включён (выходной слой, см.
    /// `TranscriptOutput`). Сырой результат при этом не меняется.
    func output(detail: TimestampDetail) -> TranscriptResult? {
        let settings = SettingsStore.shared
        let rules = settings.applyDictionaryToFiles ? settings.replacements : nil
        let key = OutputKey(detail: detail, dictionary: rules, revision: revision)
        if let cachedOutput, cachedOutput.key == key { return cachedOutput.result }
        guard let source = source(detail: detail) else { return nil }
        let result = rules.map { TranscriptOutput.applyingDictionary(source, rules: $0) } ?? source
        cachedOutput = (key, result)
        return result
    }

    /// Результат с правками, но ДО словаря — текст для редактора реплики:
    /// пользователь правит исходник, а словарь остаётся линзой поверх.
    func source(detail: TimestampDetail) -> TranscriptResult? {
        guard let body else { return nil }
        let key = SourceKey(detail: detail, revision: revision)
        if let cachedSource, cachedSource.key == key { return cachedSource.result }
        let result = body.makeResult(detail: detail)
        cachedSource = (key, result)
        return result
    }

    /// Переход записи в «готово» (конец распознавания, добор после
    /// перезапуска, повтор на месте) — тело появилось или сменилось.
    private func recordDidChange(_ fresh: FileTranscriptRecord?) {
        let wasDone = record?.isDone == true
        record = fresh
        guard let fresh else {
            loadState = .missing
            return
        }
        if fresh.isDone && !wasDone {
            Task { await reload() }
        }
    }
}
