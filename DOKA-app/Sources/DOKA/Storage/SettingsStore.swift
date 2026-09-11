import AppKit
import Foundation
import ServiceManagement

/// Языки транскрипции, поддерживаемые в настройках.
struct TranscriptionLanguage: Identifiable, Equatable {
    let id: String      // ISO-639-1 код или "auto"
    let title: String

    static let all: [TranscriptionLanguage] = [
        .init(id: "auto", title: L("lang.auto")),
        .init(id: "ru", title: L("lang.ru")),
        .init(id: "en", title: L("lang.en")),
        .init(id: "uk", title: L("lang.uk")),
        .init(id: "kk", title: L("lang.kk")),
        .init(id: "de", title: L("lang.de")),
        .init(id: "fr", title: L("lang.fr")),
        .init(id: "es", title: L("lang.es")),
        .init(id: "it", title: L("lang.it")),
        .init(id: "pt", title: L("lang.pt")),
        .init(id: "zh", title: L("lang.zh")),
        .init(id: "ja", title: L("lang.ja")),
        .init(id: "tr", title: L("lang.tr"))
    ]
}

/// Стиль плавающей панели записи.
enum RecorderStyle: String, CaseIterable, Identifiable {
    case aurora    // светящаяся плашка + волна, подсветка краёв всего экрана
    case studio    // широкая волна-спектр внизу экрана: таймер по центру, esc снизу
    // Порядок кейсов задаёт порядок карточек в пикере стилей
    // (`RecorderStylePicker` строит сетку из allCases).
    case notch     // чёрная плашка, прирастающая к вырезу камеры
    case mini      // капелька вдвое уже «Авроры», без подсветки экрана
    case classic   // крупная: точка, волна, таймер, подсказка Esc
    case hidden    // панель не показывается (кроме ошибок)

    var id: String { rawValue }

    var title: String {
        switch self {
        case .classic: return L("recorderStyle.classic")
        case .mini: return L("recorderStyle.mini")
        case .notch: return L("recorderStyle.notch")
        case .aurora: return L("recorderStyle.aurora")
        case .studio: return L("recorderStyle.studio")
        case .hidden: return L("recorderStyle.hidden")
        }
    }
}

/// Язык интерфейса приложения.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case ru
    case en

    var id: String { rawValue }

    /// Названия языков — каждое на своём языке (конвенция),
    /// локализуется только пункт «Как в системе».
    var title: String {
        switch self {
        case .system: return L("appLanguage.system")
        case .ru: return "Русский"
        case .en: return "English"
        }
    }
}

/// Срок хранения аудиозаписей истории. `forever` — по времени не удалять.
enum AudioRetention: String, CaseIterable, Identifiable {
    case day1, day3, day7, day14, day30, forever

    var id: String { rawValue }

    var title: String {
        switch self {
        case .day1: return L("audioRetention.day1")
        case .day3: return L("audioRetention.day3")
        case .day7: return L("audioRetention.day7")
        case .day14: return L("audioRetention.day14")
        case .day30: return L("audioRetention.day30")
        case .forever: return L("audioRetention.forever")
        }
    }

    /// Срок в днях; nil — хранить всегда.
    var days: Int? {
        switch self {
        case .day1: return 1
        case .day3: return 3
        case .day7: return 7
        case .day14: return 14
        case .day30: return 30
        case .forever: return nil
        }
    }
}

/// Срок хранения записей библиотеки транскрибаций. Библиотека — место, куда
/// возвращаются, поэтому дефолт — «всегда»; прежний дефолт 12 ч был
/// согласован с жизнью результата на сервере Nexara, пока журнал был лишь
/// списком «недавних». rawValue в UserDefaults — вставка новых сроков
/// безопасна.
enum TranscriptRetention: String, CaseIterable, Identifiable {
    case hours12, hours24, hours48, hours72, days7, days30, forever

    var id: String { rawValue }

    var title: String { L("transcriptRetention.\(rawValue)") }

    /// Срок в часах; nil — хранить всегда.
    var hours: Int? {
        switch self {
        case .hours12: return 12
        case .hours24: return 24
        case .hours48: return 48
        case .hours72: return 72
        case .days7: return 7 * 24
        case .days30: return 30 * 24
        case .forever: return nil
        }
    }

    /// Срок из UserDefaults. Ключ пишется только при явном выборе в UI
    /// (`didSet`), поэтому его отсутствие = «пользователь не выбирал» →
    /// «всегда»; явный выбор сохраняется. Мусор — тоже «всегда»: безопасная
    /// сторона, ничего не удаляется.
    static func resolve(stored: String?) -> TranscriptRetention {
        guard let stored else { return .forever }
        return TranscriptRetention(rawValue: stored) ?? .forever
    }

    /// Выбирал ли пользователь срок сам (для однократной плашки о смене дефолта).
    static func isExplicit(stored: String?) -> Bool {
        stored.flatMap(TranscriptRetention.init(rawValue:)) != nil
    }
}

/// Исполняемый маршрут активного сервиса распознавания — единственная форма
/// ветвления «локальный/сетевой» в контроллерах (`SettingsStore.resolveRoute`).
/// Своих редакций этого выбора (сентинелы, пары опционалов) не заводить.
enum ServiceRoute {
    case local(LocalModel)
    case remote(apiKey: String, config: ProviderConfig)

    /// Имя модели для метаданных истории.
    var modelTag: String {
        switch self {
        case .local(let model): return model.modelName
        case .remote(_, let config): return config.model
        }
    }
}

/// Настройки приложения поверх UserDefaults.
@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    private let defaults = UserDefaults.standard

    private enum Key {
        static let language = "language"
        static let soundsEnabled = "soundsEnabled"
        static let restoreClipboard = "restoreClipboard"
        static let replacements = "replacements"
        static let onboardingCompleted = "onboardingCompleted"
        static let provider = "provider"
        static let customEndpoint = "customEndpoint"
        static let customModel = "customModel"
        static let recorderStyle = "recorderStyle"
        static let appLanguage = "appLanguage"
        static let typingSpeedWPM = "typingSpeedWPM"
        static let saveAudio = "saveAudio"
        static let audioRetention = "audioRetention"
        static let transcriptRetention = "transcriptRetention"
        static let micAutoBoost = "micAutoBoost"
        static let silenceRemoval = "silenceRemoval"
        static let soundVolume = "soundVolume"
        static let showDockIcon = "showDockIcon"
        static let openWindowAtLaunch = "openWindowAtLaunch"
        static let mouseShortcutButton = "mouseShortcutButton"
        static let customServices = "customServices"
        static let servicesMigrated = "servicesMigrated"
        static let skipSilentRecordings = "skipSilentRecordings"
        static let applyDictionaryToFiles = "applyDictionaryToFiles"
        static let libraryRetentionNoticeDismissed = "libraryRetentionNoticeDismissed"
        static let saveTranscriptAudio = "saveTranscriptAudio"
        static let notifyFileTranscription = "notifyFileTranscription"
    }

    @Published var language: String {
        didSet { defaults.set(language, forKey: Key.language) }
    }
    @Published var soundsEnabled: Bool {
        didSet { defaults.set(soundsEnabled, forKey: Key.soundsEnabled) }
    }
    /// Громкость звуковых сигналов (0…1).
    @Published var soundVolume: Double {
        didSet { defaults.set(soundVolume, forKey: Key.soundVolume) }
    }
    /// На время записи выставлять громкость системного микрофона на максимум
    /// (и возвращать обратно после). Работает только с устройством по умолчанию.
    @Published var micAutoBoost: Bool {
        didSet { defaults.set(micAutoBoost, forKey: Key.micAutoBoost) }
    }
    /// Вырезать тишину из записи перед отправкой на распознавание.
    /// Статистику и аудио истории не затрагивает — режется только копия для API.
    @Published var silenceRemoval: Bool {
        didSet { defaults.set(silenceRemoval, forKey: Key.silenceRemoval) }
    }
    @Published var restoreClipboard: Bool {
        didSet { defaults.set(restoreClipboard, forKey: Key.restoreClipboard) }
    }
    @Published var replacements: [ReplacementRule] {
        didSet {
            if let data = try? JSONEncoder().encode(replacements) {
                defaults.set(data, forKey: Key.replacements)
            }
        }
    }
    @Published var onboardingCompleted: Bool {
        didSet { defaults.set(onboardingCompleted, forKey: Key.onboardingCompleted) }
    }

    /// Выбранный сервис распознавания: "builtin" или "custom:<uuid>" —
    /// ссылка на пресет из `customServices`.
    @Published var providerID: String {
        didSet {
            defaults.set(providerID, forKey: Key.provider)
            // Смена сервиса: модель ушедшего локального сервиса выгружается
            // из памяти сразу (~2 ГБ ОЗУ), не дожидаясь таймера простоя.
            if let old = LocalModel.from(providerID: oldValue), old != selectedLocalModel {
                LocalEngineManager.shared.unloadIfCurrent(old)
            }
        }
    }
    /// Сохранённые пользовательские сервисы (пресеты «Сервиса»).
    @Published var customServices: [CustomService] {
        didSet { persistCustomServices() }
    }

    /// Стиль панели записи.
    @Published var recorderStyle: RecorderStyle {
        didSet { defaults.set(recorderStyle.rawValue, forKey: Key.recorderStyle) }
    }

    /// Личная скорость печати (слов/мин), измеренная тестом на дашборде.
    /// 0 — тест ещё не пройден (геро-метрики дашборда скрыты).
    @Published var typingSpeedWPM: Double {
        didSet { defaults.set(typingSpeedWPM, forKey: Key.typingSpeedWPM) }
    }

    /// Сохранять ли исходное аудио диктовки (m4a) для прослушивания в истории.
    /// Выключено — аудио не кодируется (вставка быстрее) и не показывается в истории.
    @Published var saveAudio: Bool {
        didSet { defaults.set(saveAudio, forKey: Key.saveAudio) }
    }
    /// Срок хранения сохранённого аудио истории.
    @Published var audioRetention: AudioRetention {
        didSet { defaults.set(audioRetention.rawValue, forKey: Key.audioRetention) }
    }
    /// Срок хранения записей «Недавних транскрибаций».
    @Published var transcriptRetention: TranscriptRetention {
        didSet { defaults.set(transcriptRetention.rawValue, forKey: Key.transcriptRetention) }
    }

    /// Не отправлять на распознавание запись диктовки, в которой не услышана
    /// речь (`DictationGate`): не платим за тишину и не ловим галлюцинации.
    /// Выключается для тихих голосов и дальних микрофонов.
    @Published var skipSilentRecordings: Bool {
        didSet { defaults.set(skipSilentRecordings, forKey: Key.skipSilentRecordings) }
    }
    /// Применять «Словарь» к расшифровкам файлов — на выходном слое
    /// (`TranscriptOutput`): показ, копирование, «Сохранить как…». По
    /// умолчанию выключено — изоляция пайплайна файлов сохраняется.
    @Published var applyDictionaryToFiles: Bool {
        didSet { defaults.set(applyDictionaryToFiles, forKey: Key.applyDictionaryToFiles) }
    }
    /// Плашку библиотеки «записи теперь хранятся всегда» закрыли.
    @Published var libraryRetentionNoticeDismissed: Bool {
        didSet { defaults.set(libraryRetentionNoticeDismissed, forKey: Key.libraryRetentionNoticeDismissed) }
    }

    /// Выбирал ли пользователь срок хранения библиотеки сам (иначе действует
    /// дефолт «всегда» — см. `TranscriptRetention.resolve`).
    var isTranscriptRetentionExplicit: Bool {
        TranscriptRetention.isExplicit(stored: defaults.string(forKey: Key.transcriptRetention))
    }

    /// Язык интерфейса. Применяется при следующем запуске: Foundation
    /// читает AppleLanguages один раз на старте процесса.
    @Published var appLanguage: AppLanguage {
        didSet {
            defaults.set(appLanguage.rawValue, forKey: Key.appLanguage)
            switch appLanguage {
            case .system:
                defaults.removeObject(forKey: "AppleLanguages")
            case .ru, .en:
                defaults.set([appLanguage.rawValue], forKey: "AppleLanguages")
            }
        }
    }

    /// Выбранный пользовательский сервис; nil — встроенный (или пресет удалён,
    /// тогда всё мягко откатывается к встроенному).
    var selectedCustomService: CustomService? {
        customService(for: providerID)
    }

    /// Пресет по id сервиса («custom:<uuid>»); nil — не пресет или он удалён.
    func customService(for providerID: String) -> CustomService? {
        guard providerID.hasPrefix("custom:"),
              let id = UUID(uuidString: String(providerID.dropFirst("custom:".count))) else {
            return nil
        }
        return customServices.first { $0.id == id }
    }

    /// Выбранная локальная модель; nil — сетевой сервис.
    var selectedLocalModel: LocalModel? {
        LocalModel.from(providerID: providerID)
    }

    /// Активен ли локальный сервис (on-device, без сети и без ключа).
    var isLocalService: Bool { selectedLocalModel != nil }

    /// Готов ли активный сервис к работе: локальный — модель скачана,
    /// сетевой — разбирается конфиг и сохранён ключ. Единая замена всех
    /// guard'ов «есть ключ» — другие редакции этой проверки не заводить.
    var isServiceReady: Bool {
        if let local = selectedLocalModel {
            return LocalModelStore.shared.isDownloaded(local)
        }
        // Конфиг — до ключа: не трогаем Keychain, когда сервис всё равно не готов.
        return providerConfig != nil && currentAPIKey != nil
    }

    /// Исполняемый маршрут активного сервиса: локальный движок или сетевой
    /// клиент с ключом и конфигом. Бросает `ClientError`, если сетевой сервис
    /// не готов. Читает Keychain — не вызывать синхронно в пути запуска
    /// (диалог подтверждения доступа заморозит приложение, см. CLAUDE.md).
    func resolveRoute() throws -> ServiceRoute {
        try resolveRoute(providerID: providerID)
    }

    /// Маршрут произвольного сервиса — повтор файловой транскрибации по
    /// сохранённым параметрам записи, не переключая выбор пользователя.
    /// Удалённый пресет — ошибка «не настроен», а не молчаливый уход на
    /// встроенный (платный) сервис. Читает Keychain — только по действию
    /// пользователя, не из тела вью и не в пути запуска.
    func resolveRoute(providerID: String) throws -> ServiceRoute {
        if let local = LocalModel.from(providerID: providerID) { return .local(local) }
        if providerID.hasPrefix("custom:"), customService(for: providerID) == nil {
            throw TranscriptionClient.ClientError.notConfigured
        }
        guard let config = providerConfig(for: providerID) else {
            throw TranscriptionClient.ClientError.notConfigured
        }
        guard let apiKey = KeychainHelper.getAPIKey(account: keychainAccount(for: providerID)) else {
            throw TranscriptionClient.ClientError.noAPIKey
        }
        return .remote(apiKey: apiKey, config: config)
    }

    /// Активная конфигурация запросов. nil — у пресета не разбирается адрес
    /// либо выбран локальный сервис (у него нет ни эндпоинта, ни модели API).
    var providerConfig: ProviderConfig? {
        providerConfig(for: providerID)
    }

    func providerConfig(for providerID: String) -> ProviderConfig? {
        guard LocalModel.from(providerID: providerID) == nil else { return nil }
        if let service = customService(for: providerID) {
            guard let url = ProviderConfig.normalizeEndpoint(service.endpoint) else { return nil }
            let model = service.model.trimmingCharacters(in: .whitespacesAndNewlines)
            return ProviderConfig(endpoint: url,
                                  model: model.isEmpty ? TranscriptionProvider.custom.defaultModel : model)
        }
        guard let url = TranscriptionProvider.builtin.endpoint else { return nil }
        return ProviderConfig(endpoint: url, model: TranscriptionProvider.builtin.defaultModel)
    }

    /// Keychain-аккаунт ключа активного сервиса.
    var currentKeychainAccount: String {
        keychainAccount(for: providerID)
    }

    func keychainAccount(for providerID: String) -> String {
        customService(for: providerID)?.keychainAccount ?? TranscriptionProvider.builtin.keychainAccount
    }

    /// Метка сервиса для записей (история, библиотека) по id сервиса.
    func providerTag(for providerID: String) -> String {
        if let local = LocalModel.from(providerID: providerID) { return local.title }
        return customService(for: providerID)?.name ?? TranscriptionProvider.builtin.rawValue
    }

    /// Сохранять ли архив исходного звука файловых транскрибаций (m4a
    /// 16 кГц mono) — для плеера и повторного распознавания. Действует на
    /// новые записи; уже сохранённое стирается только кнопкой в «Расширенных».
    @Published var saveTranscriptAudio: Bool {
        didSet { defaults.set(saveTranscriptAudio, forKey: Key.saveTranscriptAudio) }
    }
    /// Системное уведомление о готовности (или ошибке) файловой транскрибации,
    /// когда результат не на глазах (`FileTranscriptionNotifier`).
    @Published var notifyFileTranscription: Bool {
        didSet { defaults.set(notifyFileTranscription, forKey: Key.notifyFileTranscription) }
    }

    /// API-ключ активного сервиса. У локального сервиса ключа нет — Keychain
    /// намеренно не трогаем (синхронное чтение в пути запуска может заморозить
    /// приложение диалогом подтверждения доступа).
    var currentAPIKey: String? {
        guard selectedLocalModel == nil else { return nil }
        return KeychainHelper.getAPIKey(account: currentKeychainAccount)
    }

    /// Метка сервиса для записей истории: builtin остаётся rawValue
    /// (история маппит его в локализованное название), пресет — своё имя,
    /// локальная модель — её название (показывается как есть).
    var providerTagForHistory: String {
        if let local = selectedLocalModel { return local.title }
        return selectedCustomService?.name ?? TranscriptionProvider.builtin.rawValue
    }

    /// Удаляет пресет вместе с его ключом; если он был выбран — возврат
    /// на встроенный сервис.
    func deleteCustomService(_ id: UUID) {
        if let service = customServices.first(where: { $0.id == id }) {
            KeychainHelper.deleteAPIKey(account: service.keychainAccount)
        }
        customServices.removeAll { $0.id == id }
        if providerID == "custom:\(id.uuidString)" {
            providerID = TranscriptionProvider.builtin.rawValue
        }
    }

    private func persistCustomServices() {
        if let data = try? JSONEncoder().encode(customServices) {
            defaults.set(data, forKey: Key.customServices)
        }
    }

    /// Показывать иконку приложения в Dock (и в Cmd+Tab). Применяется на лету:
    /// прецедент побочных эффектов в didSet — appLanguage/launchAtLogin.
    @Published var showDockIcon: Bool {
        didSet {
            defaults.set(showDockIcon, forKey: Key.showDockIcon)
            NSApp.setActivationPolicy(showDockIcon ? .regular : .accessory)
            // Смена политики роняет фокус — возвращаем его открытому окну.
            WindowManager.shared.refocusMain()
        }
    }
    /// Открывать главное окно при запуске приложения (иначе тихий старт
    /// в меню-баре, и факт запуска легко не заметить).
    @Published var openWindowAtLaunch: Bool {
        didSet { defaults.set(openWindowAtLaunch, forKey: Key.openWindowAtLaunch) }
    }
    /// Номер кнопки мыши для старта/остановки диктовки (NSEvent.buttonNumber,
    /// боковые кнопки — 3/4 и далее). −1 — не назначена.
    @Published var mouseShortcutButton: Int {
        didSet { defaults.set(mouseShortcutButton, forKey: Key.mouseShortcutButton) }
    }

    /// Автозапуск при входе через SMAppService.
    @Published var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != (SMAppService.mainApp.status == .enabled) else { return }
            do {
                if launchAtLogin {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                NSLog("DOKA: не удалось изменить автозапуск: \(error.localizedDescription)")
                launchAtLogin = SMAppService.mainApp.status == .enabled
            }
        }
    }

    private init() {
        defaults.register(defaults: [
            Key.language: "ru",
            Key.soundsEnabled: true,
            Key.restoreClipboard: true,
            Key.onboardingCompleted: false,
            Key.provider: TranscriptionProvider.builtin.rawValue,
            Key.saveAudio: false,
            Key.micAutoBoost: false,
            Key.silenceRemoval: false,
            Key.soundVolume: 1.0,
            Key.showDockIcon: false,
            Key.openWindowAtLaunch: true,
            Key.mouseShortcutButton: -1,
            Key.skipSilentRecordings: true,
            Key.applyDictionaryToFiles: false,
            Key.saveTranscriptAudio: true,
            Key.notifyFileTranscription: true
        ])
        notifyFileTranscription = defaults.bool(forKey: Key.notifyFileTranscription)
        skipSilentRecordings = defaults.bool(forKey: Key.skipSilentRecordings)
        applyDictionaryToFiles = defaults.bool(forKey: Key.applyDictionaryToFiles)
        libraryRetentionNoticeDismissed = defaults.bool(forKey: Key.libraryRetentionNoticeDismissed)
        saveTranscriptAudio = defaults.bool(forKey: Key.saveTranscriptAudio)
        language = defaults.string(forKey: Key.language) ?? "ru"
        soundsEnabled = defaults.bool(forKey: Key.soundsEnabled)
        soundVolume = defaults.double(forKey: Key.soundVolume)
        micAutoBoost = defaults.bool(forKey: Key.micAutoBoost)
        silenceRemoval = defaults.bool(forKey: Key.silenceRemoval)
        showDockIcon = defaults.bool(forKey: Key.showDockIcon)
        openWindowAtLaunch = defaults.bool(forKey: Key.openWindowAtLaunch)
        mouseShortcutButton = defaults.integer(forKey: Key.mouseShortcutButton)
        restoreClipboard = defaults.bool(forKey: Key.restoreClipboard)
        onboardingCompleted = defaults.bool(forKey: Key.onboardingCompleted)
        providerID = defaults.string(forKey: Key.provider) ?? TranscriptionProvider.builtin.rawValue
        if let data = defaults.data(forKey: Key.customServices),
           let services = try? JSONDecoder().decode([CustomService].self, from: data) {
            customServices = services
        } else {
            customServices = []
        }
        recorderStyle = RecorderStyle(rawValue: defaults.string(forKey: Key.recorderStyle) ?? "") ?? .classic
        appLanguage = AppLanguage(rawValue: defaults.string(forKey: Key.appLanguage) ?? "") ?? .system
        typingSpeedWPM = defaults.double(forKey: Key.typingSpeedWPM)
        saveAudio = defaults.bool(forKey: Key.saveAudio)
        audioRetention = AudioRetention(rawValue: defaults.string(forKey: Key.audioRetention) ?? "") ?? .forever
        transcriptRetention = TranscriptRetention.resolve(stored: defaults.string(forKey: Key.transcriptRetention))
        if let data = defaults.data(forKey: Key.replacements),
           let rules = try? JSONDecoder().decode([ReplacementRule].self, from: data) {
            replacements = rules
        } else {
            replacements = []
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
        migrateLegacyServices()
    }

    /// Одноразовый перенос прежних сервисов (openai/groq/«свой») в пресеты:
    /// в UI остались только «Встроенный» и пользовательские, но ничей рабочий
    /// сервис и ключ не должны пропасть. didSet в init не срабатывают —
    /// persist здесь ручной.
    private func migrateLegacyServices() {
        guard !defaults.bool(forKey: Key.servicesMigrated) else { return }
        defaults.set(true, forKey: Key.servicesMigrated)
        switch providerID {
        case "openai":
            adoptLegacyService(endpoint: "https://api.openai.com/v1",
                               model: "whisper-1", oldAccount: "api-key-openai")
        case "groq":
            adoptLegacyService(endpoint: "https://api.groq.com/openai/v1",
                               model: "whisper-large-v3", oldAccount: "api-key-groq")
        case "custom":
            let endpoint = (defaults.string(forKey: "customEndpoint") ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if endpoint.isEmpty {
                providerID = TranscriptionProvider.builtin.rawValue
            } else {
                adoptLegacyService(endpoint: endpoint,
                                   model: defaults.string(forKey: "customModel") ?? "",
                                   oldAccount: "api-key-custom")
            }
        default:
            return
        }
        persistCustomServices()
        defaults.set(providerID, forKey: Key.provider)
    }

    private func adoptLegacyService(endpoint: String, model: String, oldAccount: String) {
        let service = CustomService(
            id: UUID(),
            name: CustomService.makeName(endpoint: endpoint, model: model),
            endpoint: endpoint,
            model: model
        )
        customServices.append(service)
        if let key = KeychainHelper.getAPIKey(account: oldAccount) {
            KeychainHelper.setAPIKey(key, account: service.keychainAccount)
            KeychainHelper.deleteAPIKey(account: oldAccount)
        }
        providerID = "custom:\(service.id.uuidString)"
    }
}
