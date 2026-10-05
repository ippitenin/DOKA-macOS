import CoreGraphics

/// Готовые пути маски в точках окна — строятся вне главного потока, на main
/// только присваиваются (`LipMeshOverlay.apply`). Сетка — в пикселях камеры;
/// плавные кривые считаются там же (`LipMesh.smoothRing`), а в окно их
/// переводит `map`, который знает о зеркале и окне камеры.
///
/// `@unchecked Sendable`: `CGPath` неизменяем, а изменяемые пути наружу не
/// выходят.
struct LipMeshPaths: @unchecked Sendable {
    /// Радиус узла сетки, pt.
    static let nodeRadius: CGFloat = 0.6
    /// Радиус ключевой точки Vision, pt.
    static let keyRadius: CGFloat = 1.5
    /// Отступ скобок от ореола, pt.
    static let bracketPadding: CGFloat = 6
    /// Длина плеча скобки — доля меньшей стороны рамки.
    static let bracketArm: CGFloat = 0.24

    /// Внешний контур + внутренний (even-odd): заливка полосы губ и
    /// светящиеся контуры — один и тот же путь.
    let band: CGPath
    /// Промежуточные кольца и спицы от внешнего узла к внутреннему.
    let grid: CGPath
    /// Ореол и короткие спицы к нему через одну.
    let halo: CGPath
    /// Кружки узлов: промежуточные кольца, внешний и внутренний контуры, ореол.
    let nodes: CGPath
    /// Кружки ключевых точек — настоящих точек Vision.
    let keys: CGPath
    /// Угловые скобки вокруг рамки ореола.
    let brackets: CGPath

    static func make(_ lips: LipMesh, map: (CGPoint) -> CGPoint) -> LipMeshPaths {
        // Узлы — для спиц и точек, плавные кривые — для контуров, колец и ореола.
        let outer = lips.outer.map(map)
        let inner = lips.inner.map(map)
        let bands = lips.bands.map { $0.map(map) }
        let aura = lips.halo.map(map)
        func curve(_ ring: [CGPoint]) -> [CGPoint] { LipMesh.smoothRing(ring).map(map) }

        // Полоса губ: внешний контур минус внутренний (even-odd).
        let band = CGMutablePath()
        band.addLines(between: curve(lips.outer))
        band.closeSubpath()
        band.addLines(between: curve(lips.inner))
        band.closeSubpath()

        // Кольца между контурами и «спицы» от внешнего узла к внутреннему.
        let grid = CGMutablePath()
        for ring in lips.bands {
            grid.addLines(between: curve(ring))
            grid.closeSubpath()
        }
        for (o, i) in zip(outer, inner) {
            grid.move(to: o)
            grid.addLine(to: i)
        }

        // Ореол и короткие спицы к нему через одну.
        let halo = CGMutablePath()
        halo.addLines(between: curve(lips.halo))
        halo.closeSubpath()
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
            band: band, grid: grid, halo: halo,
            nodes: dots(bands.flatMap { $0 } + outer + inner + aura, radius: nodeRadius),
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
