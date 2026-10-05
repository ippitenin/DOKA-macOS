import AppKit
import QuartzCore
import SwiftUI

/// Маска-сетка губ поверх кадра зеркала: полупрозрачная полоса губ, сетка
/// между контурами, пунктирный ореол, светящиеся контуры, узлы, ключевые
/// точки Vision и угловые скобки вокруг рта. Слои ставятся прямо в
/// контейнер видео (координаты сверху слева). Геометрия — в `LipMeshPaths`
/// (строится вне главного потока); здесь только стиль и порядок слоёв.
///
/// Неявной анимации у `CAShapeLayer.path` нет: пути меняются скачком, на
/// каждом результате трекера.
final class LipMeshOverlay {
    static let meshWidth: CGFloat = 0.5
    static let haloWidth: CGFloat = 0.6
    static let rimWidth: CGFloat = 1.1
    static let bracketWidth: CGFloat = 1

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
    private var layers: [CAShapeLayer] { [fill, halo, mesh, rims, nodes, keys, brackets] }

    func install(in container: CALayer) {
        for layer in layers { container.addSublayer(layer) }
    }

    /// Пути одного кадра; nil — маску спрятать. Вызывающий сам решает про
    /// транзакцию: зеркало меняет маску и картинку вместе, без анимаций.
    func apply(_ paths: LipMeshPaths?) {
        fill.path = paths?.band
        rims.path = paths?.band
        mesh.path = paths?.grid
        halo.path = paths?.halo
        nodes.path = paths?.nodes
        keys.path = paths?.keys
        brackets.path = paths?.brackets
    }

    /// Масштаб экрана — иначе на Retina пути растрируются в 1×.
    func setScale(_ scale: CGFloat) {
        for layer in layers { layer.contentsScale = scale }
    }

    /// Свечение — только у контуров и ключевых точек: тень на густой сетке
    /// пересчитывалась бы на каждом кадре.
    private static func glow(_ layer: CAShapeLayer, color: Color, radius: CGFloat) {
        layer.shadowColor = NSColor(color).cgColor
        layer.shadowRadius = radius
        layer.shadowOpacity = 0.9
        layer.shadowOffset = .zero
    }
}
