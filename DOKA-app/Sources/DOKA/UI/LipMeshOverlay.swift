import AppKit
import QuartzCore
import SwiftUI

/// Маска-сетка губ поверх кадра зеркала: полупрозрачная полоса губ,
/// пунктирный ореол, спицы и промежуточные кольца между контурами, внешний
/// (персик) и внутренний (индиго) контуры, ключевые точки (точки Vision
/// после фильтра One Euro, без интерполяции) и угловые скобки вокруг рта.
/// Слои ставятся прямо в контейнер видео (координаты сверху слева).
/// Геометрия — в `LipMeshPaths` (строится вне главного потока); здесь только
/// стиль и порядок слоёв.
///
/// Маска — свет, а не краска: каждый слой ложится на видео наложением
/// «экран» (осветляет губы, а не закрашивает их) с одинаковой
/// непрозрачностью `DS.Lips.maskOpacity` у каждого слоя. Фильтр — встроенный
/// фильтр Core Animation по имени, не CIFilter: флаг
/// `layerUsesCoreImageFilters` у вью-хоста (`LipMirrorVideoNSView`) ему не
/// нужен и стоит страховкой на случай перехода на CIFilter.
///
/// Неявной анимации у `CAShapeLayer.path` нет: пути меняются скачком, на
/// каждом результате трекера.
final class LipMeshOverlay {
    static let rimWidth: CGFloat = 0.9
    static let ringWidth: CGFloat = 0.4
    static let haloWidth: CGFloat = 0.5
    static let bracketWidth: CGFloat = 0.8
    /// Свечение контуров и ключевых точек.
    static let glowRadius: CGFloat = 3
    static let glowOpacity: Float = 0.6
    /// Наложение «экран» — имя фильтра компоновки Core Animation.
    static let blend = "screenBlendMode"

    private let fill = CAShapeLayer()
    private let halo = CAShapeLayer()
    private let spokes = CAShapeLayer()
    private let ringOuter = CAShapeLayer()
    private let ringInner = CAShapeLayer()
    private let outerRim = CAShapeLayer()
    private let innerRim = CAShapeLayer()
    private let keys = CAShapeLayer()
    private let brackets = CAShapeLayer()

    init() {
        fill.fillColor = NSColor(DS.Lips.fill).cgColor
        fill.fillRule = .evenOdd
        fill.strokeColor = nil

        Self.stroke(halo, DS.Lips.halo, width: Self.haloWidth)
        // Пунктир отсчитывается от начала каждого подпути, а ореол порезан
        // на подпути по узлам (`LipMeshPaths.make`): штрихи не ползут на речи.
        halo.lineDashPattern = [2, 3]

        Self.stroke(spokes, DS.Lips.spoke, width: Self.ringWidth)
        Self.stroke(ringOuter, DS.Lips.ringOuter, width: Self.ringWidth)
        Self.stroke(ringInner, DS.Lips.ringInner, width: Self.ringWidth)

        Self.stroke(outerRim, DS.Lips.outer, width: Self.rimWidth)
        Self.glow(outerRim, color: DS.Lips.outer)
        Self.stroke(innerRim, DS.Lips.inner, width: Self.rimWidth)
        Self.glow(innerRim, color: DS.Lips.inner)

        keys.fillColor = NSColor(DS.Lips.dot).cgColor
        keys.strokeColor = nil
        Self.glow(keys, color: DS.Lips.dot)

        Self.stroke(brackets, DS.Lips.bracket, width: Self.bracketWidth)
        brackets.lineCap = .round

        for layer in layers {
            layer.compositingFilter = Self.blend
            layer.opacity = DS.Lips.maskOpacity
        }
    }

    /// Снизу вверх: заливка под сеткой, ключевые точки и скобки — сверху.
    var layers: [CAShapeLayer] {
        [fill, halo, spokes, ringOuter, ringInner, outerRim, innerRim, keys, brackets]
    }

    func install(in container: CALayer) {
        for layer in layers { container.addSublayer(layer) }
    }

    /// Пути одного кадра; nil — маску спрятать. Вызывающий сам решает про
    /// транзакцию: зеркало меняет маску и картинку вместе, без анимаций.
    /// Колец в сетке два (`LipMesh.bands`); лишние, если их станет больше,
    /// не рисуются.
    func apply(_ paths: LipMeshPaths?) {
        fill.path = paths?.band
        halo.path = paths?.halo
        spokes.path = paths?.spokes
        ringOuter.path = paths?.rings.first
        ringInner.path = paths.flatMap { $0.rings.count > 1 ? $0.rings[1] : nil }
        outerRim.path = paths?.outerRim
        innerRim.path = paths?.innerRim
        keys.path = paths?.keys
        brackets.path = paths?.brackets
    }

    /// Масштаб экрана — иначе на Retina пути растрируются в 1×.
    func setScale(_ scale: CGFloat) {
        for layer in layers { layer.contentsScale = scale }
    }

    private static func stroke(_ layer: CAShapeLayer, _ color: Color, width: CGFloat) {
        layer.fillColor = nil
        layer.strokeColor = NSColor(color).cgColor
        layer.lineWidth = width
        layer.lineJoin = .round
    }

    /// Мягкое свечение — только у контуров и ключевых точек: тень на густой
    /// сетке пересчитывалась бы на каждом кадре.
    private static func glow(_ layer: CAShapeLayer, color: Color) {
        layer.shadowColor = NSColor(color).cgColor
        layer.shadowRadius = glowRadius
        layer.shadowOpacity = glowOpacity
        layer.shadowOffset = .zero
    }
}
