import AppKit
import QuartzCore
import SwiftUI

/// Маска-сетка губ поверх кадра зеркала: полупрозрачная полоса губ, сетка
/// между контурами, пунктирный ореол, светящиеся контуры, узлы, ключевые
/// точки Vision и угловые скобки вокруг рта. Слои ставятся прямо в
/// контейнер видео (координаты сверху слева); точки кадра камеры переводит
/// в них `map`, который знает о зеркале и масштабе превью.
///
/// Неявной анимации у `CAShapeLayer.path` нет: пути меняются скачком, на
/// каждом результате трекера.
final class LipMeshOverlay {
    static let meshWidth: CGFloat = 0.5
    static let haloWidth: CGFloat = 0.6
    static let rimWidth: CGFloat = 1.1
    static let nodeRadius: CGFloat = 0.6
    static let keyRadius: CGFloat = 1.5
    static let bracketWidth: CGFloat = 1
    /// Отступ скобок от ореола, pt.
    static let bracketPadding: CGFloat = 6
    /// Длина плеча скобки — доля меньшей стороны рамки.
    static let bracketArm: CGFloat = 0.24

    private let fill = CAShapeLayer()
    private let halo = CAShapeLayer()
    private let mesh = CAShapeLayer()
    private let rims = CAShapeLayer()
    private let nodes = CAShapeLayer()
    private let keys = CAShapeLayer()
    private let brackets = CAShapeLayer()

    init() {
        fill.fillColor = NSColor(DS.Lips.fill).cgColor
        fill.fillRule = .evenOdd
        fill.strokeColor = nil

        halo.fillColor = nil
        halo.strokeColor = NSColor(DS.Lips.halo).cgColor
        halo.lineWidth = Self.haloWidth
        halo.lineDashPattern = [2, 3]

        mesh.fillColor = nil
        mesh.strokeColor = NSColor(DS.Lips.mesh).cgColor
        mesh.lineWidth = Self.meshWidth
        mesh.lineJoin = .round

        rims.fillColor = nil
        rims.strokeColor = NSColor(DS.Lips.contour).cgColor
        rims.lineWidth = Self.rimWidth
        rims.lineJoin = .round
        Self.glow(rims, color: DS.Lips.contour, radius: 4)

        nodes.fillColor = NSColor(DS.Lips.node).cgColor
        nodes.strokeColor = nil

        keys.fillColor = NSColor(DS.Lips.dot).cgColor
        keys.strokeColor = nil
        Self.glow(keys, color: DS.Lips.dot, radius: 3)

        brackets.fillColor = nil
        brackets.strokeColor = NSColor(DS.Lips.bracket).cgColor
        brackets.lineWidth = Self.bracketWidth
        brackets.lineCap = .round
        brackets.lineJoin = .round
    }

    /// Снизу вверх: заливка под сеткой, ключевые точки и скобки — сверху.
    func install(in container: CALayer) {
        for layer in [fill, halo, mesh, rims, nodes, keys, brackets] {
            container.addSublayer(layer)
        }
    }

    func show(_ lips: LipMesh, map: (CGPoint) -> CGPoint) {
        // Узлы — для спиц и точек, плавные кривые — для контуров, колец и ореола.
        let outer = lips.outer.map(map)
        let inner = lips.inner.map(map)
        let bands = lips.bands.map { $0.map(map) }
        let aura = lips.halo.map(map)
        func curve(_ ring: [CGPoint]) -> [CGPoint] { LipMesh.smoothRing(ring).map(map) }

        // Полоса губ: внешний контур минус внутренний (even-odd). Тот же путь — контуры.
        let band = CGMutablePath()
        band.addLines(between: curve(lips.outer))
        band.closeSubpath()
        band.addLines(between: curve(lips.inner))
        band.closeSubpath()
        fill.path = band
        rims.path = band

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
        mesh.path = grid

        // Ореол и короткие спицы к нему через одну.
        let auraPath = CGMutablePath()
        auraPath.addLines(between: curve(lips.halo))
        auraPath.closeSubpath()
        for j in stride(from: 0, to: min(outer.count, aura.count), by: 2) {
            auraPath.move(to: outer[j])
            auraPath.addLine(to: aura[j])
        }
        halo.path = auraPath

        nodes.path = Self.dots(bands.flatMap { $0 } + outer + inner + aura, radius: Self.nodeRadius)
        keys.path = Self.dots(lips.keypoints.map(map), radius: Self.keyRadius)

        let bounds = lips.bounds
        let a = map(CGPoint(x: bounds.minX, y: bounds.minY))
        let b = map(CGPoint(x: bounds.maxX, y: bounds.maxY))
        let frame = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
        brackets.path = Self.brackets(around: frame.insetBy(dx: -Self.bracketPadding, dy: -Self.bracketPadding))
    }

    func hide() {
        for layer in [fill, halo, mesh, rims, nodes, keys, brackets] {
            layer.path = nil
        }
    }

    /// Свечение — только у контуров и ключевых точек: тень на густой сетке
    /// пересчитывалась бы на каждом кадре.
    private static func glow(_ layer: CAShapeLayer, color: Color, radius: CGFloat) {
        layer.shadowColor = NSColor(color).cgColor
        layer.shadowRadius = radius
        layer.shadowOpacity = 0.9
        layer.shadowOffset = .zero
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
