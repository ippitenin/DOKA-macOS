import AppKit
import Carbon.HIToolbox
import KeyboardShortcuts

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

    /// Прошлая вставка — для пробела между диктовками подряд (`PasteSpacing`).
    /// Любое нажатие клавиши или клик после неё её сбрасывает: тогда уже
    /// неизвестно, что стоит перед курсором.
    private static var lastPaste: PasteSpacing.Previous?
    private static var activityMonitor: Any?

    /// Метка синтетических событий DOKA (`eventSourceUserData`): глобальный
    /// монитор видит и наш собственный Cmd+V, и его нельзя принять за ввод
    /// пользователя — иначе пробел не ставился бы никогда.
    private static let syntheticEventTag: Int64 = 0x444F_4B41   // «DOKA»

    /// Клавиши самой DOKA: нажатие хоткея диктовки между двумя вставками
    /// текста в поле не меняет и прошлую вставку не сбрасывает.
    private static let ownShortcuts: [KeyboardShortcuts.Name] = [
        .toggleRecording, .pushToTalk, .pasteLast, .cancelRecording,
        .toggleQuietMode, .openMainWindow, .openHistoryWindow
    ]

    /// Вставляет текст. При restoreClipboard прежнее содержимое буфера вернётся
    /// через ~0.9 с — если за это время буфер не менялся кем-то ещё. При
    /// `spacing` перед текстом встаёт пробел, если это продолжение прошлой
    /// вставки (см. `PasteSpacing`); в буфер на случай отказа кладётся текст
    /// без него — куда вставит пользователь, неизвестно.
    static func paste(_ text: String, restoreClipboard: Bool, spacing: Bool) async throws {
        // Незавершённое восстановление от предыдущей вставки больше не актуально.
        restoreTask?.cancel()
        restoreTask = nil

        let previous = restoreClipboard ? ClipboardManager.snapshot() : nil
        // В защищённом поле (пароль) синтетический Cmd+V не сработает —
        // текст остаётся в буфере, пользователь вставит сам.
        let secureInput = IsSecureEventInputEnabled()
        let trusted = AXIsProcessTrusted()
        let target = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let prefix = spacing && !secureInput && trusted
            ? PasteSpacing.prefix(previous: lastPaste, next: text, targetPID: target, now: Date())
            : ""
        ClipboardManager.setString(prefix + text)
        let ourChangeCount = NSPasteboard.general.changeCount

        guard !secureInput else { throw PasteError.secureInput }
        guard trusted else { throw PasteError.noAccessibility }

        await waitForModifierRelease()
        // Запоминаем ДО Cmd+V: отмена посреди `sendCmdV` приходит уже после
        // того, как клавиши ушли и текст вставлен.
        lastPaste = PasteSpacing.Previous(text: prefix + text, date: Date(), targetPID: target)
        if spacing { installActivityMonitor() }
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

    /// Глобальный монитор ввода: клавиша (кроме наших хоткеев и нашего же
    /// Cmd+V) или клик после вставки сбрасывают прошлую вставку. Ставится
    /// один раз — при первой вставке с пробелами.
    private static func installActivityMonitor() {
        guard activityMonitor == nil else { return }
        activityMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown]
        ) { event in
            let isKey = event.type == .keyDown
            let tag = isKey ? event.cgEvent?.getIntegerValueField(.eventSourceUserData) : nil
            let shortcut = isKey ? KeyboardShortcuts.Shortcut(event: event) : nil
            Task { @MainActor in
                if tag == syntheticEventTag { return }
                if let shortcut,
                   ownShortcuts.contains(where: { KeyboardShortcuts.getShortcut(for: $0) == shortcut }) {
                    return
                }
                lastPaste = nil
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
        keyDown?.setIntegerValueField(.eventSourceUserData, value: syntheticEventTag)
        keyUp?.setIntegerValueField(.eventSourceUserData, value: syntheticEventTag)

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
