import CoreGraphics
import XCTest
@testable import DOKA

/// Один фиксированный кроп на весь дубль губ.
///
/// Зачем: WISLIP сам ищет лицо (S3FD на кадре ×0,25 — лицо должно быть
/// крупнее 25 px) и сам трекает его по кадрам. От DOKA нужен квадрат, в
/// котором лицо есть ВСЕГДА, с запасом, и который не дрожит: покадровый кроп
/// дал бы ложные «смены сцены». Тесный кроп WISLIP не переварит.
final class LipCropPlannerTests: XCTestCase {

    private let frame = CGSize(width: 1280, height: 720)

    private func boxes(_ count: Int, x: (Int) -> CGFloat, y: CGFloat = 210, side: CGFloat = 300) -> [CGRect] {
        (0..<count).map { CGRect(x: x($0), y: y, width: side, height: side) }
    }

    /// Неподвижное лицо 300 px: квадрат 2,3 лица, центр чуть ниже центра лица,
    /// вдвинут в кадр.
    func testStaticFace() throws {
        let plan = try XCTUnwrap(LipCropPlanner.plan(faces: boxes(30, x: { _ in 490 }), frame: frame))
        XCTAssertEqual(plan.rect, CGRect(x: 296, y: 30, width: 690, height: 690))
        XCTAssertEqual(plan.faceInOutputPx, 300 * 512 / 690, accuracy: 0.01)
    }

    /// Голова гуляла влево-вправо — квадрат охватывает весь путь, но не больше кадра.
    func testMovingHeadIsCoveredButClampedToFrame() throws {
        let plan = try XCTUnwrap(LipCropPlanner.plan(faces: boxes(41, x: { 300 + CGFloat($0) * 10 }, side: 200),
                                                     frame: frame))
        XCTAssertEqual(plan.rect.width, 720)
        XCTAssertEqual(plan.rect.height, 720)
        XCTAssertEqual(plan.rect.minY, 0)
        XCTAssertLessThanOrEqual(plan.rect.minX, 300)
        XCTAssertGreaterThanOrEqual(plan.rect.maxX, 900)
    }

    /// Одиночный ложный бокс (лицо на плакате сзади) не раздувает кроп.
    func testOutlierIsIgnored() throws {
        var faces = boxes(30, x: { _ in 490 })
        faces.append(CGRect(x: 20, y: 20, width: 60, height: 60))
        let plan = try XCTUnwrap(LipCropPlanner.plan(faces: faces, frame: frame))
        XCTAssertEqual(plan.rect, CGRect(x: 296, y: 30, width: 690, height: 690))
    }

    /// Лицо у правого края — квадрат прижат к краю, а не вылезает за кадр.
    func testFaceAtEdgeIsClampedInsideFrame() throws {
        let plan = try XCTUnwrap(LipCropPlanner.plan(faces: boxes(10, x: { _ in 1060 }, side: 200), frame: frame))
        XCTAssertEqual(plan.rect.maxX, 1280)
        XCTAssertGreaterThanOrEqual(plan.rect.minY, 0)
        XCTAssertLessThanOrEqual(plan.rect.maxY, 720)
    }

    /// Далёкое лицо: квадрат не меньше 384 px, а лицо в выходе мелкое —
    /// планировщик это сообщает, решение принимает вердикт.
    func testSmallFaceReportsSmallOutput() throws {
        let plan = try XCTUnwrap(LipCropPlanner.plan(faces: boxes(10, x: { _ in 600 }, y: 300, side: 60), frame: frame))
        XCTAssertEqual(plan.rect.width, 384)
        XCTAssertEqual(plan.faceInOutputPx, 60 * 512 / 384, accuracy: 0.01)
    }

    /// Целые чётные пиксели: кодеры 4:2:0 не любят нечётные края.
    func testRectUsesEvenIntegers() throws {
        let faces = (0..<20).map { CGRect(x: 401.3 + Double($0), y: 133.7, width: 257.9, height: 263.1) }
        let r = try XCTUnwrap(LipCropPlanner.plan(faces: faces, frame: frame)).rect
        for v in [r.minX, r.minY, r.width, r.height] {
            XCTAssertEqual(v, v.rounded())
            XCTAssertEqual(Int(v) % 2, 0)
        }
    }

    func testNoFacesNoPlan() {
        XCTAssertNil(LipCropPlanner.plan(faces: [], frame: frame))
    }
}
