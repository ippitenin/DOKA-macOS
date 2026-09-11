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
    /// Мемо вывода. Не @Published: пишется во время вычисления body вью.
    private var cachedOutput: (key: OutputKey, result: TranscriptResult)?

    private struct OutputKey: Equatable {
        let detail: TimestampDetail
        let dictionary: [ReplacementRule]?
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
    }

    func reload() async {
        let loaded = await store.loadBody(recordID)
        body = loaded
        revision += 1
        cachedOutput = nil
        loadState = loaded == nil ? .missing : .ready
    }

    /// То, что пользователь видит и забирает: нарезка под детализацию плюс
    /// словарь для файлов, если он включён (выходной слой, см.
    /// `TranscriptOutput`). Сырой результат при этом не меняется.
    func output(detail: TimestampDetail) -> TranscriptResult? {
        guard let body else { return nil }
        let settings = SettingsStore.shared
        let rules = settings.applyDictionaryToFiles ? settings.replacements : nil
        let key = OutputKey(detail: detail, dictionary: rules, revision: revision)
        if let cachedOutput, cachedOutput.key == key { return cachedOutput.result }
        let raw = body.makeResult(detail: detail)
        let result = rules.map { TranscriptOutput.applyingDictionary(raw, rules: $0) } ?? raw
        cachedOutput = (key, result)
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
