import AppKit
import Carbon.HIToolbox

/// Вставка текста в позицию курсора активного приложения:
/// текст кладётся в буфер обмена, затем синтезируется Cmd+V.
@MainActor
enum Paster {
    enum PasteError: LocalizedError {
        case secureInput
        case noAccessibility

        var errorDescription: String? {
            switch self {
            case .secureInput:
                return L("error.secureInput")
            case .noAccessibility:
                return L("error.noAccessibility")
            }
        }
    }

    private static var restoreTask: Task<Void, Never>?

    /// Вставляет текст. При restoreClipboard прежнее содержимое буфера вернётся
    /// через ~0.9 с — если за это время буфер не менялся кем-то ещё.
    static func paste(_ text: String, restoreClipboard: Bool) async throws {
        // Незавершённое восстановление от предыдущей вставки больше не актуально.
        restoreTask?.cancel()
        restoreTask = nil

        let previous = restoreClipboard ? ClipboardManager.snapshot() : nil
        ClipboardManager.setString(text)
        let ourChangeCount = NSPasteboard.general.changeCount

        guard !IsSecureEventInputEnabled() else {
            // В защищённом поле (пароль) синтетический Cmd+V не сработает —
            // оставляем текст в буфере, пользователь вставит сам.
            throw PasteError.secureInput
        }
        guard AXIsProcessTrusted() else {
            throw PasteError.noAccessibility
        }

        await waitForModifierRelease()
        try await sendCmdV()

        if let previous {
            restoreTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(900))
                guard !Task.isCancelled else { return }
                // Восстанавливаем только если буфер не трогали после нас.
                guard NSPasteboard.general.changeCount == ourChangeCount else { return }
                ClipboardManager.restore(previous)
            }
        }
    }

    /// Ждёт отпускания физических модификаторов (до 0.5 с): если послать Cmd+V,
    /// пока зажаты Ctrl+Option хоткея, целевое приложение получит Cmd+Ctrl+Option+V.
    private static func waitForModifierRelease() async {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(500))
        while ContinuousClock.now < deadline {
            let held = NSEvent.modifierFlags.intersection([.command, .option, .control, .shift])
            if held.isEmpty { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private static func sendCmdV() async throws {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        let vKey = CGKeyCode(kVK_ANSI_V)

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand

        keyDown?.post(tap: .cghidEventTap)
        // Именно `try?`: отмена (Esc во время вставки) между keyDown и keyUp
        // бросила бы CancellationError, keyUp не ушёл бы, и клавиша V осталась
        // бы «зажатой» на уровне HID — для ВСЕЙ системы, а не только для DOKA.
        // Отменённая вставка допустима, залипшая клавиша — нет.
        try? await Task.sleep(for: .milliseconds(10))
        keyUp?.post(tap: .cghidEventTap)
        // Пауза, чтобы целевое приложение успело обработать вставку.
        try await Task.sleep(for: .milliseconds(50))
    }
}
