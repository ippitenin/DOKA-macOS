import SwiftUI

/// Форма стеклянной поверхности: скруглённый прямоугольник или капсула.
/// InsettableShape — чтобы strokeBorder рисовался по той же форме.
struct GlassSurfaceShape: InsettableShape {
    enum Kind: Equatable {
        case rounded(CGFloat)
        case capsule
    }

    var kind: Kind
    var insetAmount: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let inset = rect.insetBy(dx: insetAmount, dy: insetAmount)
        switch kind {
        case .rounded(let radius):
            return RoundedRectangle(cornerRadius: max(0, radius - insetAmount), style: .continuous)
                .path(in: inset)
        case .capsule:
            return Capsule(style: .continuous).path(in: inset)
        }
    }

    func inset(by amount: CGFloat) -> GlassSurfaceShape {
        var copy = self
        copy.insetAmount += amount
        return copy
    }
}

extension View {
    /// Адаптивная стеклянная подложка — всё стекло приложения идёт через неё.
    /// macOS 26 — Liquid Glass; 15 — материал со светящейся кромкой;
    /// Reduce Transparency — непрозрачный фон. forceMaterial — страховка
    /// для контекстов, где glassEffect ведёт себя плохо (borderless NSPanel).
    func glassSurface(
        radius: CGFloat = DS.Radius.card,
        tint: Color? = nil,
        interactive: Bool = false,
        shadow: Bool = false,
        forceMaterial: Bool = false
    ) -> some View {
        modifier(GlassSurfaceModifier(
            shape: GlassSurfaceShape(kind: .rounded(radius)),
            tint: tint, interactive: interactive, shadow: shadow,
            forceMaterial: forceMaterial
        ))
    }

    /// То же стекло в форме капсулы (mini-рекордер, кнопки-пилюли).
    func glassCapsule(
        tint: Color? = nil,
        interactive: Bool = false,
        shadow: Bool = false,
        forceMaterial: Bool = false
    ) -> some View {
        modifier(GlassSurfaceModifier(
            shape: GlassSurfaceShape(kind: .capsule),
            tint: tint, interactive: interactive, shadow: shadow,
            forceMaterial: forceMaterial
        ))
    }
}

private struct GlassSurfaceModifier: ViewModifier {
    let shape: GlassSurfaceShape
    let tint: Color?
    let interactive: Bool
    let shadow: Bool
    let forceMaterial: Bool

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        surfaced(content)
            // Тень — отдельной размытой формой позади, а не .shadow():
            // модификатор тени на контенте зацепил бы текст и иконки.
            .background(
                shape
                    .fill(Color.black.opacity(shadow && !reduceTransparency ? 0.22 : 0))
                    .blur(radius: 16)
                    .offset(y: 8)
            )
    }

    @ViewBuilder
    private func surfaced(_ content: Content) -> some View {
        if reduceTransparency {
            // Непрозрачный фон; статусный тон остаётся виден полупрозрачным слоем.
            content
                .background((tint ?? .clear).opacity(tint == nil ? 0 : 0.22), in: shape)
                .background(Color(nsColor: .windowBackgroundColor), in: shape)
                .overlay(shape.strokeBorder(Color.primary.opacity(0.12)))
        } else if #available(macOS 26.0, *), !forceMaterial {
            content.glassEffect(resolvedGlass, in: shape)
        } else {
            content
                .background((tint ?? .clear).opacity(tint == nil ? 0 : 0.10), in: shape)
                .background(.regularMaterial, in: shape)
                .overlay(
                    shape.strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(0.25), .white.opacity(0.05)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
                )
        }
    }

    @available(macOS 26.0, *)
    private var resolvedGlass: Glass {
        var glass: Glass = .regular
        if let tint { glass = glass.tint(tint) }
        if interactive { glass = glass.interactive() }
        return glass
    }
}
