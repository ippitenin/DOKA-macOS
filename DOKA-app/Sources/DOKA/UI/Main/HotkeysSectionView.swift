import AppKit
import SwiftUI
import KeyboardShortcuts

/// Секция «Клавиши»: глобальные горячие клавиши диктовки, кнопка мыши
/// и шорткаты окна (отражаются в меню-баре).
struct HotkeysSectionView: View {
    @ObservedObject private var settings = SettingsStore.shared
    /// Системное действие на 🌐 — читается при появлении и при возврате в
    /// DOKA (человек мог поменять его в Системных настройках).
    @State private var systemFnFree = SystemFnKeyUsage.doesNothing

    var body: some View {
        SettingsForm(title: L("section.hotkeys")) {
            SettingsCard(header: L("hotkeys.card.dictation"),
                         footer: L("hotkeys.escHint")) {
                SettingsRow(title: L("hotkeys.toggle")) {
                    KeyboardShortcuts.Recorder(for: .toggleRecording)
                }
                CardDivider()
                SettingsRow(title: L("hotkeys.pushToTalk"),
                            help: L("hotkeys.pushToTalk.hint")) {
                    KeyboardShortcuts.Recorder(for: .pushToTalk)
                }
                CardDivider()
                SettingsRow(title: L("hotkeys.mouseButton"),
                            help: L("hotkeys.mouseButton.hint")) {
                    MouseShortcutRecorder()
                }
                CardDivider()
                SettingsRow(title: L("hotkeys.fnKey"),
                            help: L("hotkeys.fnKey.hint")) {
                    SettingsPopup(selection: $settings.fnKeyMode, title: \.title)
                }
                if settings.fnKeyMode != .off && !systemFnFree {
                    HStack(spacing: 10) {
                        Text(L("hotkeys.fnKey.systemConflict"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Button(L("hotkeys.fnKey.openKeyboardSettings")) {
                            SystemFnKeyUsage.openKeyboardSettings()
                        }
                        .dsGlassButton()
                    }
                    .padding(.horizontal, DS.Spacing.cardPadding)
                    .padding(.bottom, 9)
                }
                CardDivider()
                SettingsRow(title: L("hotkeys.pasteLast")) {
                    KeyboardShortcuts.Recorder(for: .pasteLast)
                }
                CardDivider()
                SettingsRow(title: L("hotkeys.quietMode"),
                            help: L("hotkeys.quietMode.hint")) {
                    KeyboardShortcuts.Recorder(for: .toggleQuietMode)
                }
            }

            SettingsCard(header: L("hotkeys.card.window"),
                         footer: L("hotkeys.window.footer")) {
                SettingsRow(title: L("hotkeys.openMain")) {
                    KeyboardShortcuts.Recorder(for: .openMainWindow)
                }
                CardDivider()
                SettingsRow(title: L("hotkeys.openHistory")) {
                    KeyboardShortcuts.Recorder(for: .openHistoryWindow)
                }
            }
        }
        .onAppear { systemFnFree = SystemFnKeyUsage.doesNothing }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            systemFnFree = SystemFnKeyUsage.doesNothing
        }
    }
}

/// «Рекордер» кнопки мыши. Визуально идентичен KeyboardShortcuts.Recorder,
/// потому что построен так же — на нативном NSSearchField (та же ширина 130,
/// та же заливка и крестик в обеих темах). Клик по полю ждёт нажатия боковой
/// кнопки (.otherMouseDown, номера от 2 — левая/правая не перехватываются).
private struct MouseShortcutRecorder: View {
    @ObservedObject private var settings = SettingsStore.shared
    @State private var isListening = false

    var body: some View {
        MouseShortcutField(
            assignedButton: settings.mouseShortcutButton,
            isListening: $isListening,
            onAssign: { settings.mouseShortcutButton = $0 },
            onClear: { settings.mouseShortcutButton = -1 }
        )
        .fixedSize()
        .onDisappear { isListening = false }
    }
}

private struct MouseShortcutField: NSViewRepresentable {
    let assignedButton: Int
    @Binding var isListening: Bool
    let onAssign: (Int) -> Void
    let onClear: () -> Void

    func makeNSView(context: Context) -> CaptureField {
        let field = CaptureField()
        field.alignment = .center
        // Поле остаётся editable, как в RecorderCocoa: у нередактируемого
        // NSSearchField системная подложка заметно бледнее. Ввод с клавиатуры
        // всё равно невозможен — поле не принимает фокус (acceptsFirstResponder
        // == false) и mouseDown не запускает редактирование.
        field.refusesFirstResponder = true
        // Как в RecorderCocoa: иконку поиска убираем, крестик держим отдельно
        // и подставляем только при назначенной кнопке.
        let cell = field.cell as? NSSearchFieldCell
        context.coordinator.cancelCell = cell?.cancelButtonCell
        cell?.searchButtonCell = nil
        cell?.cancelButtonCell = nil
        field.setContentHuggingPriority(.defaultHigh, for: .vertical)
        field.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        field.onClick = { [weak coordinator = context.coordinator] in
            coordinator?.toggleListening()
        }
        field.onClear = { [weak coordinator = context.coordinator] in
            coordinator?.clear()
        }
        context.coordinator.field = field
        context.coordinator.refresh()
        return field
    }

    func updateNSView(_ field: CaptureField, context: Context) {
        context.coordinator.parent = self
        context.coordinator.refresh()
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor
    final class Coordinator {
        var parent: MouseShortcutField
        weak var field: CaptureField?
        var cancelCell: NSButtonCell?
        private var monitor: Any?

        init(parent: MouseShortcutField) {
            self.parent = parent
        }

        func toggleListening() {
            parent.isListening.toggle()
            refresh()
        }

        func clear() {
            parent.onClear()
            parent.isListening = false
            refresh()
        }

        /// Приводит поле и монитор захвата к текущему состоянию.
        func refresh() {
            reconcileMonitor()
            guard let field else { return }
            let cell = field.cell as? NSSearchFieldCell
            if parent.isListening {
                field.stringValue = ""
                field.placeholderString = L("hotkeys.mouseButton.listening")
                cell?.cancelButtonCell = nil
            } else if parent.assignedButton >= 2 {
                // Для людей кнопки нумеруются с единицы (боковые — 4, 5…).
                field.stringValue = L("hotkeys.mouseButton.assigned", parent.assignedButton + 1)
                cell?.cancelButtonCell = cancelCell
            } else {
                field.stringValue = ""
                field.placeholderString = L("hotkeys.mouseButton.assign")
                cell?.cancelButtonCell = nil
            }
            field.needsDisplay = true
        }

        private func reconcileMonitor() {
            if parent.isListening, monitor == nil {
                MouseShortcutCapture.isCapturing = true
                monitor = NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown) { [weak self] event in
                    let button = event.buttonNumber
                    Task { @MainActor in
                        guard let self else { return }
                        if button >= 2 {
                            self.parent.onAssign(button)
                        }
                        self.parent.isListening = false
                        self.refresh()
                    }
                    return nil   // событие захвачено рекордером, дальше не идёт
                }
            } else if !parent.isListening, let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
                MouseShortcutCapture.isCapturing = false
            }
        }
    }

    /// NSSearchField без клавиатурного ввода: клик по полю — захват кнопки,
    /// клик по крестику — сброс. Ширина — как у RecorderCocoa (130).
    final class CaptureField: NSSearchField {
        var onClick: (() -> Void)?
        var onClear: (() -> Void)?

        override var intrinsicContentSize: CGSize {
            var size = super.intrinsicContentSize
            size.width = 130
            return size
        }

        override var acceptsFirstResponder: Bool { false }

        override func mouseDown(with event: NSEvent) {
            if !stringValue.isEmpty,
               let cell = cell as? NSSearchFieldCell,
               cell.cancelButtonCell != nil {
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
