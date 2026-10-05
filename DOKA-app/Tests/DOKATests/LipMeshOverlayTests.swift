import AppKit
import QuartzCore
import SwiftUI
import XCTest
@testable import DOKA

/// Стиль маски губ: свет, а не краска.
///
/// Зачем: маска ложится на видео наложением «экран» с одинаковой
/// непрозрачностью у каждого слоя. Слой без фильтра закрашивал бы губы краской — ровно то,
/// от чего отказались после живой проверки; заметить это можно только
/// глазами, поэтому инвариант держит тест.
final class LipMeshOverlayTests: XCTestCase {

    func testEveryLayerBlendsAsLight() {
        let overlay = LipMeshOverlay()
        XCTAssertEqual(overlay.layers.count, 9)
        for layer in overlay.layers {
            XCTAssertEqual(layer.compositingFilter as? String, "screenBlendMode")
            XCTAssertEqual(layer.opacity, DS.Lips.maskOpacity)
        }
        XCTAssertEqual(DS.Lips.maskOpacity, 0.8, accuracy: 1e-6)
    }

    /// Кольца перетекают от персика к индиго: смесь `Color.mix` доходит до
    /// `strokeColor` слоёв (а не теряется при переводе в `NSColor`), и синий
    /// растёт снаружи внутрь — внешний контур, кольца, внутренний контур.
    func testRingsBlendFromPeachToIndigo() throws {
        let layers = LipMeshOverlay().layers
        let sRGB = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        func blue(_ layer: CAShapeLayer) throws -> CGFloat {
            let color = try XCTUnwrap(layer.strokeColor?.converted(to: sRGB, intent: .defaultIntent, options: nil))
            return try XCTUnwrap(color.components)[2]
        }
        // Порядок слоёв — `LipMeshOverlay.layers`: кольца 3…4, контуры 5…6.
        let steps = try [layers[5], layers[3], layers[4], layers[6]].map(blue)
        for (a, b) in zip(steps, steps.dropFirst()) { XCTAssertLessThan(a, b) }
    }

    /// Все слои ставятся в контейнер, путей до первого кадра нет, а nil
    /// прячет маску целиком.
    func testInstallAndApply() throws {
        let overlay = LipMeshOverlay()
        let container = CALayer()
        overlay.install(in: container)
        XCTAssertEqual(container.sublayers?.count, overlay.layers.count)
        XCTAssertTrue(overlay.layers.allSatisfy { $0.path == nil })

        let lips = LipSyntheticFace.lips()
        let mesh = try XCTUnwrap(LipMesh.make(outer: lips.outer, inner: lips.inner))
        overlay.apply(LipMeshPaths.make(mesh) { $0 })
        XCTAssertTrue(overlay.layers.allSatisfy { $0.path != nil })
        overlay.apply(nil)
        XCTAssertTrue(overlay.layers.allSatisfy { $0.path == nil })
    }
}
