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
        let ptt = name == .pushToTalk ? shortcut : KeyboardShortcuts.getShortcut(for: .pushToTalk)
        if let ptt {
            let combined = KeyboardShortcuts.Shortcut(
                carbonKeyCode: command.carbonKeyCode,
                carbonModifiers: command.carbonModifiers | ptt.carbonModifiers
            )
            if command.carbonKeyCode == ptt.carbonKeyCode || combined.isTakenBySystem
                || others.contains(where: { ($0 == name ? shortcut : KeyboardShortcuts.getShortcut(for: $0)) == combined }) {
                return .disallow(reason: L("hotkeys.lockOrPause.conflict"))
            }
        }
        return .allow
    }

    static func heldVariant(command: KeyboardShortcuts.Shortcut?,
                            pushToTalk: KeyboardShortcuts.Shortcut?,
                            active: Bool) -> KeyboardShortcuts.Shortcut? {
        guard active, let command, let pushToTalk,
              command.carbonKeyCode != pushToTalk.carbonKeyCode else { return nil }
        let variant = KeyboardShortcuts.Shortcut(
            carbonKeyCode: command.carbonKeyCode,
            carbonModifiers: command.carbonModifiers | pushToTalk.carbonModifiers
        )
        guard variant != command, !variant.isTakenBySystem else { return nil }
        let otherCommands = KeyboardShortcuts.Name.dokaShortcuts.filter { $0 != .lockOrPause }
        guard !otherCommands.contains(where: { KeyboardShortcuts.getShortcut(for: $0) == variant }) else {
            return nil
        }
        return variant
    }
}
