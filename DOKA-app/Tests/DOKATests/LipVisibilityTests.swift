import CoreGraphics
import XCTest
@testable import DOKA

/// Решение «губы видны» для зеркала и журнала дубля.
///
/// Зачем: на закрытом ладонью рте Vision лицо не теряет, а дорисовывает губы —
/// маска легла бы на ладонь, а кадры ушли бы в WISLIP как хорошие. Ловится это
/// по оценке неточности точек самого Vision; поворот головы (неточность растёт
/// у всех точек) закрытым ртом считаться не должен, а край ладони, где
/// неточность ходит около порога, не должен мигать маской. Числа неточности —
/// с живого стенда (открытый рот 0,0063, ладонь 0,0137–0,0163). Кадр 1280×720.
final class LipVisibilityTests: XCTestCase {

    private let frame = CGSize(width: 1280, height: 720)
    private let take = UUID()

    private func face(lips: Double?, eyes: Double?, mouth: CGPoint = CGPoint(x: 640, y: 480)) -> LipFaceSample {
        var sample = LipSyntheticFace.sample(mouth: mouth)
        sample.lipsUncertainty = lips
        sample.eyesUncertainty = eyes
        return sample
    }

    private var open: LipFaceSample { face(lips: 0.0063, eyes: 0.0064) }
    /// Ладонь: губы неточнее глаз в 1,09 раза.
    private var covered: LipFaceSample { face(lips: 0.0150, eyes: 0.0138) }
    /// Между порогами выхода и входа, губы неточнее глаз.
    private var between: LipFaceSample { face(lips: 0.0110, eyes: 0.0100) }

    func testOpenMouthIsVisible() {
        var visibility = LipVisibility()
        XCTAssertFalse(visibility.lipsHidden(in: open, frame: frame, take: take))
    }

    func testCoveredMouthIsHidden() {
        var visibility = LipVisibility()
        XCTAssertTrue(visibility.lipsHidden(in: covered, frame: frame, take: take))
    }

    /// Поворот головы: неточность губ высокая, но у глаз такая же — рот не закрыт.
    func testHeadTurnIsNotCover() {
        var visibility = LipVisibility()
        XCTAssertFalse(visibility.lipsHidden(in: face(lips: 0.0150, eyes: 0.0155), frame: frame, take: take))
    }

    /// Неточность между порогами выхода и входа держит прошлое состояние: край
    /// ладони не мигает маской. Ниже порога выхода губы снова видны, а между
    /// порогами из открытого состояния губы не закрываются.
    func testHysteresisBetweenExitAndEnter() {
        var visibility = LipVisibility()
        XCTAssertTrue(visibility.lipsHidden(in: covered, frame: frame, take: take))
        XCTAssertTrue(visibility.lipsHidden(in: between, frame: frame, take: take), "держится закрытым")
        XCTAssertFalse(visibility.lipsHidden(in: face(lips: 0.0090, eyes: 0.0085), frame: frame, take: take))
        XCTAssertFalse(visibility.lipsHidden(in: between, frame: frame, take: take), "из открытого — нужен вход")
    }

    /// Закрытый рот перешёл в поворот головы: глаза стали не точнее губ —
    /// губы снова видны, хотя неточность выше порога выхода.
    func testCoverEndsWhenEyesAreAsUncertain() {
        var visibility = LipVisibility()
        XCTAssertTrue(visibility.lipsHidden(in: covered, frame: frame, take: take))
        XCTAssertFalse(visibility.lipsHidden(in: face(lips: 0.0150, eyes: 0.0160), frame: frame, take: take))
    }

    /// Губы ушли за нижний край кадра при найденном лице — скрыты, даже если
    /// Vision уверен в точках.
    func testLipsBeyondFrameEdgeAreHidden() {
        var visibility = LipVisibility()
        let low = face(lips: 0.0063, eyes: 0.0064, mouth: CGPoint(x: 640, y: 710))
        XCTAssertTrue(low.outerLips.contains { $0.y > frame.height }, "фикстура: губы за краем")
        XCTAssertTrue(visibility.lipsHidden(in: low, frame: frame, take: take))
    }

    /// Без оценок неточности (созвездие 65) решает только геометрия: скрытыми
    /// губы объявляет только улика.
    func testWithoutEstimatesOnlyGeometryDecides() {
        var visibility = LipVisibility()
        XCTAssertFalse(visibility.lipsHidden(in: face(lips: nil, eyes: nil), frame: frame, take: take))
        XCTAssertFalse(visibility.lipsHidden(in: face(lips: 0.0150, eyes: nil), frame: frame, take: take))
        let low = face(lips: nil, eyes: nil, mouth: CGPoint(x: 640, y: 710))
        XCTAssertTrue(visibility.lipsHidden(in: low, frame: frame, take: take))
    }

    /// Лица нет — это не «губы скрыты» (бокса нет, и `lipsVisible` и так
    /// ложно); губ у лица нет — тоже не улика.
    func testNoFaceAndNoLipsAreNotHiddenFlag() {
        var visibility = LipVisibility()
        XCTAssertFalse(visibility.lipsHidden(in: .none, frame: frame, take: take))
        XCTAssertFalse(LipFaceSample.none.lipsVisible)
        XCTAssertFalse(visibility.lipsHidden(in: LipSyntheticFace.faceWithoutLips(), frame: frame, take: take))
    }

    /// Новый дубль и потеря лица начинают решение заново, с порога входа.
    func testNewTakeAndFaceLossReset() {
        var visibility = LipVisibility()
        XCTAssertTrue(visibility.lipsHidden(in: covered, frame: frame, take: take))
        XCTAssertFalse(visibility.lipsHidden(in: between, frame: frame, take: UUID()))

        XCTAssertTrue(visibility.lipsHidden(in: covered, frame: frame, take: take))
        _ = visibility.lipsHidden(in: .none, frame: frame, take: take)
        XCTAssertFalse(visibility.lipsHidden(in: between, frame: frame, take: take))
    }

    func testLipsVisibleNeedsFaceAndNotHidden() {
        var sample = open
        XCTAssertTrue(sample.lipsVisible)
        sample.lipsHidden = true
        XCTAssertFalse(sample.lipsVisible)
    }
}
