import CoreGraphics
import XCTest
@testable import DOKA

/// Геометрия зеркала губ: где плашка, где кадр рта, как он следует за лицом.
///
/// Зачем: зеркало «вытекает» из выреза или нижней кромки — плашка обязана
/// прирастать к краю экрана ровно, не залезать видео под физический вырез и
/// не дрожать за каждым пикселем бокса. Отражение — только на экране: рот
/// в зеркале должен оказаться в центре именно отражённой картинки.
final class LipMirrorGeometryTests: XCTestCase {

    /// MacBook с вырезом: экран 1512×982, вырез 200 pt, высота 32.
    private let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private let notchPanel = CGRect(x: 526, y: 950, width: 460, height: 32)

    // MARK: - Правило размещения

    func testBottomStylesUseTopNotch() {
        for style in [RecorderStyle.classic, .studio, .aurora, .mini, .hidden] {
            for variant in LipMirrorNotchVariant.allCases {
                XCTAssertEqual(LipMirrorPlacement.resolve(style: style, variant: variant), .topNotch, "\(style)")
            }
        }
    }

    func testNotchStyleFollowsVariant() {
        XCTAssertEqual(LipMirrorPlacement.resolve(style: .notch, variant: .continuation), .belowNotchPanel)
        XCTAssertEqual(LipMirrorPlacement.resolve(style: .notch, variant: .bottom), .bottomEdge)
    }

    // MARK: - Рамки

    /// Сверху: приросла к верхней кромке, по центру, видео ниже выреза.
    func testTopNotchHangsFromTopEdgeBelowNotch() {
        let layout = LipMirrorGeometry.layout(.topNotch, screen: screen, safeTop: 32, notchWidth: 200,
                                              notchPanel: nil)
        XCTAssertEqual(layout.frame.maxY, screen.maxY)
        XCTAssertEqual(layout.frame.midX, screen.midX)
        XCTAssertGreaterThanOrEqual(layout.video.minY, 32)
        XCTAssertEqual(layout.flatEdge, .top)
        XCTAssertGreaterThan(layout.frame.width, 200)   // шире выреза: вытекает из-под него
    }

    /// Экран без выреза: та же плашка от верхней кромки.
    func testTopNotchWithoutHardwareNotch() {
        let layout = LipMirrorGeometry.layout(.topNotch, screen: screen, safeTop: 0, notchWidth: 0,
                                              notchPanel: nil)
        XCTAssertEqual(layout.frame.maxY, screen.maxY)
        XCTAssertGreaterThan(layout.video.minY, 0)
    }

    /// Продолжение notch-плашки: заходит под неё ровно на 2 pt — без шва.
    func testBelowNotchPanelOverlapsPanelBy2pt() {
        let layout = LipMirrorGeometry.layout(.belowNotchPanel, screen: screen, safeTop: 32, notchWidth: 200,
                                              notchPanel: notchPanel)
        XCTAssertEqual(layout.frame.maxY, notchPanel.minY + 2)
        XCTAssertEqual(layout.frame.midX, notchPanel.midX)
        XCTAssertLessThanOrEqual(layout.frame.width, notchPanel.width)
        XCTAssertEqual(layout.flatEdge, .top)
    }

    /// «Нижний вырез»: прирастает к нижней кромке экрана, плоский низ.
    func testBottomEdgeSitsOnScreenBottom() {
        let layout = LipMirrorGeometry.layout(.bottomEdge, screen: screen, safeTop: 32, notchWidth: 200,
                                              notchPanel: notchPanel)
        XCTAssertEqual(layout.frame.minY, screen.minY)
        XCTAssertEqual(layout.frame.midX, screen.midX)
        XCTAssertEqual(layout.flatEdge, .bottom)
        XCTAssertLessThanOrEqual(layout.video.maxY, layout.frame.height)
    }

    /// Видео целиком внутри окна во всех вариантах.
    func testVideoFitsInsideWindow() {
        for placement in [LipMirrorPlacement.topNotch, .belowNotchPanel, .bottomEdge] {
            let layout = LipMirrorGeometry.layout(placement, screen: screen, safeTop: 32, notchWidth: 200,
                                                  notchPanel: notchPanel)
            let bounds = CGRect(origin: .zero, size: layout.frame.size)
            XCTAssertTrue(bounds.contains(layout.video), "\(placement)")
        }
    }

    // MARK: - Кадр рта

    /// Рот в центре контейнера и занимает ~1/2,2 его ширины.
    func testViewportCentersMouth() {
        let mouth = CGRect(x: 600, y: 450, width: 100, height: 40)   // центр 650, 470
        let container = CGSize(width: 220, height: 120)
        let frame = LipMirrorGeometry.previewFrame(mouth: mouth, camera: CGSize(width: 1280, height: 720),
                                                   container: container, mirrored: false)
        let scale = frame.width / 1280
        XCTAssertEqual(frame.minX + 650 * scale, 110, accuracy: 0.01)
        XCTAssertEqual(frame.minY + 470 * scale, 60, accuracy: 0.01)
        XCTAssertEqual(100 * scale, 220 / 2.2, accuracy: 0.01)
        XCTAssertEqual(frame.height / frame.width, 720.0 / 1280, accuracy: 1e-6)
    }

    /// В зеркале рот тоже в центре — но уже отражённой картинки.
    func testViewportMirroredCentersMirroredMouth() {
        let mouth = CGRect(x: 300, y: 450, width: 100, height: 40)   // центр 350
        let frame = LipMirrorGeometry.previewFrame(mouth: mouth, camera: CGSize(width: 1280, height: 720),
                                                   container: CGSize(width: 220, height: 120), mirrored: true)
        let scale = frame.width / 1280
        XCTAssertEqual(frame.minX + (1280 - 350) * scale, 110, accuracy: 0.01)
    }

    // MARK: - Сглаживание

    /// Мелкое дрожание бокса (меньше мёртвой зоны) кадр не двигает.
    func testSmootherIgnoresJitter() {
        var smoother = LipMirrorSmoother()
        let base = CGRect(x: 600, y: 450, width: 100, height: 40)
        _ = smoother.update(base)
        let next = smoother.update(base.offsetBy(dx: 1, dy: -1))
        XCTAssertEqual(next, base)
    }

    /// Поворот головы — кадр догоняет плавно, а не прыжком.
    func testSmootherFollowsMovementGradually() throws {
        var smoother = LipMirrorSmoother()
        let base = CGRect(x: 600, y: 450, width: 100, height: 40)
        _ = smoother.update(base)
        let moved = base.offsetBy(dx: 100, dy: 0)
        let first = try XCTUnwrap(smoother.update(moved))
        XCTAssertGreaterThan(first.midX, base.midX)
        XCTAssertLessThan(first.midX, moved.midX)
        var last = first
        for _ in 0..<40 { last = smoother.update(moved) ?? last }
        XCTAssertEqual(last.midX, moved.midX, accuracy: 2)
    }
}
