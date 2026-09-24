import SwiftUI

extension View {
    /// Непрерывное «дыхание» SF Symbol внутри вью (`.breathe` доступен с
    /// macOS 15 — минимальной версии приложения).
    func dsBreathe() -> some View {
        symbolEffect(.breathe)
    }
}

extension View {
    /// Главная кнопка: сплошная капсула фирменного коралла на всех версиях.
    /// НЕ `.glassProminent` с `.tint(DS.accent)`: стекло подмешивает к оттенку
    /// фон под кнопкой, и коралл мутнел до горчичного, а на macOS 27 вдобавок
    /// терялась капсула. Цвет обязан совпадать с иконками (`DS.accent`).
    func dsProminentButton() -> some View {
        buttonStyle(DSCapsuleButtonStyle(kind: .prominent))
    }

    /// Вторичная кнопка: та же капсула и те же размеры, что у главной, но с
    /// нейтральной полупрозрачной заливкой. Системный `.glass` был выше
    /// коралловой кнопки, и в одном ряду («Отмена» · «Сохранить») это бросалось в глаза.
    func dsGlassButton() -> some View {
        buttonStyle(DSCapsuleButtonStyle(kind: .secondary))
    }
}

/// Общий стиль капсульных кнопок: одна метрика на главную и вторичную, чтобы
/// в одном ряду они были ровно одной высоты. Учитывает `.controlSize(.small)`;
/// нажатие слегка темнит, наведение слегка высветляет, неактивная — полупрозрачная.
private struct DSCapsuleButtonStyle: ButtonStyle {
    enum Kind { case prominent, secondary }
    let kind: Kind

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize
    @State private var isHovering = false

    private var isCompact: Bool { controlSize == .small || controlSize == .mini }

    func makeBody(configuration: Configuration) -> some View {
        let shape = Capsule(style: .continuous)
        configuration.label
            .font(isCompact ? .subheadline : nil)
            .foregroundStyle(foreground(role: configuration.role))
            .padding(.horizontal, isCompact ? 10 : 14)
            .padding(.vertical, isCompact ? 3 : 6)
            .background(
                shape
                    .fill(fill)
                    .brightness(configuration.isPressed ? -0.08 : (isHovering ? 0.04 : 0))
            )
            .overlay(shape.strokeBorder(stroke, lineWidth: kind == .prominent ? 0.5 : 1))
            .contentShape(shape)
            .opacity(isEnabled ? 1 : 0.45)
            .onHover { isHovering = $0 && isEnabled }
            .animation(DS.Anim.hover, value: isHovering)
    }

    private var fill: Color {
        switch kind {
        case .prominent: DS.accent
        case .secondary: Color.primary.opacity(isHovering ? 0.12 : 0.08)
        }
    }

    private var stroke: Color {
        switch kind {
        case .prominent: .white.opacity(0.18)
        case .secondary: Color.primary.opacity(0.10)
        }
    }

    /// Явный `.foregroundStyle` у лейбла (красная «Стереть всё аудио») всё равно
    /// побеждает: он стоит глубже по иерархии.
    private func foreground(role: ButtonRole?) -> Color {
        switch kind {
        case .prominent: .white
        case .secondary: role == .destructive ? .red : .primary
        }
    }
}
