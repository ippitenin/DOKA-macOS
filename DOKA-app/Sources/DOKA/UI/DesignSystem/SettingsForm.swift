import SwiftUI

/// Скролл-контейнер секции настроек: заголовок + стеклянные карточки.
/// Замена Form(.grouped): grouped-формы рисуют непрозрачные подложки,
/// инородные на стекле.
struct SettingsForm<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.cardPadding) {
                SectionHeader(title: title, subtitle: subtitle)
                    .padding(.bottom, 2)
                content
            }
            .padding(.horizontal, DS.Spacing.section)
            .padding(.top, 46)
            .padding(.bottom, 20)
        }
    }
}

/// Группа строк на стеклянной карточке (роль Section в Form).
struct SettingsCard<Content: View>: View {
    var header: String? = nil
    var footer: String? = nil
    /// Материал вместо Liquid Glass — для высоких карточек: их линза у кромок
    /// дотягивается до соседей и отражает сайдбар и контролы выше.
    var forceMaterial: Bool = false
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let header {
                Text(header)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
            }
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassSurface(forceMaterial: forceMaterial)
            if let footer {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
            }
        }
    }
}

/// Разделитель строк внутри стеклянной карточки.
struct CardDivider: View {
    var body: some View {
        Divider()
            .opacity(0.5)
            .padding(.horizontal, DS.Spacing.cardPadding)
    }
}

/// Выпадающий список фиксированной ширины для SettingsRow.
/// Честный NSPopUpButton: SwiftUI-Picker игнорирует предложенную ширину
/// (сайзится по контенту и центрируется), а кастомные Menu-лейблы ломают
/// рендер меню. NSViewRepresentable заполняет предложенный frame, клик
/// мгновенно раскрывает системное меню с галочкой на выбранном пункте.
struct SettingsPopup: View {
    let titles: [String]
    @Binding var selectionIndex: Int
    /// nil — ширина по содержимому (для списков с длинными пунктами).
    var width: CGFloat? = 180

    /// SwiftUI НЕ пробрасывает `.disabled` внутрь NSViewRepresentable сам:
    /// без явной передачи в `NSPopUpButton.isEnabled` заблокированный снаружи
    /// список продолжает раскрываться по клику.
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        if let width {
            PopUpButton(titles: titles, selectionIndex: $selectionIndex,
                        fixedWidth: width, isEnabled: isEnabled)
                .frame(width: width, height: 26)
        } else {
            PopUpButton(titles: titles, selectionIndex: $selectionIndex,
                        fixedWidth: nil, isEnabled: isEnabled)
                .fixedSize()
        }
    }
}

private struct PopUpButton: NSViewRepresentable {
    let titles: [String]
    @Binding var selectionIndex: Int
    let fixedWidth: CGFloat?
    let isEnabled: Bool

    func makeNSView(context: Context) -> NSView {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.target = context.coordinator
        button.action = #selector(Coordinator.didChange(_:))
        context.coordinator.button = button
        guard fixedWidth != nil else { return button }
        // Минимальная ширина NSPopUpButton растёт по САМОМУ ДЛИННОМУ пункту
        // меню: с длинными пунктами («Задачи и договорённости») кнопка
        // раздвигала фрейм и вылезала за карточку в обе стороны. Сжимаемая
        // кнопка плюс многоточие держат ровно заданную ширину.
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        (button.cell as? NSPopUpButtonCell)?.lineBreakMode = .byTruncatingTail
        // Контейнер с констрейнтами: интринсик-ширина NSPopUpButton сильнее
        // предложенного SwiftUI фрейма, без них кнопка вылезает за карточку.
        let container = NSView()
        container.addSubview(button)
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            button.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])
        return container
    }

    /// Заданная ширина — ровно она: иначе SwiftUI берёт минимальный размер
    /// AppKit-вью (по длинному пункту) и центрирует его поверх фрейма.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        guard let fixedWidth else { return nil }
        return CGSize(width: fixedWidth, height: 26)
    }

    func updateNSView(_ view: NSView, context: Context) {
        guard let button = context.coordinator.button else { return }
        context.coordinator.parent = self
        button.isEnabled = isEnabled
        if button.itemTitles != titles {
            button.removeAllItems()
            // Не addItems(withTitles:) — он молча выкидывает дубликаты.
            for title in titles {
                button.menu?.addItem(NSMenuItem(title: title, action: nil, keyEquivalent: ""))
            }
        }
        if button.indexOfSelectedItem != selectionIndex,
           titles.indices.contains(selectionIndex) {
            button.selectItem(at: selectionIndex)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor
    final class Coordinator: NSObject {
        var parent: PopUpButton
        weak var button: NSPopUpButton?

        init(_ parent: PopUpButton) {
            self.parent = parent
        }

        @objc func didChange(_ sender: NSPopUpButton) {
            parent.selectionIndex = sender.indexOfSelectedItem
        }
    }
}

/// Переключатель для SettingsRow: вне Form тогглы рисуются чекбоксами,
/// а в настройках ожидается switch, как в Системных настройках.
struct SettingsSwitch: View {
    @Binding var isOn: Bool

    var body: some View {
        Toggle("", isOn: $isOn)
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
    }
}

/// Строка «подпись слева — контрол справа» (роль строки Form).
/// `help` — подсказка за «вопросиком» рядом с заголовком (клик → поповер);
/// предпочтительнее subtitle: строки не разбухают от пояснений.
struct SettingsRow<Control: View>: View {
    let title: String
    var subtitle: String? = nil
    var help: String? = nil
    @ViewBuilder var control: Control

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(title)
                    if let help {
                        HelpBubble(text: help)
                    }
                }
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 16)
            control
        }
        .padding(.horizontal, DS.Spacing.cardPadding)
        .padding(.vertical, 9)
    }
}

/// «Вопросик» с поповером-подсказкой — тот самый, что у `SettingsRow(help:)`,
/// но пригодный для любых заголовков (например, у списков вне форм настроек).
struct HelpBubble: View {
    let text: String

    @State private var showHelp = false

    var body: some View {
        Button {
            showHelp.toggle()
        } label: {
            Image(systemName: "questionmark.circle")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showHelp, arrowEdge: .bottom) {
            Text(text)
                .font(.callout)
                .multilineTextAlignment(.leading)
                .padding(12)
                .frame(width: 280, alignment: .leading)
        }
    }
}

extension View {
    /// Плоское поле ввода: мягкая подложка и тонкая кромка вместо системной
    /// серой рамки `.roundedBorder` — «Шаблоны анализа», «Словарь».
    func dsFieldBox() -> some View {
        textFieldStyle(.plain)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.badge, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.badge, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
            )
    }
}
