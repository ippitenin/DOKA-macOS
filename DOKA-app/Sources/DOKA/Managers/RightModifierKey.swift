import AppKit
import Carbon.HIToolbox
import Combine
import KeyboardShortcuts

/// Правая клавиша-модификатор как самостоятельный хоткей. KeyboardShortcuts
/// (Carbon) одиночный модификатор не назначает и левый от правого не
/// отличает, поэтому эти клавиши ловятся своими мониторами `.flagsChanged`
/// (`HotkeyManager`), а назначения хранятся отдельно (`RightModifierKeys`).
enum RightModifierKey: String, CaseIterable {
    case option
    case command

    /// Виртуальный код клавиши в событии `.flagsChanged`.
    var keyCode: UInt16 {
        switch self {
        case .option: return UInt16(kVK_RightOption)
        case .command: return UInt16(kVK_RightCommand)
        }
    }

    /// Аппаратно-зависимый бит нажатия (`NX_DEVICERALTKEYMASK` /
    /// `NX_DEVICERCMDKEYMASK`): общий флаг `.option` не годится — при
    /// зажатом левом ⌥ он остаётся и после отпускания правого.
    var deviceMask: UInt {
        switch self {
        case .option: return 0x40
        case .command: return 0x10
        }
    }

    /// Аппаратно-независимый флаг этой клавиши.
    var flag: NSEvent.ModifierFlags {
        switch self {
        case .option: return .option
        case .command: return .command
        }
    }

    /// Модификатор Carbon: так клавиша выглядит для зарегистрированных
    /// сочетаний, пока её держат (⌃⇧Пробел при правом ⌥ = ⌃⌥⇧Пробел).
    var carbonModifier: Int {
        switch self {
        case .option: return optionKey
        case .command: return cmdKey
        }
    }

    var title: String {
        switch self {
        case .option: return L("hotkeys.rightOption")
        case .command: return L("hotkeys.rightCommand")
        }
    }

    init?(keyCode: UInt16) {
        guard let key = Self.allCases.first(where: { $0.keyCode == keyCode }) else { return nil }
        self = key
    }

    /// Нажата ли клавиша по флагам события.
    func isDown(in flags: NSEvent.ModifierFlags) -> Bool {
        flags.rawValue & deviceMask != 0
    }

    /// Общий бит клавиши в флагах Quartz.
    var cgFlag: CGEventFlags {
        switch self {
        case .option: return .maskAlternate
        case .command: return .maskCommand
        }
    }

    /// Страховка отпускания по `CGEventSource.flagsState`: клавиша точно
    /// отпущена, если в флагах нет даже общего бита. `keyState` по коду
    /// 61/54 для этого НЕ годится — правые модификаторы он не ведёт и
    /// отвечает «отпущено» при зажатой клавише: запись сбрасывалась через
    /// 20 мс после старта. Цена — при зажатом вместе левом ⌥ страховка
    /// молчит; обычное отпускание всё равно приходит событием.
    static func isReleased(_ key: RightModifierKey, in flags: CGEventFlags) -> Bool {
        !flags.contains(key.cgFlag)
    }
}

/// Какие команды DOKA назначены на правые клавиши. Одна клавиша — одна
/// команда. Назначение и обычное сочетание у команды взаимоисключающие:
/// это следит рекордер (`HotkeyRecorder`).
@MainActor
final class RightModifierKeys: ObservableObject {
    static let shared = RightModifierKeys()

    static let storageKey = "rightModifierKeys"

    /// Команды, которым можно назначить правую клавишу. Esc фиксирован,
    /// кнопка мыши — свой рекордер.
    static let assignable: [KeyboardShortcuts.Name] = [
        .toggleRecording, .pushToTalk, .lockOrPause, .pasteLast,
        .toggleQuietMode, .openMainWindow, .openHistoryWindow
    ]

    /// `rawValue` команды → клавиша.
    @Published private(set) var assignments: [String: RightModifierKey]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let raw = defaults.dictionary(forKey: Self.storageKey) as? [String: String] ?? [:]
        assignments = raw.compactMapValues(RightModifierKey.init(rawValue:))
    }

    func key(for name: KeyboardShortcuts.Name) -> RightModifierKey? {
        assignments[name.rawValue]
    }

    /// Команда, на которую назначена клавиша.
    func name(for key: RightModifierKey) -> KeyboardShortcuts.Name? {
        Self.assignable.first { assignments[$0.rawValue] == key }
    }

    /// Назначает клавишу. Занята другой командой — отказ с её именем.
    @discardableResult
    func assign(_ key: RightModifierKey, to name: KeyboardShortcuts.Name) -> KeyboardShortcuts.Name? {
        if let owner = self.name(for: key), owner != name { return owner }
        assignments[name.rawValue] = key
        save()
        return nil
    }

    func clear(_ name: KeyboardShortcuts.Name) {
        guard assignments.removeValue(forKey: name.rawValue) != nil else { return }
        save()
    }

    private func save() {
        defaults.set(assignments.mapValues(\.rawValue), forKey: Self.storageKey)
    }
}
