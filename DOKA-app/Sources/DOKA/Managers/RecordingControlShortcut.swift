import AppKit
import KeyboardShortcuts

/// Сочетание дополнительной команды с уже удерживаемыми модификаторами PTT.
/// Системное или назначенное другой команде сочетание не перехватывается.
@MainActor
enum RecordingControlShortcut {
    static func validate(_ shortcut: KeyboardShortcuts.Shortcut,
                         for name: KeyboardShortcuts.Name) -> KeyboardShortcuts.ValidationResult {
        let command = name == .lockOrPause ? shortcut : KeyboardShortcuts.getShortcut(for: .lockOrPause)
        guard let command else { return .allow }
        let others = KeyboardShortcuts.Name.dokaShortcuts.filter { $0 != .lockOrPause }
        if others.contains(where: { ($0 == name ? shortcut : KeyboardShortcuts.getShortcut(for: $0)) == command }) {
            return .disallow(reason: L("hotkeys.lockOrPause.conflict"))
        }
        // PTT записывается прямо сейчас — его сочетание вытеснит правую клавишу.
        let held = name == .pushToTalk
            ? HeldPushToTalk(shortcut: shortcut)
            : HeldPushToTalk.current()
        if let held {
            let combined = KeyboardShortcuts.Shortcut(
                carbonKeyCode: command.carbonKeyCode,
                carbonModifiers: command.carbonModifiers | held.carbonModifiers
            )
            if command.carbonKeyCode == held.carbonKeyCode || combined.isTakenBySystem
                || others.contains(where: { ($0 == name ? shortcut : KeyboardShortcuts.getShortcut(for: $0)) == combined }) {
                return .disallow(reason: L("hotkeys.lockOrPause.conflict"))
            }
        }
        return .allow
    }

    static func heldVariant(command: KeyboardShortcuts.Shortcut?,
                            pushToTalk: KeyboardShortcuts.Shortcut?,
                            active: Bool) -> KeyboardShortcuts.Shortcut? {
        heldVariant(command: command, held: pushToTalk.map(HeldPushToTalk.init(shortcut:)), active: active)
    }

    static func heldVariant(command: KeyboardShortcuts.Shortcut?,
                            held: HeldPushToTalk?,
                            active: Bool) -> KeyboardShortcuts.Shortcut? {
        guard active, let command, let held,
              command.carbonKeyCode != held.carbonKeyCode else { return nil }
        let variant = KeyboardShortcuts.Shortcut(
            carbonKeyCode: command.carbonKeyCode,
            carbonModifiers: command.carbonModifiers | held.carbonModifiers
        )
        guard variant != command, !variant.isTakenBySystem else { return nil }
        let otherCommands = KeyboardShortcuts.Name.dokaShortcuts.filter { $0 != .lockOrPause }
        guard !otherCommands.contains(where: { KeyboardShortcuts.getShortcut(for: $0) == variant }) else {
            return nil
        }
        return variant
    }
}

/// Что физически зажато, пока держат push-to-talk: основная клавиша
/// сочетания (у правой клавиши-модификатора её нет) и модификаторы Carbon.
struct HeldPushToTalk: Equatable {
    let carbonKeyCode: Int?
    let carbonModifiers: Int

    init(shortcut: KeyboardShortcuts.Shortcut) {
        carbonKeyCode = shortcut.carbonKeyCode
        carbonModifiers = shortcut.carbonModifiers
    }

    init(rightKey: RightModifierKey) {
        carbonKeyCode = nil
        carbonModifiers = rightKey.carbonModifier
    }

    /// Текущее назначение PTT: правая клавиша или сочетание.
    @MainActor
    static func current() -> HeldPushToTalk? {
        if let right = RightModifierKeys.shared.key(for: .pushToTalk) {
            return HeldPushToTalk(rightKey: right)
        }
        return KeyboardShortcuts.getShortcut(for: .pushToTalk).map(HeldPushToTalk.init(shortcut:))
    }
}
