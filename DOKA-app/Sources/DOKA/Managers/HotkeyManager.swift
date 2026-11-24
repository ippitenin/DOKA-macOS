import AppKit
import Foundation
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// Старт/стоп диктовки. По умолчанию Option+Tab — как в VoiceInk пользователя.
    static let toggleRecording = Self("toggleRecording", initial: .init(.tab, modifiers: [.option]))
    /// Push-to-talk: зажать — запись, отпустить — распознавание. Без дефолта.
    static let pushToTalk = Self("pushToTalk")
    /// Только внутри диктовки: фиксация PTT, затем пауза/продолжение.
    static let lockOrPause = Self("lockOrPause", initial: .init(.space, modifiers: [.control, .shift]))
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

    /// Все клавиши DOKA. Новый хоткей — сюда же: нажатие своей клавиши между
    /// двумя вставками не считается вводом пользователя (`Paster`).
    static let dokaShortcuts: [Self] = [
        .toggleRecording, .pushToTalk, .pasteLast, .cancelRecording,
        .openMainWindow, .openHistoryWindow, .toggleQuietMode, .lockOrPause
    ]
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
    private var controlKeyIsDown = false
    private var heldVariant: KeyboardShortcuts.Shortcut?
    private var heldVariantTask: Task<Void, Never>?
    private var shortcutObserver: NSObjectProtocol?
    private var pushReleaseTask: Task<Void, Never>?
    private var rightGesture = RightModifierGesture()
    private var rightStartTasks: [RightModifierKey: Task<Void, Never>] = [:]

    init(controller: DictationController) {
        self.controller = controller

        KeyboardShortcuts.onKeyDown(for: .toggleRecording) { [weak controller] in
            controller?.toggle()
        }
        KeyboardShortcuts.onKeyDown(for: .pushToTalk) { [weak self] in
            self?.pushToTalkDown()
        }
        KeyboardShortcuts.onKeyUp(for: .pushToTalk) { [weak self] in
            self?.pushToTalkReleasedIfPhysicalKeyIsUp()
        }
        KeyboardShortcuts.onKeyDown(for: .lockOrPause) { [weak self] in
            self?.controlKeyDown()
        }
        KeyboardShortcuts.onKeyUp(for: .lockOrPause) { [weak self] in
            self?.controlKeyUp()
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
        KeyboardShortcuts.disable(.cancelRecording, .lockOrPause)
        // Переназначение при открытой диктовке обновляет и временное сочетание.
        shortcutObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncRecordingControls() }
        }

        installMouseMonitors()
        installRightModifierMonitors()
    }

    private var controlReleaseTask: Task<Void, Never>?

    private func pushToTalkDown() {
        controller.pushToTalkDown()
        syncRecordingControls()
        guard pushReleaseTask == nil,
              let shortcut = KeyboardShortcuts.getShortcut(for: .pushToTalk) else { return }
        // Carbon может прислать keyUp при добавлении модификаторов, хотя
        // основная клавиша всё ещё зажата. И наоборот, физический keyUp с
        // изменёнными модификаторами может не дойти. Проверяем саму клавишу.
        pushReleaseTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(20))
                guard !Task.isCancelled, let self else { return }
                if !CGEventSource.keyState(.combinedSessionState,
                                           key: CGKeyCode(shortcut.carbonKeyCode)) {
                    self.controller.pushToTalkUp()
                    self.pushReleaseTask = nil
                    self.syncRecordingControls()
                    return
                }
            }
        }
    }

    private func pushToTalkReleasedIfPhysicalKeyIsUp() {
        guard let shortcut = KeyboardShortcuts.getShortcut(for: .pushToTalk),
              !CGEventSource.keyState(.combinedSessionState,
                                      key: CGKeyCode(shortcut.carbonKeyCode)) else { return }
        pushReleaseTask?.cancel()
        pushReleaseTask = nil
        controller.pushToTalkUp()
        syncRecordingControls()
    }

    private func controlKeyDown() {
        guard !controlKeyIsDown else { return }
        controlKeyIsDown = true
        controller.lockOrPause()
        controlReleaseTask?.cancel()
        guard let shortcut = KeyboardShortcuts.getShortcut(for: .lockOrPause) else { return }
        controlReleaseTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(20))
                guard !Task.isCancelled, let self else { return }
                if !CGEventSource.keyState(.combinedSessionState,
                                           key: CGKeyCode(shortcut.carbonKeyCode)) {
                    self.controlKeyIsDown = false
                    return
                }
            }
        }
    }

    private func controlKeyUp() {
        guard let shortcut = KeyboardShortcuts.getShortcut(for: .lockOrPause),
              !CGEventSource.keyState(.combinedSessionState,
                                      key: CGKeyCode(shortcut.carbonKeyCode)) else { return }
        controlKeyIsDown = false
    }

    /// Carbon требует точного набора модификаторов. Пока удерживается PTT,
    /// регистрируем также сочетание «назначенная команда + модификаторы PTT»:
    /// например, при ⌥Tab команда ⌃⇧Пробел физически приходит как ⌃⌥⇧Пробел.
    /// Временная регистрация живёт только до отпускания PTT/конца записи.
    func syncRecordingControls() {
        let assignment = KeyboardShortcuts.getShortcut(for: .lockOrPause)
        let valid = assignment.map {
            RecordingControlShortcut.validate($0, for: .lockOrPause) == .allow
        } ?? false
        let active = controller.state.hasRecording && valid
        if active {
            KeyboardShortcuts.enable(.lockOrPause)
        } else {
            KeyboardShortcuts.disable(.lockOrPause)
            controlKeyIsDown = false
        }
        let variant = RecordingControlShortcut.heldVariant(
            command: KeyboardShortcuts.getShortcut(for: .lockOrPause),
            held: HeldPushToTalk.current(),
            active: active && controller.pushToTalkIsDown
        )
        guard variant != heldVariant else { return }
        heldVariantTask?.cancel()
        heldVariantTask = nil
        heldVariant = variant
        guard let variant else { return }
        let events = KeyboardShortcuts.events(for: variant)
        heldVariantTask = Task { [weak self] in
            for await event in events {
                guard !Task.isCancelled, let self else { break }
                if event == .keyDown {
                    self.controlKeyDown()
                } else {
                    self.controlKeyUp()
                }
            }
        }
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

    // MARK: - Правые ⌥ / ⌘

    /// Событие клавиатуры, нужное жесту правой клавиши, — извлекается из
    /// NSEvent сразу в обработчике монитора (сам NSEvent через границу Task
    /// не передать).
    private enum RightModifierInput {
        case flags(keyCode: UInt16, flags: NSEvent.ModifierFlags, time: TimeInterval)
        case key(keyCode: UInt16, time: TimeInterval)

        init?(_ event: NSEvent) {
            switch event.type {
            case .flagsChanged:
                self = .flags(keyCode: event.keyCode, flags: event.modifierFlags, time: event.timestamp)
            case .keyDown where !event.isARepeat:
                // Автоповтор зажатой клавиши (⌥Tab у PTT) — не новое нажатие.
                self = .key(keyCode: event.keyCode, time: event.timestamp)
            default:
                return nil
            }
        }
    }

    /// Одиночный модификатор KeyboardShortcuts не назначает, а левый от
    /// правого Carbon не отличает, — свои мониторы, как у кнопки мыши:
    /// глобальный (другие приложения) и локальный (окна DOKA). События не
    /// поглощаются: модификатор продолжает работать как модификатор.
    private func installRightModifierMonitors() {
        NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            guard let input = RightModifierInput(event) else { return }
            Task { @MainActor in self?.handleRightModifier(input) }
        }
        NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            if let input = RightModifierInput(event) {
                Task { @MainActor in self?.handleRightModifier(input) }
            }
            return event
        }
    }

    /// Идёт запись сочетания в «Клавишах»: нажатие назначают, а не выполняют.
    private static var isRecordingShortcut: Bool {
        (NSApp.keyWindow?.firstResponder as? NSText)?.delegate is KeyboardShortcuts.RecorderCocoa
    }

    private func handleRightModifier(_ input: RightModifierInput) {
        let keys = RightModifierKeys.shared
        switch input {
        case let .flags(keyCode, flags, time):
            guard let key = RightModifierKey(keyCode: keyCode), keys.name(for: key) != nil || rightGesture.isDown(key) else {
                // Другой модификатор или неназначенная правая клавиша.
                rightGesture.otherModifierChanged()
                return
            }
            if key.isDown(in: flags) {
                guard !Self.isRecordingShortcut, let name = keys.name(for: key) else { return }
                perform(rightGesture.keyDown(key, at: time, kind: name == .pushToTalk ? .hold : .tap))
            } else {
                // Отпускание доводим до конца всегда — даже если клавишу
                // переназначили посреди удержания: иначе запись осталась бы без стопа.
                perform(rightGesture.keyUp(key, at: time))
            }
        case let .key(keyCode, time):
            // Основная клавиша фиксации под удержанием — не сочетание: ⌃⇧Пробел
            // при правом ⌥ фиксирует запись, а не отменяет её.
            if controller.state.hasRecording,
               let command = KeyboardShortcuts.getShortcut(for: .lockOrPause),
               Int(keyCode) == command.carbonKeyCode { return }
            perform(rightGesture.otherKey(at: time))
        }
    }

    private func perform(_ actions: [RightModifierGesture.Action]) {
        for action in actions { perform(action) }
    }

    private func perform(_ action: RightModifierGesture.Action) {
        switch action {
        case let .scheduleStart(key, delay):
            rightStartTasks[key]?.cancel()
            rightStartTasks[key] = Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, let self else { return }
                self.perform(self.rightGesture.startDelayElapsed(key, at: ProcessInfo.processInfo.systemUptime))
            }
        case let .start(key):
            controller.pushToTalkDown()
            syncRecordingControls()
            watchRightKeyRelease(key)
        case let .stop(key):
            rightStartTasks[key]?.cancel()
            controller.pushToTalkUp()
            syncRecordingControls()
        case let .cancel(key):
            rightStartTasks[key]?.cancel()
            // Отменяется только запись: распознавание отменяет сам
            // пользователь — по Esc. Отпускание PTT сразу: жест его уже
            // забыл, а без него следующее удержание не запустило бы запись.
            if controller.state.isRecording { controller.cancel() }
            controller.pushToTalkUp()
            syncRecordingControls()
        case let .fire(key):
            guard let name = RightModifierKeys.shared.name(for: key) else { return }
            fire(name)
        }
    }

    /// Страховка удержания, как у PTT-сочетания: событие отпускания
    /// модификатора может не дойти (смена фокуса, защищённый ввод), и запись
    /// шла бы без конца. Пока клавишу держат, сверяемся с физическим
    /// состоянием; задача живёт в том же слоте, что и таймер старта.
    private func watchRightKeyRelease(_ key: RightModifierKey) {
        rightStartTasks[key] = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(20))
                guard !Task.isCancelled, let self else { return }
                guard self.rightGesture.isDown(key) else { return }
                if !CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(key.keyCode)) {
                    self.perform(self.rightGesture.keyUp(key, at: ProcessInfo.processInfo.systemUptime))
                    return
                }
            }
        }
    }

    /// Короткое нажатие правой клавиши — та же команда, что у её сочетания.
    private func fire(_ name: KeyboardShortcuts.Name) {
        switch name {
        case .toggleRecording: controller.toggle()
        case .lockOrPause: controller.lockOrPause()   // вне записи — no-op
        case .pasteLast: controller.pasteLastTranscription()
        case .toggleQuietMode: controller.toggleQuietMode()
        case .openMainWindow: WindowManager.shared.showMain(section: .home)
        case .openHistoryWindow: WindowManager.shared.showMain(section: .history)
        default: break
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
