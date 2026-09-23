import SwiftUI

/// Фон всего окна: behind-window-блюр + медленный mesh-дрейф поверх.
/// При Reduce Transparency — сплошной системный цвет.
struct AppBackground: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if reduceTransparency {
            Color(nsColor: .windowBackgroundColor)
        } else {
            ZStack {
                VisualEffectView(material: .underWindowBackground)
                // Насыщенный глубокий синий тинт.
                MeshBackground()
                    .opacity(scheme == .dark ? 0.50 : 0.38)
                EdgeGlow()
                EdgeRim()
            }
            .clipped()
        }
    }
}

/// Асимметричное тёплое свечение (Huly-стиль): большое персиковое пятно
/// с горячим ядром справа-снизу и слабый отклик слева-сверху.
private struct EdgeGlow: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack {
                // Большое мягкое пятно.
                Circle()
                    .fill(DS.glow)
                    .frame(width: w * 0.95, height: w * 0.95)
                    .position(x: w * 1.02, y: h * 1.08)
                    .blur(radius: 130)
                    .opacity(scheme == .dark ? 0.34 : 0.20)
                // Горячее ядро — даёт яркость у самого угла.
                Circle()
                    .fill(DS.glow)
                    .frame(width: w * 0.42, height: w * 0.42)
                    .position(x: w * 1.04, y: h * 1.10)
                    .blur(radius: 85)
                    .opacity(scheme == .dark ? 0.30 : 0.16)
                // Слабый отклик в противоположном углу.
                Circle()
                    .fill(DS.glow)
                    .frame(width: w * 0.4, height: w * 0.4)
                    .position(x: -w * 0.04, y: -h * 0.03)
                    .blur(radius: 100)
                    .opacity(scheme == .dark ? 0.12 : 0.08)
            }
        }
        .allowsHitTesting(false)
    }
}

/// Тонкий асимметричный rim-свет по периметру окна: ярче и толще
/// у правого нижнего угла, едва заметный у левого верхнего.
private struct EdgeRim: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        // Радиус угла окна НЕ зашивать числом: он меняется от версии к версии
        // macOS (26 → 27 уже менялся), и кромка начинала рисовать второе
        // скругление внутри угла окна. С macOS 26 форму отдаёт система —
        // `ConcentricRectangle` концентричен окну и учитывает отступ.
        if #available(macOS 26, *) {
            rim(ConcentricRectangle())
        } else {
            // Радиус титулованного окна macOS 15.
            rim(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    /// `ConcentricRectangle` — не `InsettableShape`, поэтому вместо
    /// `strokeBorder` — `stroke` с отступом в половину толщины линии
    /// (плюс прежний отступ 1 pt от края окна).
    private func rim(_ shape: some Shape) -> some View {
        let boost: Double = scheme == .dark ? 1.0 : 0.55
        return ZStack {
            // Тонкая линия по всему периметру с угловым затуханием
            // (0° — восток, 90° — юг: максимум на юго-востоке).
            shape
                .stroke(rimGradient(peak: 0.9 * boost), lineWidth: 1)
                .padding(1 + 0.5)
                .blur(radius: 0.5)
            // Утолщённое размытое свечение — только у юго-востока,
            // даёт неравную толщину кромки.
            shape
                .stroke(rimGradient(peak: 0.55 * boost, tightFalloff: true), lineWidth: 4)
                .padding(1 + 2)
                .blur(radius: 6)
        }
        .allowsHitTesting(false)
    }

    private func rimGradient(peak: Double, tightFalloff: Bool = false) -> AngularGradient {
        let dim = tightFalloff ? 0.0 : 0.04
        return AngularGradient(
            gradient: Gradient(stops: [
                .init(color: DS.glow.opacity(peak * 0.45), location: 0.0),     // восток
                .init(color: DS.glow.opacity(peak), location: 0.125),          // юго-восток
                .init(color: DS.glow.opacity(peak * 0.35), location: 0.25),    // юг
                .init(color: DS.glow.opacity(dim), location: 0.45),
                .init(color: DS.glow.opacity(dim * 0.5), location: 0.625),     // северо-запад
                .init(color: DS.glow.opacity(dim), location: 0.8),
                .init(color: DS.glow.opacity(peak * 0.45), location: 1.0)
            ]),
            center: .center
        )
    }
}

/// Анимированный sci-fi mesh на `MeshGradient` (доступен с macOS 15 —
/// минимальной версии приложения, поэтому фолбэка больше нет).
struct MeshBackground: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: reduceMotion)) { context in
            let t = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
            MeshGradient(
                width: 3, height: 3,
                points: Self.drift(t),
                colors: DS.meshColors(for: scheme)
            )
        }
    }

    /// Дрейф точек сетки 3×3: углы закреплены, кромочные точки скользят
    /// вдоль своей кромки, центр гуляет сильнее всех. Период ~1.5 минуты.
    static func drift(_ t: TimeInterval) -> [SIMD2<Float>] {
        let s = Float(sin(t * 0.07))
        let c = Float(cos(t * 0.05))
        return [
            [0, 0], [0.5 + 0.08 * s, 0], [1, 0],
            [0, 0.5 + 0.06 * c], [0.5 + 0.12 * s, 0.5 + 0.12 * c], [1, 0.5 - 0.06 * s],
            [0, 1], [0.5 - 0.08 * c, 1], [1, 1]
        ]
    }
}

