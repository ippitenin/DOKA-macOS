import SwiftUI
import XCTest
@testable import DOKA

/// Плашка, «вытекающая» из кромки экрана: плоский край у кромки, вогнутые
/// плечи, скруглённый противоположный край. Общая у notch-плашки и зеркала губ.
///
/// Зачем: прежняя notch-плашка упиралась в кромку прямым углом. Плечи —
/// это расширение у самого края: там плашка шире тела и сужается вогнутой
/// дугой.
final class EdgeFlowShapeTests: XCTestCase {
    private let rect = CGRect(x: 0, y: 0, width: 260, height: 32)

    /// Плоский верх: у верхнего угла плечо закрашено, у нижнего угла — пусто.
    func testTopFlatEdgeHasShouldersAtTop() {
        let path = EdgeFlowShape(flatEdge: .top, shoulder: 10, corner: 14).path(in: rect)
        // Вогнутое плечо сходит на нет у края экрана: на середине (x = 5)
        // его толщина ~0,86 pt.
        XCTAssertTrue(path.contains(CGPoint(x: 5, y: 0.3)), "плечо у верхнего края")
        XCTAssertFalse(path.contains(CGPoint(x: 5, y: 5)), "под дугой плеча — пусто")
        XCTAssertFalse(path.contains(CGPoint(x: 1, y: 31)), "под плечом — пусто")
        XCTAssertTrue(path.contains(CGPoint(x: 130, y: 31)), "тело плашки внизу по центру")
        XCTAssertFalse(path.contains(CGPoint(x: 11, y: 31)), "нижний угол тела скруглён")
    }

    /// Плоский низ — то же зеркально.
    func testBottomFlatEdgeHasShouldersAtBottom() {
        let path = EdgeFlowShape(flatEdge: .bottom, shoulder: 10, corner: 14).path(in: rect)
        XCTAssertTrue(path.contains(CGPoint(x: 5, y: 31.7)))
        XCTAssertFalse(path.contains(CGPoint(x: 5, y: 27)))
        XCTAssertFalse(path.contains(CGPoint(x: 1, y: 1)))
        XCTAssertTrue(path.contains(CGPoint(x: 130, y: 1)))
    }

    /// Фейковая notch-плашка (экран без выреза) шире прежней на два плеча.
    @MainActor
    func testFakeNotchPanelIncludesShoulders() {
        let geometry = RecorderPanelController.notchGeometry(for: nil)
        XCTAssertEqual(geometry.size, CGSize(width: 240 + 2 * DS.EdgePlate.shoulder, height: 36))
        XCTAssertEqual(geometry.notchWidth, 0)
    }
}
