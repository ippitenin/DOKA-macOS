import Combine
import Foundation

/// Разрешение ИИ-агенту — тумблер на странице «Доступ для ИИ-агентов».
/// Всё, что касается личных данных, по умолчанию закрыто (решение владельца
/// 8.11.2026); открыто только распознавание файлов, которые агент приносит сам.
/// rawValue хранится в UserDefaults — не переименовывать.
enum AgentPermission: String, CaseIterable, Identifiable {
    case transcribeFiles
    case libraryRead
    case libraryWrite
    case analysis
    case dictationHistory
    case dictionary
    /// Запись в словарь — отдельно от чтения: правило меняет текст, который
    /// человек диктует в другие приложения (подмена номера, адреса).
    case dictionaryWrite
    /// Обычный API для программ (OpenAI-совместимый `/v1/audio/transcriptions`):
    /// любая программа с токеном отправляет звук и получает текст.
    case openAIAPI

    var id: String { rawValue }

    var isOnByDefault: Bool { self == .transcribeFiles }

    /// Разрешения агента — без API для программ: у того своя карточка.
    static var agentCases: [AgentPermission] { allCases.filter { $0 != .openAIAPI } }

    /// Название тумблера. Ключи литеральные: скрипт проверки локализации
    /// находит их сам, без пополнения `DYNAMIC_PREFIXES`.
    var title: String {
        switch self {
        case .transcribeFiles: return L("agent.permission.transcribeFiles")
        case .libraryRead: return L("agent.permission.libraryRead")
        case .libraryWrite: return L("agent.permission.libraryWrite")
        case .analysis: return L("agent.permission.analysis")
        case .dictationHistory: return L("agent.permission.dictationHistory")
        case .dictionary: return L("agent.permission.dictionary")
        case .dictionaryWrite: return L("agent.permission.dictionaryWrite")
        case .openAIAPI: return L("agent.permission.openAIAPI")
        }
    }

    var help: String {
        switch self {
        case .transcribeFiles: return L("agent.permission.transcribeFiles.help")
        case .libraryRead: return L("agent.permission.libraryRead.help")
        case .libraryWrite: return L("agent.permission.libraryWrite.help")
        case .analysis: return L("agent.permission.analysis.help")
        case .dictationHistory: return L("agent.permission.dictationHistory.help")
        case .dictionary: return L("agent.permission.dictionary.help")
        case .dictionaryWrite: return L("agent.permission.dictionaryWrite.help")
        case .openAIAPI: return L("agent.permission.openAIAPI.help")
        }
    }

    /// Ответ агенту, когда тумблер выключен: где его включить. Агент
    /// пересказывает это человеку, поэтому текст — на языке интерфейса.
    var denialMessage: String { L("agent.denied", title) }
}

/// Кто вправе что делать с записью библиотеки. Чистые правила.
///
/// Свои записи агента (созданные через `transcribe_file`) — его рабочий
/// результат: читать, отменять, переименовывать и удалять их можно с одним
/// «Распознавать файлы». Иначе распознавание было бы бесполезно без доступа
/// ко всей библиотеке человека.
enum AgentAccessPolicy {
    static func canRead(createdByAgent: Bool, permissions: Set<AgentPermission>) -> Bool {
        createdByAgent ? permissions.contains(.transcribeFiles) : permissions.contains(.libraryRead)
    }

    static func canModify(createdByAgent: Bool, permissions: Set<AgentPermission>) -> Bool {
        createdByAgent ? permissions.contains(.transcribeFiles) : permissions.contains(.libraryWrite)
    }

    /// Разрешение, которого не хватает для действия с записью; nil — хватает.
    static func missingForRead(createdByAgent: Bool, permissions: Set<AgentPermission>) -> AgentPermission? {
        guard !canRead(createdByAgent: createdByAgent, permissions: permissions) else { return nil }
        return createdByAgent ? .transcribeFiles : .libraryRead
    }

    static func missingForModify(createdByAgent: Bool, permissions: Set<AgentPermission>) -> AgentPermission? {
        guard !canModify(createdByAgent: createdByAgent, permissions: permissions) else { return nil }
        return createdByAgent ? .transcribeFiles : .libraryWrite
    }
}

/// Настройки доступа агентов: главный тумблер, порт и разрешения. Отдельно от
/// `SettingsStore`: вся область живёт в папке `Agent/`, а UserDefaults общий.
@MainActor
final class AgentAccessSettings: ObservableObject {
    static let shared = AgentAccessSettings(defaults: .standard)

    /// Порт по умолчанию: вне системных и популярных портов разработки.
    nonisolated static let defaultPort = 47_800
    nonisolated static let portRange = 1_024...65_535

    private enum Key {
        static let enabled = "agentAccessEnabled"
        static let port = "agentAccessPort"
        static let permissions = "agentAccessPermissions"
    }

    private let defaults: UserDefaults

    /// Главный тумблер: сервер слушает порт, только пока он включён.
    @Published var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Key.enabled) }
    }

    @Published var port: Int {
        didSet {
            // Присваивание внутри своего didSet наблюдателя повторно не зовёт.
            let clamped = min(max(port, Self.portRange.lowerBound), Self.portRange.upperBound)
            if clamped != port { port = clamped }
            defaults.set(port, forKey: Key.port)
        }
    }

    @Published private(set) var permissions: Set<AgentPermission> {
        didSet { defaults.set(permissions.map(\.rawValue).sorted(), forKey: Key.permissions) }
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: Key.enabled)
        let storedPort = defaults.integer(forKey: Key.port)
        port = Self.portRange.contains(storedPort) ? storedPort : Self.defaultPort
        if let raw = defaults.array(forKey: Key.permissions) as? [String] {
            // Неизвестное значение (из будущей версии) пропускается.
            permissions = Set(raw.compactMap(AgentPermission.init(rawValue:)))
        } else {
            permissions = Set(AgentPermission.allCases.filter(\.isOnByDefault))
        }
    }

    func isAllowed(_ permission: AgentPermission) -> Bool { permissions.contains(permission) }

    func set(_ permission: AgentPermission, allowed: Bool) {
        if allowed { permissions.insert(permission) } else { permissions.remove(permission) }
    }
}
