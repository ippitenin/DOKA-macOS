import Foundation

/// Правая клавиша-модификатор как хоткей: чистый автомат «события клавиатуры
/// и время → действие». Таймер и вызовы контроллера — у `HotkeyManager`,
/// поэтому всё решение проверяется тестами без клавиатуры. Образец —
/// убранная клавиша Fn (`FnKeyGesture`, коммит 77c0e5c).
///
/// Правые ⌥ и ⌘ — ещё и модификаторы: ⌥+буква печатает «—» и «», ⌘+C
/// копирует. Такие сочетания не должны ни запускать запись, ни срабатывать
/// как нажатие команды.
struct RightModifierGesture {
    /// Как команда читает клавишу: push-to-talk — удержание, остальные —
    /// короткое нажатие.
    enum Kind: Equatable {
        case hold
        case tap
    }

    enum Action: Equatable {
        /// Запустить таймер и по нему позвать `startDelayElapsed`.
        case scheduleStart(RightModifierKey, after: TimeInterval)
        /// Удержание: начать запись (PTT вниз).
        case start(RightModifierKey)
        /// Удержание: клавишу отпустили (PTT вверх).
        case stop(RightModifierKey)
        /// Удержание оказалось сочетанием — запись отменить.
        case cancel(RightModifierKey)
        /// Короткое нажатие — выполнить команду.
        case fire(RightModifierKey)
    }

    /// Задержка старта при удержании: сочетание успевает начаться раньше.
    static let holdStartDelay: TimeInterval = 0.2
    /// Сочетание вскоре после старта — тоже не диктовка: запись отменяется.
    /// Позже другая клавиша идущую запись не трогает: это случайность, а не
    /// сочетание, и терять из-за неё надиктованное нельзя.
    static let comboCancelWindow: TimeInterval = 1.0
    /// Короткое нажатие; дольше — человек передумал.
    static let tapMaxDuration: TimeInterval = 0.5

    private struct Press {
        /// Вид берётся в момент нажатия: переназначение посреди нажатия его
        /// не ломает.
        let kind: Kind
        let downAt: TimeInterval
        var combo = false
        var startedAt: TimeInterval?
    }

    private var presses: [RightModifierKey: Press] = [:]

    func isDown(_ key: RightModifierKey) -> Bool { presses[key] != nil }

    mutating func keyDown(_ key: RightModifierKey, at time: TimeInterval, kind: Kind) -> [Action] {
        guard presses[key] == nil else { return [] }
        presses[key] = Press(kind: kind, downAt: time)
        return kind == .hold ? [.scheduleStart(key, after: Self.holdStartDelay)] : []
    }

    mutating func startDelayElapsed(_ key: RightModifierKey, at time: TimeInterval) -> [Action] {
        guard var press = presses[key], press.kind == .hold, !press.combo, press.startedAt == nil else {
            return []
        }
        press.startedAt = time
        presses[key] = press
        return [.start(key)]
    }

    /// Нажата обычная клавиша (не автоповтор). Каждое идущее нажатие
    /// становится сочетанием; свежая запись удержанием — отменяется.
    mutating func otherKey(at time: TimeInterval) -> [Action] {
        var actions: [Action] = []
        for key in RightModifierKey.allCases {
            guard var press = presses[key] else { continue }
            press.combo = true
            if press.kind == .hold, let started = press.startedAt, time - started < Self.comboCancelWindow {
                press.startedAt = nil
                actions.append(.cancel(key))
            }
            presses[key] = press
        }
        return actions
    }

    /// Нажали или отпустили другой модификатор (не назначенную правую
    /// клавишу), кликнули мышью или прокрутили. Короткому нажатию это
    /// сочетание (правый ⌘ + ⇧, ⌘+клик по ссылке, ⌘+прокрутка), а удержанию —
    /// нет: под удержанием нажимают ⌃⇧ команды фиксации и кликают по ходу диктовки.
    mutating func interruptTaps() {
        for key in RightModifierKey.allCases where presses[key]?.kind == .tap {
            presses[key]?.combo = true
        }
    }

    mutating func keyUp(_ key: RightModifierKey, at time: TimeInterval) -> [Action] {
        guard let press = presses.removeValue(forKey: key) else { return [] }
        switch press.kind {
        case .hold:
            return press.startedAt != nil ? [.stop(key)] : []
        case .tap:
            return !press.combo && time - press.downAt <= Self.tapMaxDuration ? [.fire(key)] : []
        }
    }
}
