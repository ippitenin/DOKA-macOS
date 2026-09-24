import Combine
import SwiftUI
import UniformTypeIdentifiers

/// Режим разметки ролей на странице «Транскрибация» (UI поверх `RolesSpec`).
enum RolesMode: String, CaseIterable, Identifiable {
    case off, auto, custom

    var id: String { rawValue }
    var title: String { L("transcribe.roles.\(rawValue)") }
}

/// Режим LLM-анализа Nexara. В списке страницы — только `off`, `template`
/// (шаблон из «Шаблонов анализа») и `custom`. Прежние пресеты
/// `meetingMinutes`/`summary`/`actionItems` из UI убраны (у каждого есть
/// встроенный шаблон-двойник), но остаются в enum: записи библиотеки с ними
/// декодируются и повторяются тем же промптом.
enum LLMAnalysisPreset: String, CaseIterable, Identifiable {
    case off, meetingMinutes, summary, actionItems, custom, template

    var id: String { rawValue }
    var title: String { L("transcribe.llm.preset.\(rawValue)") }

    /// Готовый промпт пресета; off и custom промпта не имеют.
    var promptTemplate: String? {
        switch self {
        case .off, .custom, .template: return nil
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
        /// Новая запись. `parentID` — «Распознать заново»: из какой записи (её
        /// архив звука наследуется копией); `sourcePath` — путь исходного файла
        /// для будущего «Повторить» (у повтора из архива — путь исходника родителя).
        case new(parentID: UUID?, title: String?, sourcePath: String?)
        /// «Повторить» на месте: та же запись снова в работе. `sourcePath` —
        /// новый путь исходника, если файл выбрали заново; nil — прежний.
        case reuse(UUID, sourcePath: String?)

        /// Запуск из библиотеки («Повторить», «Распознать заново»), а не
        /// файлом, выбранным на странице.
        var isFromLibrary: Bool {
            switch self {
            case .reuse: return true
            case .new(let parentID, _, _): return parentID != nil
            }
        }
    }

    /// Итог запуска. Причину отказа показывает вызывающий: страница — фазой,
    /// запись библиотеки — у своей кнопки (фазу страницы повтор из библиотеки
    /// не трогает).
    enum StartOutcome: Equatable {
        case started(UUID)
        /// Уже распознаётся другой файл — один за раз.
        case busy
        case rejected(String)
    }

    @Published private(set) var phase: Phase = .idle {
        didSet { syncShownDocument() }
    }
    /// Документ показанной записи (при `phase == .done`) — тот же экземпляр,
    /// что у детали библиотеки (`LibraryModel.document(for:)`); запись на
    /// странице наблюдает его сама.
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
    /// Разметка ролей (только Nexara, только с диаризацией).
    @Published var rolesMode: RolesMode = .off
    /// Свой список ролей: имена через запятую («Клиент, Агент»).
    @Published var rolesText: String = ""
    /// LLM-анализ расшифровки (только Nexara).
    @Published var llmPreset: LLMAnalysisPreset = .off
    /// Свой промпт анализа (llmPreset == .custom).
    @Published var llmCustomPrompt: String = ""
    /// Шаблон анализа (llmPreset == .template): id встроенного или своего.
    @Published var llmTemplateID: String?
    /// Где анализировать: на этом Mac (по умолчанию — в облако расшифровка
    /// уходит только по явному выбору) или LLM Nexara в том же запросе.
    @Published var llmLocal = true

    /// Анализ фактически пойдёт локально: выбран «На этом Mac» либо сервис
    /// не Nexara — у остальных облачного анализа нет вовсе.
    var analyzesLocally: Bool { llmLocal || !isBuiltinService }

    /// Локальный анализ заказан, а языковой модели нет — запускать нельзя
    /// (иначе анализ молча не состоялся бы после распознавания).
    var isLLMModelMissing: Bool {
        effectiveLLMPreset != .off && analyzesLocally && !LocalModelStore.shared.isDownloaded(.llm)
    }

    /// Режим анализа, который реально уйдёт в снимок: выбранный шаблон могли
    /// удалить в «Шаблонах анализа» — тогда анализ выключен (как в
    /// `FileTranscriptionParams.llmFields`), и запуск не должен блокироваться
    /// «нет модели», пока попап уже показывает «Выкл».
    var effectiveLLMPreset: LLMAnalysisPreset {
        llmPreset == .template && selectedLLMTemplate == nil ? .off : llmPreset
    }

    /// Шаблоны для списка «Анализ ИИ» — те же, что у панели анализа записи.
    var llmTemplates: [AnalysisTemplate] { SettingsStore.shared.allAnalysisTemplates }

    /// Выбранный шаблон; nil — не выбран или его успели удалить.
    var selectedLLMTemplate: AnalysisTemplate? {
        guard llmPreset == .template, let id = llmTemplateID else { return nil }
        return llmTemplates.first { $0.id == id }
    }

    /// Параметры страницы снимком — ровно то, что уйдёт в запрос и в запись
    /// библиотеки (по ним работают «Повторить» и «Распознать заново»).
    var pageParams: FileTranscriptionParams {
        let providerID = SettingsStore.shared.providerID
        // У сервисов кроме Nexara облачного анализа нет — только локальный.
        let local = llmLocal || providerID != TranscriptionProvider.builtin.rawValue
        let llm = FileTranscriptionParams.llmFields(preset: llmPreset,
                                                    customPrompt: llmCustomPrompt,
                                                    template: selectedLLMTemplate,
                                                    local: local,
                                                    languageName: llmLanguageName)
        return FileTranscriptionParams(providerID: providerID,
                                       language: language,
                                       diarize: diarize,
                                       numSpeakers: numSpeakers,
                                       diarizationSetting: diarizationSetting.rawValue,
                                       rolesMode: rolesMode.rawValue,
                                       rolesText: rolesText,
                                       llmPreset: llm.preset.rawValue,
                                       llmCustomPrompt: llm.prompt,
                                       llmTemplateID: llm.templateID,
                                       llmTemplateTitle: llm.templateTitle,
                                       llmLocal: local)
    }

    /// Язык ответа анализа Nexara: язык записи, если он задан на странице,
    /// иначе язык интерфейса — как у прежних пресетов.
    private var llmLanguageName: String {
        let code = language == "auto" ? AnalysisController.interfaceLanguageCode : language
        return TranscriptionLanguage.all.first { $0.id == code }?.title
            ?? Locale.current.localizedString(forLanguageCode: code) ?? code
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

    /// Поставить модель диаризатора в очередь скачивания, если её нет (и для
    /// шита «Распознать заново» — у него свои параметры).
    static func requestDiarizerModel() {
        if case .notDownloaded = LocalModelStore.shared.state(for: .diarizer) {
            LocalModelStore.shared.download(.diarizer)
        }
    }

    private var pickedURL: URL?
    private var task: Task<Void, Never>?
    /// Запись библиотеки, которая распознаётся прямо сейчас.
    private(set) var runningRecordID: UUID?
    /// Что распознаётся сейчас — для дропзоны: у запуска из библиотеки это
    /// не выбранный на странице файл.
    private var runningSource: (name: String, url: URL)?
    /// Идущий прогон занимает локальный ускоритель (ANE/GPU).
    ///
    /// Считается от маршрута ЭТОГО запуска, а не от глобального `providerID`:
    /// повтор из библиотеки идёт по снимку `params.providerID`, и пользователь
    /// мог с тех пор переключить сервис. Прежняя проверка глобальной настройки
    /// ошибалась в обе стороны — разрешала анализ поверх локального прогона и
    /// запрещала его при сетевом.
    private(set) var runningUsesLocalEngine = false
    /// Фаза страницы до запуска из библиотеки. Контроллер один (файл за раз),
    /// поэтому на время повтора страница показывает его прогресс, но итог
    /// такого запуска виден в самой записи — по окончании страница
    /// возвращается к своему файлу или показанному результату, а не к чужой
    /// записи или её ошибке.
    private var pagePhaseBeforeRun: Phase?

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
    /// Типы для `.fileImporter` — страница и «Повторить» с выбором файла.
    static let importerTypes: [UTType] = {
        var types = allExtensions.compactMap { UTType(filenameExtension: $0) }
        types.append(.audio)
        types.append(.movie)
        return types
    }()
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
    /// распознавание (в .transcribing имени в phase нет: берём то, что
    /// распознаётся, — при повторе из библиотеки это не выбранный файл).
    var activeFileName: String? {
        switch phase {
        case let .picked(name, _): return name
        case .transcribing: return runningSource?.name ?? pickedURL?.lastPathComponent
        default: return nil
        }
    }

    /// Размер файла для зоны загрузки (см. `activeFileName`).
    var activeFileSize: Int64? {
        switch phase {
        case let .picked(_, size): return size
        case .transcribing: return (runningSource?.url ?? pickedURL).map { Self.fileSize(of: $0) }
        default: return nil
        }
    }

    /// Принять выбранный/перетащенный файл: проверить формат и размер.
    func accept(url: URL) {
        // Во время распознавания (в том числе повтора из библиотеки) новый
        // файл не принимается: иначе задача молча отменилась бы, а её запись
        // осталась бы «в процессе».
        guard !isTranscribing else { return }
        if let message = Self.validationError(for: url) {
            phase = .error(message)
            return
        }
        task?.cancel()
        task = nil
        pickedURL = url
        phase = .picked(name: url.lastPathComponent, sizeBytes: Self.fileSize(of: url))
    }

    /// Формат и размер файла; nil — файл годится (страница и выбор файла
    /// для «Повторить»).
    static func validationError(for url: URL) -> String? {
        let ext = url.pathExtension.lowercased()
        guard allExtensions.contains(ext) else {
            return L("transcribe.error.unsupportedFormat", ext.isEmpty ? "—" : ext)
        }
        guard fileSize(of: url) <= maxBytes else { return L("transcribe.error.fileTooLarge") }
        return nil
    }

    /// Запустить транскрипцию выбранного файла с параметрами страницы.
    func transcribe() {
        guard let url = pickedURL else { return }
        let outcome = start(source: url, displayName: url.lastPathComponent, params: pageParams,
                            target: .new(parentID: nil, title: nil, sourcePath: url.path))
        if case .rejected(let message) = outcome {
            phase = .error(message)
        }
    }

    /// Единая точка запуска: страница, «Повторить» и «Распознать заново».
    /// Параметры — снимок (не глобальный `providerID`), поэтому повтор идёт
    /// сохранённым сервисом, не переключая выбор пользователя. Один файл за
    /// раз: при идущем распознавании запуск отклоняется. Отказ фазу НЕ
    /// меняет — повтор из библиотеки не должен затирать страницу.
    @discardableResult
    func start(source url: URL, displayName: String,
               params: FileTranscriptionParams, target: Target) -> StartOutcome {
        guard !isTranscribing else { return .busy }
        // После переноса «Папки данных» до перезапуска новая запись потерялась бы.
        guard !store.isFrozen else { return .rejected(L("transcribe.error.restartRequired")) }
        if case .reuse(let id, _) = target, store.record(id) == nil {
            return .rejected(L("transcribe.recordMissing"))
        }
        let route: ServiceRoute
        do {
            route = try SettingsStore.shared.resolveRoute(providerID: params.providerID)
        } catch {
            return .rejected(error.localizedDescription)
        }
        // Локальный сервис: без ключа и конфига, но модель должна быть скачана.
        if case .local(let model) = route, !LocalModelStore.shared.isDownloaded(model) {
            return .rejected(L("transcribe.local.modelMissing"))
        }
        // Взаимоисключение с ИИ-анализом — в обе стороны: анализ не стартует
        // поверх локального распознавания (AnalysisController.availability), а
        // локальное распознавание — поверх анализа. Иначе речевая модель на ANE
        // и языковая на Metal дерутся за ускоритель, а на маке с 8 ГБ ещё и за
        // память. Сетевому распознаванию анализ не мешает.
        if case .local = route, AnalysisController.shared.isRunning {
            return .rejected(L("transcribe.busy.analysis"))
        }
        if let message = params.rolesValidationMessage { return .rejected(message) }
        if params.usesLocalDiarization && !LocalModelStore.shared.isDownloaded(.diarizer) {
            Self.requestDiarizerModel()
            return .rejected(L("transcribe.diarize.modelMissing"))
        }
        // Нарезка ответа на хранение не влияет: в тело уходят rawSegments и
        // words, показ перенарезает документ под выбранную детализацию.
        let options = params.makeOptions(detail: .server)
        let localDiarization = params.usesLocalDiarization
        let speakerHint = params.numSpeakers
        let providerTag = SettingsStore.shared.providerTag(for: params.providerID)

        let recordID: UUID
        switch target {
        case let .new(parentID, title, sourcePath):
            recordID = store.addPending(.init(fileName: displayName, provider: providerTag,
                                              title: title, params: params,
                                              sourcePath: sourcePath, parentID: parentID))
        case let .reuse(id, sourcePath):
            store.restartPending(id, provider: providerTag, params: params, sourcePath: sourcePath)
            recordID = id
        }
        // Архив исходного звука — параллельно распознаванию, задачей стора:
        // отмена распознавания его не убивает (иначе «Повторить» не из чего).
        // «Распознать заново» наследует архив исходной записи копией.
        if SettingsStore.shared.saveTranscriptAudio, store.audioURL(for: recordID) == nil {
            if case .new(let parentID?, _, _) = target, store.audioURL(for: parentID) != nil {
                store.inheritAudio(recordID, from: parentID)
            } else {
                store.archiveAudio(recordID, from: url)
            }
        }
        // Разрешение на уведомления — лениво, в момент осмысленного действия.
        Task { await FileTranscriptionNotifier.shared.requestAuthorizationIfNeeded() }

        pagePhaseBeforeRun = target.isFromLibrary ? phase : nil
        runningSource = (displayName, url)
        if case .local = route { runningUsesLocalEngine = true }
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
                if saved != nil { Self.startAnalysisAfterTranscription(recordID) }
            } catch {
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                self?.progressNote = nil
                store.markError(recordID, error: error)
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                self?.failRun(message)
            }
        }
        return .started(recordID)
    }

    /// Локальный анализ сразу после распознавания: заказанный на странице
    /// («Анализ ИИ» → «На этом Mac», по сохранённым params — работает и для
    /// «Повторить»), иначе глобальный автоанализ (по умолчанию выключен:
    /// анализ идёт минутами и греет Mac). Гейт доступности — общий с кнопкой
    /// «Проанализировать», поэтому без модели и при занятом анализе он просто
    /// не стартует и ничего не сообщает. Добор async-задач после перезапуска
    /// идёт мимо контроллера — там анализ не запускается.
    private static func startAnalysisAfterTranscription(_ recordID: UUID) {
        let settings = SettingsStore.shared
        let controller = AnalysisController.shared
        let record = TranscriptHistoryStore.shared.record(recordID)
        guard controller.availability(for: record).isRunnable else { return }
        // Анализ, заказанный на странице «На этом Mac», важнее глобального
        // автоанализа: пользователь выбрал его для этого файла. Язык ответа —
        // «как в записи».
        if let kind = record?.params?.localAnalysisKind(templates: settings.allAnalysisTemplates) {
            controller.start(recordID: recordID, request: .init(kind: kind, responseLanguage: nil))
            return
        }
        guard settings.autoAnalysis else { return }
        controller.start(recordID: recordID,
                         request: .init(kind: .template(settings.selectedAnalysisTemplate),
                                        responseLanguage: settings.analysisLanguage.isEmpty
                                            ? nil : settings.analysisLanguage))
    }

    /// Итог успешного запуска: показать запись, если она ещё жива (её могли
    /// удалить, пока шло распознавание), иначе вернуться к файлу. Запуск из
    /// библиотеки возвращает страницу к её прежнему состоянию.
    private func finishRun(showing recordID: UUID?) {
        runningRecordID = nil
        runningSource = nil
        runningUsesLocalEngine = false
        if let before = pagePhaseBeforeRun {
            restorePagePhase(before)
        } else if let recordID {
            phase = .done(recordID: recordID)
        } else {
            returnToPickedOrIdle()
        }
    }

    /// Ошибка запуска: у страницы — карточка ошибки; у запуска из библиотеки
    /// ошибка видна в самой записи, страницу чужой ошибкой не затираем.
    private func failRun(_ message: String) {
        runningRecordID = nil
        runningSource = nil
        runningUsesLocalEngine = false
        if let before = pagePhaseBeforeRun {
            restorePagePhase(before)
        } else {
            phase = .error(message)
        }
    }

    /// Вернуть страницу к фазе до запуска из библиотеки — если то, что она
    /// показывала, ещё существует.
    private func restorePagePhase(_ before: Phase) {
        pagePhaseBeforeRun = nil
        switch before {
        case .done(let id) where store.record(id) == nil:
            returnToPickedOrIdle()
        case .picked where pickedURL == nil:
            returnToPickedOrIdle()
        case .transcribing:
            returnToPickedOrIdle()
        default:
            phase = before
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
                    // У FluidAudio в этой версии нет кооперативных точек
                    // отмены: после «Отмена» он досчитывает до конца, а его
                    // колбэк продолжает приходить. Без этой проверки он
                    // перетирал бы `progressNote` уже на отменённой странице —
                    // пользователь видел бы ползущий процент диаризации после
                    // того, как сам всё остановил.
                    guard let self, self.isTranscribing else { return }
                    self.progressNote = L("transcribe.diarize.progress", Int(fraction * 100))
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
        runningSource = nil
        runningUsesLocalEngine = false
        if let before = pagePhaseBeforeRun {
            restorePagePhase(before)
        } else {
            returnToPickedOrIdle()
        }
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
            phase = .picked(name: url.lastPathComponent, sizeBytes: Self.fileSize(of: url))
        } else {
            phase = .idle
        }
    }

    /// Документ следует за фазой: один на показанную запись. Инвариант в
    /// одном месте — любой уход из `.done` отвязывает документ.
    private func syncShownDocument() {
        guard case let .done(id) = phase else {
            if shownDocument != nil { shownDocument = nil }
            return
        }
        guard shownDocument?.recordID != id else { return }
        shownDocument = LibraryModel.shared.document(for: id)
    }

    private static func fileSize(of url: URL) -> Int64 {
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
