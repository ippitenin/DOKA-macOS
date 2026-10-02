import AppKit
import Foundation
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// Старт/стоп диктовки. По умолчанию Option+Tab — как в VoiceInk пользователя.
    static let toggleRecording = Self("toggleRecording", default: .init(.tab, modifiers: [.option]))
    /// Push-to-talk: зажать — запись, отпустить — распознавание. Без дефолта.
    static let pushToTalk = Self("pushToTalk")
    /// Повторная вставка последней транскрипции.
    static let pasteLast = Self("pasteLast", default: .init(.v, modifiers: [.control, .option]))
    /// Отмена записи. Активен только во время записи.
    static let cancelRecording = Self("cancelRecording", default: .init(.escape))
    /// Открыть главное окно. Без дефолта: глобальный Cmd+, отобрал бы
    /// «Настройки» у всех приложений системы.
    static let openMainWindow = Self("openMainWindow")
    /// Открыть окно на секции «История». Без дефолта.
    static let openHistoryWindow = Self("openHistoryWindow")
    /// Включить/выключить тихий режим (диктовка шёпотом). Без дефолта.
    static let toggleQuietMode = Self("toggleQuietMode")
}

/// Захват кнопки мыши в «Клавишах»: пока пользователь назначает кнопку,
/// глобальный обработчик не должен реагировать на её нажатие.
@MainActor
enum MouseShortcutCapture {
    static var isCapturing = false
}

/// Регистрация глобальных горячих клавиш и кнопки мыши.
@MainActor
final class HotkeyManager {
    private let controller: DictationController

    init(controller: DictationController) {
        self.controller = controller

        KeyboardShortcuts.onKeyDown(for: .toggleRecording) { [weak controller] in
            controller?.toggle()
        }
        KeyboardShortcuts.onKeyDown(for: .pushToTalk) { [weak controller] in
            controller?.pushToTalkDown()
        }
        KeyboardShortcuts.onKeyUp(for: .pushToTalk) { [weak controller] in
            controller?.pushToTalkUp()
        }
        KeyboardShortcuts.onKeyDown(for: .pasteLast) { [weak controller] in
            controller?.pasteLastTranscription()
        }
        KeyboardShortcuts.onKeyDown(for: .cancelRecording) { [weak controller] in
            controller?.cancel()
        }
        KeyboardShortcuts.onKeyDown(for: .openMainWindow) {
            WindowManager.shared.showMain(section: .home)
        }
        KeyboardShortcuts.onKeyDown(for: .openHistoryWindow) {
            WindowManager.shared.showMain(section: .history)
        }
        KeyboardShortcuts.onKeyDown(for: .toggleQuietMode) { [weak controller] in
            controller?.toggleQuietMode()
        }
        // Esc включается только на время записи (см. setEscapeEnabled).
        KeyboardShortcuts.disable(.cancelRecording)

        installMouseMonitors()
    }

    // MARK: - Кнопка мыши

    /// Боковые кнопки мыши приходят событием .otherMouseDown (номера от 2).
    /// Глобальный монитор ловит клики в других приложениях (только чтение,
    /// событие не поглощается), локальный — в окнах DOKA.
    private func installMouseMonitors() {
        NSEvent.addGlobalMonitorForEvents(matching: .otherMouseDown) { [weak self] event in
            let button = event.buttonNumber
            Task { @MainActor in self?.handleMouseButton(button) }
        }
        NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown) { [weak self] event in
            let button = event.buttonNumber
            Task { @MainActor in self?.handleMouseButton(button) }
            return event
        }
    }

    private func handleMouseButton(_ button: Int) {
        guard !MouseShortcutCapture.isCapturing else { return }
        let assigned = SettingsStore.shared.mouseShortcutButton
        guard assigned >= 2, button == assigned else { return }
        controller.toggle()
    }

    /// Включает/выключает глобальный Esc. Вызывается при каждом входе/выходе
    /// из состояния записи — иначе Esc останется перехваченным во всей системе.
    func setEscapeEnabled(_ enabled: Bool) {
        if enabled {
            KeyboardShortcuts.enable(.cancelRecording)
        } else {
            KeyboardShortcuts.disable(.cancelRecording)
        }
    }
}
