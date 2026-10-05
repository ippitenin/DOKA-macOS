import CoreGraphics

/// Готовые пути маски в точках окна — строятся вне главного потока, на main
/// только присваиваются (`LipMeshOverlay.apply`). Сетка — в пикселях камеры;
/// плавные кривые считаются там же (`LipMesh.smoothRing`), а в окно их
/// переводит `map`, который знает о зеркале и окне камеры.
///
/// `@unchecked Sendable`: `CGPath` неизменяем, а изменяемые пути наружу не
/// выходят.
struct LipMeshPaths: @unchecked Sendable {
    /// Радиус ключевой точки (точки Vision после фильтра One Euro), pt.
    static let keyRadius: CGFloat = 1.5
    /// Отступ скобок от ореола, pt.
    static let bracketPadding: CGFloat = 6
    /// Длина плеча скобки — доля меньшей стороны рамки.
    static let bracketArm: CGFloat = 0.24

    /// Внешний контур + внутренний (even-odd) — заливка полосы губ.
    let band: CGPath
    /// Внешний и внутренний контуры отдельно: у каждого свой цвет.
    let outerRim: CGPath
    let innerRim: CGPath
    /// Промежуточные кольца снаружи внутрь (`LipMesh.bands`), по пути на
    /// кольцо — цвет перетекает от внешнего контура к внутреннему.
    let rings: [CGPath]
    /// Спицы от внешнего узла к внутреннему.
    let spokes: CGPath
    /// Ореол и короткие спицы к нему через одну.
    let halo: CGPath
    /// Кружки ключевых точек — точек Vision после фильтра One Euro (без интерполяции).
    let keys: CGPath
    /// Угловые скобки вокруг рамки ореола.
    let brackets: CGPath

    static func make(_ lips: LipMesh, map: (CGPoint) -> CGPoint) -> LipMeshPaths {
        // Узлы — для спиц, плавные кривые — для контуров, колец и ореола.
        let outer = lips.outer.map(map)
        let inner = lips.inner.map(map)
        let aura = lips.halo.map(map)
        func curve(_ ring: [CGPoint]) -> [CGPoint] { LipMesh.smoothRing(ring).map(map) }
        func closed(_ ring: [CGPoint]) -> CGPath {
            let path = CGMutablePath()
            path.addLines(between: curve(ring))
            path.closeSubpath()
            return path
        }

        // Полоса губ: внешний контур минус внутренний (even-odd).
        let outerRim = closed(lips.outer)
        let innerRim = closed(lips.inner)
        let band = CGMutablePath()
        band.addPath(outerRim)
        band.addPath(innerRim)

        // «Спицы» от внешнего узла к внутреннему.
        let spokes = CGMutablePath()
        for (o, i) in zip(outer, inner) {
            spokes.move(to: o)
            spokes.addLine(to: i)
        }

        // Ореол и короткие спицы к нему через одну. Ореол — отдельный подпуть
        // на каждый отрезок между узлами: пунктир начинается заново на каждом
        // подпути, поэтому штрихи привязаны к узлам. Одним замкнутым путём
        // штрихи нижней губы ползли бы на речи на всю разницу длины контура
        // (≈2 pt на пиксель хода челюсти — больше периода пунктира за кадр).
        let halo = CGMutablePath()
        let ring = curve(lips.halo)
        let steps = LipMesh.contourSteps
        for j in 0..<(ring.count / steps) {
            halo.addLines(between: (0...steps).map { ring[(j * steps + $0) % ring.count] })
        }
        for j in stride(from: 0, to: min(outer.count, aura.count), by: 2) {
            halo.move(to: outer[j])
            halo.addLine(to: aura[j])
        }

        // Рамка — по отображённым углам: `map` может отражать, поэтому min/max.
        let bounds = lips.bounds
        let a = map(CGPoint(x: bounds.minX, y: bounds.minY))
        let b = map(CGPoint(x: bounds.maxX, y: bounds.maxY))
        let frame = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))

        return LipMeshPaths(
            band: band, outerRim: outerRim, innerRim: innerRim, rings: lips.bands.map(closed),
            spokes: spokes, halo: halo,
            keys: dots(lips.keypoints.map(map), radius: keyRadius),
            brackets: brackets(around: frame.insetBy(dx: -bracketPadding, dy: -bracketPadding)))
    }

    private static func dots(_ points: [CGPoint], radius: CGFloat) -> CGPath {
        let path = CGMutablePath()
        for p in points {
            path.addEllipse(in: CGRect(x: p.x - radius, y: p.y - radius, width: 2 * radius, height: 2 * radius))
        }
        return path
    }

    /// L-образные скобки по четырём углам рамки.
    private static func brackets(around rect: CGRect) -> CGPath {
        let arm = max(min(rect.width, rect.height) * bracketArm, 4)
        let path = CGMutablePath()
        let corners: [(CGPoint, CGFloat, CGFloat)] = [
            (CGPoint(x: rect.minX, y: rect.minY), 1, 1),
            (CGPoint(x: rect.maxX, y: rect.minY), -1, 1),
            (CGPoint(x: rect.maxX, y: rect.maxY), -1, -1),
            (CGPoint(x: rect.minX, y: rect.maxY), 1, -1),
        ]
        for (corner, dx, dy) in corners {
            path.move(to: CGPoint(x: corner.x, y: corner.y + dy * arm))
            path.addLine(to: corner)
            path.addLine(to: CGPoint(x: corner.x + dx * arm, y: corner.y))
        }
        return path
    }
}
