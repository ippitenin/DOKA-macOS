import AppKit
import SwiftUI

/// Силуэт фирменного логотипа DOKA: симметричный четырёхлепестковый крест —
/// четыре линзы-лепестка, направленные в углы, с пустым ромбом в центре.
/// Контур перенесён 1:1 из векторного исходника `Vector_DOKA.svg`
/// (Figma-экспорт, viewBox 1013). Лепестки слегка выходят за viewBox к углам,
/// поэтому нормируем по полному охвату [−35.09 … 1048.09], чтобы крест ровно
/// вписался в `rect`. Заливка non-zero оставляет центральный ромб пустым:
/// четыре лепестка — отдельные замкнутые контуры и центр не охватывают.
struct DokaPetalsShape: Shape {
    func path(in rect: CGRect) -> Path {
        let lo: CGFloat = -35.0882
        let span: CGFloat = 1083.1764
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + (x - lo) / span * rect.width,
                    y: rect.minY + (y - lo) / span * rect.height)
        }
        func c(_ p: inout Path,
               _ x1: CGFloat, _ y1: CGFloat,
               _ x2: CGFloat, _ y2: CGFloat,
               _ x: CGFloat, _ y: CGFloat) {
            p.addCurve(to: pt(x, y), control1: pt(x1, y1), control2: pt(x2, y2))
        }
        var p = Path()
        // Лепесток влево-вниз.
        p.move(to: pt(101.301, 506.5))
        c(&p, 146.993, 582.732, 207.21, 660.138, 280.036, 732.964)
        c(&p, 352.862, 805.79, 430.268, 866.006, 506.5, 911.698)
        c(&p, 320.887, 1022.95, 142.231, 1048.09, 53.5714, 959.429)
        c(&p, -35.0882, 870.769, -9.95084, 692.112, 101.301, 506.5)
        p.closeSubpath()
        // Лепесток вправо-вниз.
        p.move(to: pt(911.698, 506.5))
        c(&p, 1022.95, 692.113, 1048.09, 870.769, 959.429, 959.429)
        c(&p, 870.769, 1048.09, 692.113, 1022.95, 506.5, 911.698)
        c(&p, 582.732, 866.006, 660.138, 805.79, 732.964, 732.964)
        c(&p, 805.79, 660.138, 866.006, 582.732, 911.698, 506.5)
        p.closeSubpath()
        // Лепесток влево-вверх.
        p.move(to: pt(53.5714, 53.5714))
        c(&p, 142.231, -35.0882, 320.887, -9.95049, 506.5, 101.301)
        c(&p, 430.268, 146.993, 352.862, 207.21, 280.036, 280.036)
        c(&p, 207.21, 352.862, 146.993, 430.268, 101.301, 506.5)
        c(&p, -9.95049, 320.887, -35.0882, 142.231, 53.5714, 53.5714)
        p.closeSubpath()
        // Лепесток вправо-вверх.
        p.move(to: pt(506.5, 101.301))
        c(&p, 692.112, -9.95086, 870.769, -35.0882, 959.429, 53.5714)
        c(&p, 1048.09, 142.231, 1022.95, 320.887, 911.698, 506.5)
        c(&p, 866.006, 430.268, 805.79, 352.862, 732.964, 280.036)
        c(&p, 660.138, 207.21, 582.732, 146.993, 506.5, 101.301)
        p.closeSubpath()
        return p
    }
}

/// Плоская мини-марка лого для малых размеров (сайдбар, меню-бар, панель
/// записи): силуэт `DokaPetalsShape` сплошной заливкой — на 14–24pt любая
/// фактура и блюр превратились бы в кашу.
struct DokaLogoMark: View {
    var size: CGFloat = 18
    /// Единый цвет марки: `.white` — для цветных плиток, `.black` — для
    /// template-образа меню-бара (важна только альфа). `nil` — фирменный
    /// тёплый персиковый градиент.
    var tint: Color? = nil

    var body: some View {
        DokaPetalsShape()
            .fill(fillStyle)
            .frame(width: size, height: size)
    }

    private var fillStyle: AnyShapeStyle {
        if let tint {
            return AnyShapeStyle(tint)
        }
        return AnyShapeStyle(
            LinearGradient(
                colors: [DS.Logo.markLight, DS.Logo.markDeep],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }
}

/// Готовый цветной логотип DOKA из ресурса (вектор `Logo_DOKA.pdf`):
/// сквиркл-тайл с фоном и персиковыми лепестками. Крупно — на экране
/// готовности. Статичный, без анимации.
struct DokaBrandLogo: View {
    var size: CGFloat = 132

    var body: some View {
        Group {
            if let image = Self.image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                // Фолбэк, если ресурс не нашёлся: силуэт креста акцентом.
                DokaPetalsShape().fill(DS.accent)
            }
        }
        .frame(width: size, height: size)
        // Тень пропорциональна размеру: на 132 pt главной — прежние ≈ 18/8,
        // на маленьком логотипе «О DOKA» фиксированная тень грязнила бы.
        .shadow(color: .black.opacity(0.22), radius: size * 0.14, y: size * 0.06)
        .accessibilityHidden(true)
    }

    /// Грузим один раз. NSImage из PDF хранит вектор и растеризуется чётко
    /// под фактический размер отрисовки (в т. ч. на Retina).
    private static let image: NSImage? = {
        guard let url = Bundle.module.url(forResource: "Logo_DOKA", withExtension: "pdf")
        else { return nil }
        return NSImage(contentsOf: url)
    }()
}

/// Плитка сайдбара с лого-маркой вместо SF-символа: повторяет оформление
/// IconTile (градиент, светлая кромка, тень), чтобы не выбиваться из ряда.
struct LogoIconTile: View {
    var size: CGFloat = 24

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [DS.accent.opacity(0.85), DS.accent],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .frame(width: size, height: size)
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(0.35), .white.opacity(0.05)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 0.5
                    )
            )
            .overlay(DokaLogoMark(size: size * 0.62, tint: .white))
            .shadow(color: .black.opacity(0.10), radius: 1, y: 0.5)
    }
}
