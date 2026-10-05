import CoreGraphics
import XCTest
@testable import DOKA

/// Конвейер зеркала: образец Vision → маска кадра и окно камеры следующего.
///
/// Зачем: картинка кадра рендерится через регион, посчитанный на прошлом
/// кадре, и маска этого кадра обязана идти через ТОТ ЖЕ регион — иначе
/// маска разъедется с губами на величину шага камеры. Новый дубль начинает
/// со сцены, одиночный промах Vision маску не гасит, а без губ камера
/// продолжает жить своей жизнью. Лица синтетические (порядок Vision 14 + 6),
/// 30 к/с, кадр 1280×720, окно 224×120 pt на Retina.
final class LipMirrorPipelineTests: XCTestCase {

    private let camera = CGSize(width: 1280, height: 720)
    private let target = LipMirrorTarget(size: CGSize(width: 224, height: 120), scale: 2, reduceMotion: false)
    private let take = UUID()
    private let dt = 1.0 / 30

    /// Конвейер с часами кадров.
    private final class Rig {
        let pipeline = LipMirrorPipeline()
        let camera: CGSize
        var target: LipMirrorTarget
        var take: UUID
        var t = 1000.0
        var lastRegion = CGRect.null

        init(camera: CGSize, target: LipMirrorTarget, take: UUID) {
            self.camera = camera
            self.target = target
            self.take = take
        }

        /// Один кадр: регион, затем маска через него.
        @discardableResult
        func step(_ sample: LipFaceSample) -> LipMeshPaths? {
            lastRegion = pipeline.region(take: take, camera: camera, target: target)
            let paths = pipeline.update(sample: sample, host: t, camera: camera, region: lastRegion, target: target)
            t += 1.0 / 30
            return paths
        }

        @discardableResult
        func hold(_ sample: LipFaceSample, seconds: Double) -> LipMeshPaths? {
            var paths: LipMeshPaths?
            for _ in 0..<Int((seconds * 30).rounded()) { paths = step(sample) }
            return paths
        }

        /// Регион следующего кадра.
        var next: CGRect { pipeline.region(take: take, camera: camera, target: target) }
    }

    private var scene: CGRect { LipMirrorGeometry.sceneRegion(camera: camera, aspect: target.aspect) }

    private func assertEqual(_ a: CGRect, _ b: CGRect, accuracy: CGFloat = 1e-6,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.minX, b.minX, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(a.minY, b.minY, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(a.width, b.width, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(a.height, b.height, accuracy: accuracy, file: file, line: line)
    }

    func testNewTakeStartsFromScene() {
        let rig = Rig(camera: camera, target: target, take: take)
        assertEqual(rig.next, scene)
        rig.hold(LipSyntheticFace.sample(mouth: CGPoint(x: 800, y: 450)), seconds: 1)
        XCTAssertLessThan(rig.next.width, scene.width / 2, "камера въехала к рту")

        // Новый дубль — снова сцена, без въезда из старого окна.
        rig.take = UUID()
        assertEqual(rig.next, scene)
        rig.step(LipSyntheticFace.sample(mouth: CGPoint(x: 800, y: 450)))
        assertEqual(rig.next, scene)
    }

    /// Новый дубль сбрасывает и маску: удержание, фильтр точек, калибровку.
    func testNewTakeStartsWithCleanMask() throws {
        let rig = Rig(camera: camera, target: target, take: take)
        rig.hold(LipSyntheticFace.sample(mouth: CGPoint(x: 800, y: 450)), seconds: 1)

        // Первый кадр дубля через кадр без губ — удержание прошлого не тянется.
        rig.take = UUID()
        XCTAssertNil(rig.step(.none), "маска прошлого дубля")

        // Губы в другом месте — ровно как у свежего конвейера на том же кадре.
        let sample = LipSyntheticFace.sample(mouth: CGPoint(x: 560, y: 500))
        let paths = try XCTUnwrap(rig.step(sample))
        let fresh = LipMirrorPipeline()
        let region = fresh.region(take: rig.take, camera: camera, target: target)
        assertEqual(region, rig.lastRegion)
        let expected = try XCTUnwrap(fresh.update(sample: sample, host: rig.t - dt, camera: camera, region: region,
                                                  target: target))
        assertEqual(paths.band.boundingBoxOfPath, expected.band.boundingBoxOfPath)
        assertEqual(paths.grid.boundingBoxOfPath, expected.grid.boundingBoxOfPath)
        assertEqual(paths.halo.boundingBoxOfPath, expected.halo.boundingBoxOfPath)
    }

    /// Маска кадра — через регион, переданный в `update` (картинка этого
    /// кадра отрендерена через него), а не через свежий выход камеры.
    func testPathsUseRegionOfThatFrame() throws {
        let pipeline = LipMirrorPipeline()
        let sample = LipSyntheticFace.sample()
        _ = pipeline.region(take: take, camera: camera, target: target)
        let region = CGRect(x: 517.5, y: 380.25, width: 300, height: 160.7)
        let paths = try XCTUnwrap(pipeline.update(sample: sample, host: 1000, camera: camera, region: region,
                                                  target: target))

        // Первый кадр: фильтр точек пропускает их как есть, калибровка — с нуля.
        var calibrator = LipMeshCalibrator()
        let contours = try XCTUnwrap(LipContours.vision(outer: sample.outerLips, inner: sample.innerLips))
        let mesh = try XCTUnwrap(LipMesh.make(contours, calibration: calibrator.update(contours)))
        let expected = LipMeshPaths.make(mesh) {
            LipMirrorGeometry.map($0, region: region, size: self.target.size, mirrored: true)
        }
        assertEqual(paths.band.boundingBoxOfPath, expected.band.boundingBoxOfPath)
        assertEqual(paths.brackets.boundingBoxOfPath, expected.brackets.boundingBoxOfPath)
        // Камера ещё на сцене — въезд после трёх фиксов (`reacquireFixes`).
        assertEqual(pipeline.region(take: take, camera: camera, target: target), scene)
    }

    /// Ось глаз доходит до таблицы Vision: при наклоне головы внутренний
    /// контур идёт через внешние уголки, а не по своим крайним точкам.
    func testEyeAxisReachesContours() throws {
        let angle = 55 * CGFloat.pi / 180
        let mouth = CGPoint(x: 640, y: 480)
        func tilted(_ points: [CGPoint], scaleY: CGFloat) -> [CGPoint] {
            let c = cos(angle), s = sin(angle)
            return points.map { p in
                let x = p.x - mouth.x, y = (p.y - mouth.y) * scaleY
                return CGPoint(x: mouth.x + x * c - y * s, y: mouth.y + x * s + y * c)
            }
        }
        var sample = LipSyntheticFace.sample(mouth: mouth)
        sample.outerLips = tilted(sample.outerLips, scaleY: 2.5)
        sample.innerLips = tilted(sample.innerLips, scaleY: 2.5)
        sample.eyes = tilted(sample.eyes, scaleY: 1)

        let pipeline = LipMirrorPipeline()
        _ = pipeline.region(take: take, camera: camera, target: target)
        let region = CGRect(x: 400, y: 300, width: 480, height: 480 * target.aspect)
        let paths = try XCTUnwrap(pipeline.update(sample: sample, host: 1000, camera: camera, region: region,
                                                  target: target))

        func expected(axis: CGVector?) throws -> LipMeshPaths {
            let contours = try XCTUnwrap(axis.map {
                LipContours.vision(outer: sample.outerLips, inner: sample.innerLips, axis: $0)
            } ?? LipContours.vision(outer: sample.outerLips, inner: sample.innerLips))
            var calibrator = LipMeshCalibrator()
            let mesh = try XCTUnwrap(LipMesh.make(contours, calibration: calibrator.update(contours)))
            return LipMeshPaths.make(mesh) {
                LipMirrorGeometry.map($0, region: region, size: self.target.size, mirrored: true)
            }
        }
        let withAxis = try expected(axis: CGVector(dx: cos(angle), dy: sin(angle)))
        let horizontal = try expected(axis: nil)
        assertEqual(paths.band.boundingBoxOfPath, withAxis.band.boundingBoxOfPath)
        assertEqual(paths.grid.boundingBoxOfPath, withAxis.grid.boundingBoxOfPath)
        // Без оси сетка другая — иначе тест ничего бы не различал.
        XCTAssertNotEqual(paths.grid.boundingBoxOfPath, horizontal.grid.boundingBoxOfPath)
    }

    /// Reduce Motion из цели окна доходит до камеры: въезд — сразу в окно
    /// рта, без промежуточных ширин; снятый посреди дубля — выезд снова глайдом.
    func testReduceMotionReachesCamera() {
        let reduced = LipMirrorTarget(size: target.size, scale: target.scale, reduceMotion: true)
        let rig = Rig(camera: camera, target: reduced, take: take)
        let sample = LipSyntheticFace.sample()
        rig.step(sample)
        rig.step(sample)
        assertEqual(rig.next, scene)
        rig.step(sample)
        let tracked = rig.next
        XCTAssertEqual(tracked.width, LipMirrorCamera.zoom * LipMirrorCamera.mouthPerEyes * 126, accuracy: 1)

        rig.target = target
        var widths: [CGFloat] = []
        for _ in 0..<36 {
            rig.step(.none)
            widths.append(rig.next.width)
        }
        XCTAssertEqual(widths.last!, scene.width, accuracy: 0.5)
        XCTAssertTrue(widths.contains { $0 > tracked.width + 1 && $0 < scene.width - 1 }, "выезд без глайда")
    }

    func testMaskHeldThroughSingleMissThenHidden() {
        let rig = Rig(camera: camera, target: target, take: take)
        XCTAssertNotNil(rig.hold(LipSyntheticFace.sample(), seconds: 0.5))
        XCTAssertNotNil(rig.step(.none), "одиночный промах Vision маску не гасит")
        XCTAssertNotNil(rig.step(LipSyntheticFace.sample()))
        XCTAssertNotNil(rig.step(LipSyntheticFace.faceWithoutLips()))
        XCTAssertNil(rig.hold(LipSyntheticFace.faceWithoutLips(), seconds: 0.2), "долгий промах — маски нет")
    }

    /// Одиночный промах Vision фильтр точек НЕ сбрасывает: после него маска
    /// продолжает с прошлого состояния, а не прыгает в сырые точки.
    func testMissDoesNotResetPointsFilter() throws {
        let rig = Rig(camera: camera, target: target, take: take)
        rig.hold(LipSyntheticFace.sample(), seconds: 0.5)
        rig.step(.none)
        let moved = LipSyntheticFace.sample(mouth: CGPoint(x: 660, y: 480))
        let paths = try XCTUnwrap(rig.step(moved))

        // Те же точки без фильтра через тот же регион. Калибровка у свежего
        // конвейера своя, но она меняет форму сетки, а не положение рта.
        let raw = LipMirrorPipeline()
        _ = raw.region(take: take, camera: camera, target: target)
        let jumped = try XCTUnwrap(raw.update(sample: moved, host: 0, camera: camera, region: rig.lastRegion,
                                              target: target))
        XCTAssertGreaterThan(abs(paths.band.boundingBoxOfPath.midX - jumped.band.boundingBoxOfPath.midX), 1,
                             "фильтр начал заново после промаха")
    }

    /// Камера ведётся по СЫРЫМ точкам: у неё свой фильтр, двойное сглаживание
    /// только добавило бы запаздывания.
    func testCameraUsesRawPoints() throws {
        let rig = Rig(camera: camera, target: target, take: take)
        var reference = LipMirrorCamera()
        for k in 0..<45 {
            let sample = LipSyntheticFace.sample(mouth: CGPoint(x: 560 + 4 * CGFloat(k), y: 480))
            let host = rig.t
            rig.step(sample)
            let eyes = sample.eyes.sorted { $0.x < $1.x }
            let axis = CGVector(dx: eyes[1].x - eyes[0].x, dy: eyes[1].y - eyes[0].y)
            let contours = try XCTUnwrap(LipContours.vision(outer: sample.outerLips, inner: sample.innerLips,
                                                            axis: axis))
            let fix = LipMirrorCamera.fix(corners: contours.outer.corners, eyes: sample.eyes, box: sample.box)
            let xs = sample.outerLips.map(\.x), ys = sample.outerLips.map(\.y)
            let lips = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
            let expected = reference.update(fix, lips: lips, at: host, camera: camera, aspect: target.aspect)
            assertEqual(rig.next, expected)
        }
    }

    func testCameraRegionAdvancesTowardMouth() {
        let rig = Rig(camera: camera, target: target, take: take)
        let mouth = CGPoint(x: 820, y: 460)
        rig.hold(LipSyntheticFace.sample(mouth: mouth), seconds: 1)
        let region = rig.next
        XCTAssertLessThan(region.width, 400, "окно сузилось к рту")
        XCTAssertTrue(region.contains(mouth))
        XCTAssertEqual(region.midX, mouth.x, accuracy: 20)
        XCTAssertEqual(region.height / region.width, target.aspect, accuracy: 1e-6)
    }

    func testNoLipsGivesNoPathsButCameraKeepsRunning() {
        let rig = Rig(camera: camera, target: target, take: take)
        let mouth = CGPoint(x: 820, y: 460)
        rig.hold(LipSyntheticFace.sample(mouth: mouth), seconds: 1)
        let tracked = rig.next

        // Губ нет, лицо есть: маска гаснет после удержания, окно пока держится.
        XCTAssertNil(rig.hold(LipSyntheticFace.faceWithoutLips(mouth: mouth), seconds: 0.3))
        XCTAssertEqual(rig.next.width, tracked.width, accuracy: tracked.width * 0.1)

        // Дольше `lostAfter` — камера сама выезжает на сцену.
        XCTAssertNil(rig.hold(LipSyntheticFace.faceWithoutLips(mouth: mouth), seconds: 1.5))
        assertEqual(rig.next, scene, accuracy: 0.5)
    }
}
