import AppKit
import Carbon.HIToolbox
import Foundation
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// Старт/стоп диктовки. По умолчанию Option+Tab — как в VoiceInk пользователя.
    static let toggleRecording = Self("toggleRecording", initial: .init(.tab, modifiers: [.option]))
    /// Push-to-talk: зажать — запись, отпустить — распознавание. Без дефолта.
    static let pushToTalk = Self("pushToTalk")
    /// Повторная вставка последней транскрипции.
    static let pasteLast = Self("pasteLast", initial: .init(.v, modifiers: [.control, .option]))
    /// Отмена записи. Активен только во время записи.
    static let cancelRecording = Self("cancelRecording", initial: .init(.escape))
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
    private var fnGesture = FnKeyGesture()
    private var fnStartTask: Task<Void, Never>?

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
        installFnMonitors()
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

    // MARK: - Клавиша Fn (🌐)

    /// Событие клавиатуры, нужное автомату Fn, — извлекается из NSEvent сразу
    /// в обработчике монитора (сам NSEvent через границу Task не передать).
    private enum FnInput {
        case fnDown(TimeInterval), fnUp(TimeInterval), otherKey(TimeInterval)

        init?(_ event: NSEvent) {
            switch event.type {
            case .flagsChanged where event.keyCode == UInt16(kVK_Function):
                self = event.modifierFlags.contains(.function)
                    ? .fnDown(event.timestamp) : .fnUp(event.timestamp)
            case .keyDown:
                self = .otherKey(event.timestamp)
            default:
                return nil
            }
        }
    }

    /// Fn — не клавиша KeyboardShortcuts (одиночный модификатор она не
    /// назначает), поэтому — свои мониторы `.flagsChanged`, как у кнопки
    /// мыши: глобальный (другие приложения) и локальный (окна DOKA).
    private func installFnMonitors() {
        NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            guard let input = FnInput(event) else { return }
            Task { @MainActor in self?.handleFn(input) }
        }
        NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            if let input = FnInput(event) {
                Task { @MainActor in self?.handleFn(input) }
            }
            return event
        }
    }

    private func handleFn(_ input: FnInput) {
        let mode = SettingsStore.shared.fnKeyMode
        // Выключено — нажатие, начатое до выключения, всё равно доводим до
        // конца: иначе запись, начатая удержанием, осталась бы без стопа.
        guard mode != .off || fnGesture.isDown else { return }
        switch input {
        case .fnDown(let time): perform(fnGesture.fnDown(at: time, mode: mode))
        case .fnUp(let time): perform(fnGesture.fnUp(at: time))
        case .otherKey(let time): perform(fnGesture.otherKey(at: time))
        }
    }

    private func perform(_ action: FnKeyGesture.Action) {
        switch action {
        case .none:
            break
        case .scheduleStart(let delay):
            fnStartTask?.cancel()
            fnStartTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, let self else { return }
                self.perform(self.fnGesture.startDelayElapsed(at: ProcessInfo.processInfo.systemUptime))
            }
        case .start:
            controller.pushToTalkDown()
        case .stop:
            fnStartTask?.cancel()
            controller.pushToTalkUp()
        case .cancel:
            fnStartTask?.cancel()
            // Отменяется только запись: распознавание отменяет сам
            // пользователь — по Esc.
            if controller.state.isRecording { controller.cancel() }
        case .toggle:
            controller.toggle()
        }
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
