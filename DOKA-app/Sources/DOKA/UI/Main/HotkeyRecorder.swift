import AppKit
import Combine
import KeyboardShortcuts
import SwiftUI

/// Рекордер строки «Клавиш»: обычное сочетание (`KeyboardShortcuts.RecorderCocoa`)
/// или одиночная правая ⌥/⌘. Пока рекордер ждёт сочетание, «чистое» нажатие и
/// отпускание правой клавиши (без других клавиш и модификаторов) назначает её
/// команде и снимает сочетание; записанное сочетание, наоборот, снимает правую
/// клавишу. Назначенная правая клавиша показывается полем-двойником того же
/// вида (нативный `NSSearchField`, как у рекордера мыши): клик — записать
/// заново, крестик — сбросить.
struct HotkeyRecorder: NSViewRepresentable {
    let name: KeyboardShortcuts.Name

    func makeNSView(context: Context) -> Container {
        context.coordinator.container
    }

    func updateNSView(_ nsView: Container, context: Context) {
        context.coordinator.refresh()
    }

    static func dismantleNSView(_ nsView: Container, coordinator: Coordinator) {
        coordinator.stop()
    }

    func makeCoordinator() -> Coordinator { Coordinator(name: name) }

    /// Подпись команды без двоеточия — для сообщения о занятой клавише.
    static func title(for name: KeyboardShortcuts.Name) -> String {
        let key: String
        switch name {
        case .toggleRecording: key = "hotkeys.toggle"
        case .pushToTalk: key = "hotkeys.pushToTalk"
        case .lockOrPause: key = "hotkeys.lockOrPause"
        case .pasteLast: key = "hotkeys.pasteLast"
        case .toggleQuietMode: key = "hotkeys.quietMode"
        case .openMainWindow: key = "hotkeys.openMain"
        case .openHistoryWindow: key = "hotkeys.openHistory"
        default: return name.rawValue
        }
        return L(key).trimmingCharacters(in: CharacterSet(charactersIn: ": "))
    }

    /// Контейнер ровно по размеру рекордера: оба поля лежат друг на друге.
    final class Container: NSView {
        weak var sizing: NSView?
        override var intrinsicContentSize: CGSize {
            sizing?.intrinsicContentSize ?? super.intrinsicContentSize
        }
    }

    @MainActor
    final class Coordinator {
        let name: KeyboardShortcuts.Name
        let container = Container()
        private let recorder: KeyboardShortcuts.RecorderCocoa
        private let assignedField = RightKeyField()
        private var cancelCell: NSButtonCell?
        private var editing = false
        /// Правая клавиша нажата «чисто» и ждёт отпускания.
        private var candidate: RightModifierKey?
        private var monitor: Any?
        private var observers: [NSObjectProtocol] = []
        private var subscription: AnyCancellable?

        init(name: KeyboardShortcuts.Name) {
            self.name = name
            // Сочетание записано — правая клавиша этой команде больше не нужна.
            // `onChange` задаётся только в init рекордера, а self ещё нет.
            let owner = WeakCoordinator()
            recorder = KeyboardShortcuts.RecorderCocoa(for: name) { shortcut in
                MainActor.assumeIsolated {
                    guard let self = owner.value, shortcut != nil else { return }
                    RightModifierKeys.shared.clear(self.name)
                    self.refresh()
                }
            }
            recorder.validateShortcut = { RecordingControlShortcut.validate($0, for: name) }
            configureAssignedField()
            for view in [recorder, assignedField] as [NSView] {
                view.translatesAutoresizingMaskIntoConstraints = false
                container.addSubview(view)
                NSLayoutConstraint.activate([
                    view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                    view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                    view.topAnchor.constraint(equalTo: container.topAnchor),
                    view.bottomAnchor.constraint(equalTo: container.bottomAnchor)
                ])
            }
            container.sizing = recorder
            container.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            container.setContentHuggingPriority(.defaultHigh, for: .vertical)
            owner.value = self
            start()
            refresh()
        }

        private func configureAssignedField() {
            assignedField.alignment = .center
            assignedField.refusesFirstResponder = true
            let cell = assignedField.cell as? NSSearchFieldCell
            cancelCell = cell?.cancelButtonCell
            cell?.searchButtonCell = nil
            assignedField.onClick = { [weak self] in self?.beginEditing() }
            assignedField.onClear = { [weak self] in
                guard let self else { return }
                RightModifierKeys.shared.clear(self.name)
                self.refresh()
            }
        }

        private func start() {
            subscription = RightModifierKeys.shared.$assignments
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.refresh() }
            // Конец записи сочетания. Имя уведомления — внутреннее у
            // KeyboardShortcuts (`recorderActiveStatusDidChange`), публичного
            // API нет; без него поле-двойник после клика не вернулось бы.
            observers.append(NotificationCenter.default.addObserver(
                forName: Notification.Name("KeyboardShortcuts_recorderActiveStatusDidChange"),
                object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.editing, self.recorder.currentEditor() == nil else { return }
                    self.editing = false
                    self.refresh()
                }
            })
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
                MainActor.assumeIsolated { self?.handle(event) }
                return event
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            subscription = nil
        }

        func refresh() {
            let key = RightModifierKeys.shared.key(for: name)
            let showAssigned = key != nil && !editing
            assignedField.isHidden = !showAssigned
            recorder.isHidden = showAssigned
            assignedField.stringValue = key?.title ?? ""
            (assignedField.cell as? NSSearchFieldCell)?.cancelButtonCell = showAssigned ? cancelCell : nil
            assignedField.needsDisplay = true
        }

        private func beginEditing() {
            editing = true
            refresh()
            recorder.window?.makeFirstResponder(recorder)
        }

        /// Ловит одиночную правую клавишу, пока рекордер ждёт сочетание.
        private func handle(_ event: NSEvent) {
            guard recorder.currentEditor() != nil else {
                candidate = nil
                return
            }
            guard event.type == .flagsChanged, let key = RightModifierKey(keyCode: event.keyCode) else {
                candidate = nil   // обычная клавиша или другой модификатор — это сочетание
                return
            }
            let pressed = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                .intersection([.shift, .control, .option, .command])
            if key.isDown(in: event.modifierFlags) {
                candidate = pressed == key.flag ? key : nil
            } else if candidate == key {
                candidate = nil
                assign(key)
            }
        }

        private func assign(_ key: RightModifierKey) {
            if let owner = RightModifierKeys.shared.assign(key, to: name) {
                let alert = NSAlert()
                alert.messageText = L("hotkeys.rightModifier.conflict", key.title, HotkeyRecorder.title(for: owner))
                if let window = recorder.window {
                    alert.beginSheetModal(for: window)
                } else {
                    alert.runModal()
                }
                return
            }
            KeyboardShortcuts.setShortcut(nil, for: name)
            editing = false
            recorder.window?.makeFirstResponder(nil)
            refresh()
        }
    }

    private final class WeakCoordinator {
        weak var value: Coordinator?
    }

    /// Поле назначенной правой клавиши: без клавиатурного ввода, клик —
    /// записать заново, крестик — сбросить. Ширина — как у RecorderCocoa.
    final class RightKeyField: NSSearchField {
        var onClick: (() -> Void)?
        var onClear: (() -> Void)?

        override var intrinsicContentSize: CGSize {
            var size = super.intrinsicContentSize
            size.width = 130
            return size
        }

        override var acceptsFirstResponder: Bool { false }

        override func mouseDown(with event: NSEvent) {
            if let cell = cell as? NSSearchFieldCell, cell.cancelButtonCell != nil {
                let point = convert(event.locationInWindow, from: nil)
                if cell.cancelButtonRect(forBounds: bounds).contains(point) {
                    onClear?()
                    return
                }
            }
            onClick?()
        }
    }
}
