import Foundation

/// Чистая политика клавиш одной диктовки. Фиксация не меняет настройки.
/// Физическое удержание PTT переживает отмену/конец сессии: запоздалый keyUp
/// не должен завершать другую запись, начатую старт/стопом.
struct DictationControls {
    enum Mode: Equatable {
        case held
        case handsFree
        case paused
    }

    enum Action: Equatable {
        case none, startHeld, startHandsFree, finish, lock, pause, resume
    }

    private(set) var mode: Mode?
    private(set) var pushToTalkIsDown = false

    mutating func didStart(held: Bool) { mode = held ? .held : .handsFree }
    mutating func didEnd() { mode = nil }

    func toggle() -> Action { mode == nil ? .startHandsFree : .finish }

    mutating func pushToTalkDown() -> Action {
        guard !pushToTalkIsDown else { return .none }
        pushToTalkIsDown = true
        switch mode {
        case nil: return .startHeld
        case .held: return .none
        case .handsFree, .paused: return .finish
        }
    }

    mutating func pushToTalkUp() -> Action {
        guard pushToTalkIsDown else { return .none }
        pushToTalkIsDown = false
        return mode == .held ? .finish : .none
    }

    mutating func lockOrPause() -> Action {
        switch mode {
        case nil: return .none
        case .held:
            mode = .handsFree
            return .lock
        case .handsFree:
            mode = .paused
            return .pause
        case .paused:
            mode = .handsFree
            return .resume
        }
    }
}
