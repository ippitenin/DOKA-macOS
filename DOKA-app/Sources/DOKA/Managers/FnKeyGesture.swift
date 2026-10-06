import AppKit

/// Режим клавиши Fn (🌐) как хоткея диктовки.
enum FnKeyMode: String, CaseIterable {
    case off
    /// Удерживать — говорить, отпустить — распознать (как push-to-talk).
    case hold
    /// Короткое нажатие — старт, ещё одно — стоп (как основной хоткей).
    case toggle

    var title: String {
        switch self {
        case .off: return L("hotkeys.fn.off")
        case .hold: return L("hotkeys.fn.hold")
        case .toggle: return L("hotkeys.fn.toggle")
        }
    }
}

/// Клавиша Fn как хоткей: чистый автомат «события клавиатуры и время →
/// действие». Таймер задержки и вызовы `DictationController` — у
/// `HotkeyManager`, поэтому всё решение проверяется тестами без клавиатуры.
///
/// Fn — ещё и модификатор: Fn+стрелки (Home/End), Fn+Delete, Fn+F-клавиши.
/// Такие сочетания не должны запускать запись, поэтому при удержании старт
/// отложен, а другая клавиша при зажатой Fn превращает нажатие в сочетание.
struct FnKeyGesture {
    enum Action: Equatable {
        case none
        /// Запустить таймер и по нему позвать `startDelayElapsed`.
        case scheduleStart(after: TimeInterval)
        case start
        case stop
        case cancel
        case toggle
    }

    /// Задержка старта при удержании: сочетание успевает начаться раньше.
    static let holdStartDelay: TimeInterval = 0.2
    /// Сочетание вскоре после старта — тоже не диктовка: запись отменяется.
    /// Позже другая клавиша уже не трогает идущую запись — это случайность,
    /// а не сочетание, и терять из-за неё надиктованное нельзя.
    static let comboCancelWindow: TimeInterval = 1.0
    /// Нажатие для старт-стопа; дольше — человек передумал.
    static let tapMaxDuration: TimeInterval = 0.5

    private(set) var isDown = false
    /// Режим берётся в момент нажатия: смена настройки посреди нажатия его
    /// не ломает.
    private var mode: FnKeyMode = .off
    private var downAt: TimeInterval = 0
    private var combo = false
    private var startedAt: TimeInterval?

    mutating func fnDown(at time: TimeInterval, mode: FnKeyMode) -> Action {
        guard !isDown else { return .none }
        isDown = true
        self.mode = mode
        downAt = time
        combo = false
        startedAt = nil
        return mode == .hold ? .scheduleStart(after: Self.holdStartDelay) : .none
    }

    mutating func startDelayElapsed(at time: TimeInterval) -> Action {
        guard mode == .hold, isDown, !combo, startedAt == nil else { return .none }
        startedAt = time
        return .start
    }

    mutating func otherKey(at time: TimeInterval) -> Action {
        guard isDown else { return .none }
        combo = true
        if mode == .hold, let started = startedAt, time - started < Self.comboCancelWindow {
            startedAt = nil
            return .cancel
        }
        return .none
    }

    mutating func fnUp(at time: TimeInterval) -> Action {
        guard isDown else { return .none }
        isDown = false
        switch mode {
        case .off:
            return .none
        case .hold:
            guard startedAt != nil else { return .none }
            startedAt = nil
            return .stop
        case .toggle:
            return !combo && time - downAt <= Self.tapMaxDuration ? .toggle : .none
        }
    }
}

/// Что macOS делает по нажатию 🌐 (Системные настройки → «Клавиатура» →
/// «Нажатие клавиши 🌐»). Если не «ничего не делать», система реагирует на
/// Fn вместе с DOKA: переключает раскладку, открывает эмодзи или диктовку.
enum SystemFnKeyUsage {
    private static let domain = "com.apple.HIToolbox" as CFString
    private static let key = "AppleFnUsageType" as CFString

    /// `true` только при явном «ничего не делать» (0). Ключа нет — у системы
    /// своё действие по умолчанию, значит конфликт есть.
    static var doesNothing: Bool {
        // Значение могли поменять в Системных настройках, пока DOKA работала:
        // без синхронизации CFPreferences отдаст закэшированное.
        CFPreferencesAppSynchronize(domain)
        return (CFPreferencesCopyAppValue(key, domain) as? Int) == 0
    }

    static func openKeyboardSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }
}
