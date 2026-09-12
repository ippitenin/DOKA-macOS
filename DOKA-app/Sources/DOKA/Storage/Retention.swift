import Foundation

// Сроки хранения пользовательских данных. Вынесены из SettingsStore: это не
// настройки стора, а правила, по которым НЕОБРАТИМО удаляются записи и аудио,
// — их стоит читать отдельно от списка @Published-свойств.
// Покрыты RetentionTests.

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
