import CoreGraphics
import XCTest
@testable import DOKA

/// Геометрия зеркала губ: где плашка, какая часть кадра в ней видна и как
/// точки кадра ложатся в окно.
///
/// Зачем: зеркало «вытекает» из выреза или нижней кромки — плашка обязана
/// прирастать к краю экрана ровно и не залезать видео под физический вырез.
/// Картинку рисует Core Image (`ciTransform`), маску — `map`: они обязаны
/// давать одно и то же отображение региона в окно, иначе маска съедет с
/// губ. Следование за лицом — в `LipMirrorCameraTests`.
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

    /// Фейковая notch-плашка с плечами (260 pt): продолжение по-прежнему уже
    /// её и заходит под неё на 2 pt.
    @MainActor
    func testBelowFakeNotchPanelWithShoulders() {
        let size = RecorderPanelController.notchGeometry(for: nil).size
        let fake = CGRect(x: screen.midX - size.width / 2, y: screen.maxY - size.height,
                          width: size.width, height: size.height)
        let layout = LipMirrorGeometry.layout(.belowNotchPanel, screen: screen, safeTop: 0, notchWidth: 0,
                                              notchPanel: fake)
        XCTAssertLessThanOrEqual(layout.frame.width, fake.width)
        XCTAssertEqual(layout.frame.maxY, fake.minY + 2)
        XCTAssertEqual(layout.frame.midX, fake.midX)
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

    // MARK: - Сцена и перенос точек

    /// Сцена — наибольший прямоугольник с аспектом окна по центру кадра.
    func testSceneRegionFillsContainerAspect() {
        let camera = CGSize(width: 1280, height: 720)
        let wide = LipMirrorGeometry.sceneRegion(camera: camera, aspect: 120.0 / 224)
        XCTAssertEqual(wide.width, 1280, accuracy: 1e-9)
        XCTAssertEqual(wide.height, 1280 * 120.0 / 224, accuracy: 1e-9)
        XCTAssertEqual(wide.midY, 360, accuracy: 1e-9)
        let tall = LipMirrorGeometry.sceneRegion(camera: camera, aspect: 1)
        XCTAssertEqual(tall, CGRect(x: 280, y: 0, width: 720, height: 720))
    }

    /// Центр области — в центре картинки, масштаб — по её размеру.
    func testMapPutsRegionCenterAtContainerCenter() {
        let region = CGRect(x: 500.5, y: 300.25, width: 224.5, height: 120.25)
        let size = CGSize(width: 224, height: 120)
        for mirrored in [false, true] {
            let center = LipMirrorGeometry.map(CGPoint(x: region.midX, y: region.midY), region: region,
                                               size: size, mirrored: mirrored)
            XCTAssertEqual(center.x, 112, accuracy: 1e-9)
            XCTAssertEqual(center.y, 60, accuracy: 1e-9)
        }
        let corner = LipMirrorGeometry.map(CGPoint(x: region.maxX, y: region.maxY), region: region,
                                           size: size, mirrored: false)
        XCTAssertEqual(corner.x, 224, accuracy: 1e-9)
        XCTAssertEqual(corner.y, 120, accuracy: 1e-9)
    }

    /// В зеркале левый край области уходит вправо, y не меняется.
    func testMirroredMapFlipsHorizontally() {
        let region = CGRect(x: 400, y: 300, width: 200, height: 100)
        let size = CGSize(width: 400, height: 200)
        let p = CGPoint(x: 450, y: 320)
        let plain = LipMirrorGeometry.map(p, region: region, size: size, mirrored: false)
        let mirrored = LipMirrorGeometry.map(p, region: region, size: size, mirrored: true)
        XCTAssertEqual(plain.x, 100, accuracy: 1e-9)
        XCTAssertEqual(mirrored.x, 300, accuracy: 1e-9)
        XCTAssertEqual(mirrored.y, plain.y, accuracy: 1e-9)
        XCTAssertEqual(LipMirrorGeometry.map(CGPoint(x: 400, y: 300), region: region, size: size,
                                             mirrored: true).x, 400, accuracy: 1e-9)
    }

    /// Картинка CoreImage (начало снизу) показывает ту же точку там же, где
    /// её рисует маска (начало сверху): одно преобразование на всё.
    func testCITransformAgreesWithMap() {
        let camera = CGSize(width: 1280, height: 720)
        let region = CGRect(x: 517.3, y: 291.7, width: 231.9, height: 124.2)
        let size = CGSize(width: 448, height: 240)
        let points = [CGPoint(x: 517.3, y: 291.7), CGPoint(x: 640, y: 360), CGPoint(x: 749.2, y: 415.9),
                      CGPoint(x: 0, y: 0), CGPoint(x: 1280, y: 720), CGPoint(x: 600.5, y: 401.25)]
        for mirrored in [false, true] {
            let transform = LipMirrorGeometry.ciTransform(region: region, camera: camera, size: size,
                                                          mirrored: mirrored)
            for p in points {
                let mapped = LipMirrorGeometry.map(p, region: region, size: size, mirrored: mirrored)
                let ci = CGPoint(x: p.x, y: camera.height - p.y).applying(transform)
                XCTAssertEqual(ci.x, mapped.x, accuracy: 1e-9, "\(p) \(mirrored)")
                XCTAssertEqual(ci.y, size.height - mapped.y, accuracy: 1e-9, "\(p) \(mirrored)")
            }
        }
    }
}
