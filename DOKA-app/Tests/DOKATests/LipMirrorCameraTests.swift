import CoreGraphics
import XCTest
@testable import DOKA

/// Спокойная камера зеркала губ.
///
/// Зачем: прежнее зеркало держалось за бокс рта и «дышало» на каждом слоге,
/// а при потере лица прыгало. Камера держится за лицо (межглазное, середина
/// уголков) и двигается только глайдами и One Euro — ни речь, ни мигающее
/// лицо, ни повторный захват не должны давать рывков. Последовательности —
/// синтетические, 30 к/с, лицо анфас: межглазное 126 px, бокс детектора
/// 345 px, кадр 1280×720, окно зеркала 224×120.
final class LipMirrorCameraTests: XCTestCase {

    private let camera = CGSize(width: 1280, height: 720)
    private let aspect: CGFloat = 120.0 / 224
    private let d: CGFloat = 126
    private let boxSide: CGFloat = 345
    private let dt = 1.0 / 30
    /// Предельный шаг окна за кадр — доля его ширины.
    private let maxStep: CGFloat = 0.08

    private var mouthWidth: CGFloat { LipMirrorCamera.mouthPerEyes * d }

    // MARK: - Синтетическое лицо

    /// Опора лица с серединой уголков `m`. `eyeScale` сжимает межглазное
    /// (поворот головы), `mouth` — ширина рта, `eyes` — середина глаз (по
    /// умолчанию на 1,1 межглазного выше рта; бокс лица — вокруг неё).
    private func fix(_ m: CGPoint, eyeScale: CGFloat = 1, mouth: CGFloat? = nil,
                     eyes: CGPoint? = nil) -> LipMirrorCamera.Fix {
        let w = mouth ?? mouthWidth
        let e = eyes ?? CGPoint(x: m.x, y: m.y - 1.1 * d)
        let eyeHalf = d * eyeScale / 2
        let fix = LipMirrorCamera.fix(
            corners: (CGPoint(x: m.x - w / 2, y: m.y), CGPoint(x: m.x + w / 2, y: m.y)),
            eyes: [CGPoint(x: e.x - eyeHalf, y: e.y), CGPoint(x: e.x + eyeHalf, y: e.y)],
            box: CGRect(x: e.x - boxSide / 2, y: e.y - 0.4 * boxSide, width: boxSide, height: boxSide))
        return fix!
    }

    /// Камера с часами кадров.
    private struct Rig {
        var camera = LipMirrorCamera()
        var t = 1000.0
        var frames: [CGRect] = []
        let size: CGSize
        let aspect: CGFloat

        @discardableResult
        mutating func step(_ fix: LipMirrorCamera.Fix?, lips: CGRect? = nil) -> CGRect {
            let rect = camera.update(fix, lips: lips, at: t, camera: size, aspect: aspect)
            frames.append(rect)
            t += 1.0 / 30
            return rect
        }

        @discardableResult
        mutating func hold(_ fix: LipMirrorCamera.Fix?, seconds: Double, lips: CGRect? = nil) -> CGRect {
            var rect = CGRect.zero
            for _ in 0..<Int((seconds * 30).rounded()) { rect = step(fix, lips: lips) }
            return rect
        }
    }

    private func rig(reduceMotion: Bool = false) -> Rig {
        var rig = Rig(size: camera, aspect: aspect)
        rig.camera.reduceMotion = reduceMotion
        return rig
    }

    private var scene: CGRect { LipMirrorGeometry.sceneRegion(camera: camera, aspect: aspect) }

    /// Сдвиг окна между кадрами в долях ширины прежнего: центр и ширина.
    private func step(_ a: CGRect, _ b: CGRect) -> CGFloat {
        max(hypot(b.midX - a.midX, b.midY - a.midY), abs(b.width - a.width)) / a.width
    }

    private func maxStep(_ frames: ArraySlice<CGRect>) -> CGFloat {
        zip(frames, frames.dropFirst()).map { step($0, $1) }.max() ?? 0
    }

    /// Где точка видна в окне, в долях его размера (0,5 — центр).
    private func onScreen(_ p: CGPoint, _ r: CGRect) -> CGPoint {
        CGPoint(x: (p.x - r.minX) / r.width, y: (p.y - r.minY) / r.height)
    }

    private func assertRect(_ a: CGRect, _ b: CGRect, accuracy: CGFloat,
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.midX, b.midX, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(a.midY, b.midY, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(a.width, b.width, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(a.height, b.height, accuracy: accuracy, file: file, line: line)
    }

    // MARK: - Опора

    /// Центр окна — середина уголков, сдвинутая к подбородку на drop·scale,
    /// при любом порядке глаз; лицо вверх ногами — сдвиг тоже к подбородку.
    func testFixCenterSitsBelowMouthCorners() throws {
        let corners = (left: CGPoint(x: 600, y: 500), right: CGPoint(x: 705, y: 500))
        let left = CGPoint(x: 589.5, y: 360), right = CGPoint(x: 715.5, y: 360)
        let box = CGRect(x: 480, y: 240, width: boxSide, height: boxSide)
        let a = try XCTUnwrap(LipMirrorCamera.fix(corners: corners, eyes: [left, right], box: box))
        let b = try XCTUnwrap(LipMirrorCamera.fix(corners: corners, eyes: [right, left], box: box))
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.scale, 126, accuracy: 1e-9)
        XCTAssertEqual(a.center.x, 652.5, accuracy: 1e-9)
        XCTAssertEqual(a.center.y, 500 + LipMirrorCamera.drop * 126, accuracy: 1e-9)

        let upsideDown = try XCTUnwrap(LipMirrorCamera.fix(
            corners: corners, eyes: [CGPoint(x: 589.5, y: 640), CGPoint(x: 715.5, y: 640)], box: box))
        XCTAssertEqual(upsideDown.center.y, 500 - LipMirrorCamera.drop * 126, accuracy: 1e-9)
    }

    /// Без глаз (или с одним) — масштаб по боксу, сдвиг вниз кадра; нечем
    /// мерить — опоры нет.
    func testFixWithoutEyesUsesBox() throws {
        let corners = (left: CGPoint(x: 600, y: 500), right: CGPoint(x: 705, y: 500))
        let box = CGRect(x: 480, y: 240, width: boxSide, height: boxSide)
        let scale = LipMirrorCamera.kappa * boxSide
        for eyes in [[], [CGPoint(x: 600, y: 360)], [CGPoint(x: 600, y: 360), CGPoint(x: 600.5, y: 360)]] {
            let fix = try XCTUnwrap(LipMirrorCamera.fix(corners: corners, eyes: eyes, box: box))
            XCTAssertEqual(fix.scale, scale, accuracy: 1e-9)
            XCTAssertEqual(fix.center.x, 652.5, accuracy: 1e-9)
            XCTAssertEqual(fix.center.y, 500 + LipMirrorCamera.drop * scale, accuracy: 1e-9)
        }
        XCTAssertNil(LipMirrorCamera.fix(corners: corners, eyes: [], box: nil))
        XCTAssertNil(LipMirrorCamera.fix(corners: nil, eyes: [CGPoint(x: 589.5, y: 360),
                                                              CGPoint(x: 715.5, y: 360)], box: box))
    }

    /// Анфас масштаб — межглазное, бокс не участвует; при повороте головы
    /// межглазное сжимается, и масштаб держит бокс.
    func testScaleIgnoresBoxUnlessTurned() {
        let m = CGPoint(x: 640, y: 450)
        XCTAssertEqual(fix(m).scale, d, accuracy: 1e-9)
        let turned = fix(m, eyeScale: 0.6)
        XCTAssertEqual(turned.scale, LipMirrorCamera.kappa * boxSide, accuracy: 1e-9)
        // Сдвиг к подбородку — тоже от масштаба, а не от сжатого межглазного.
        XCTAssertEqual(turned.center.y, m.y + LipMirrorCamera.drop * LipMirrorCamera.kappa * boxSide,
                       accuracy: 1e-9)
    }

    /// Голова наклонена на 30°: сдвиг к подбородку идёт перпендикулярно оси
    /// глаз, а не вниз кадра.
    func testFixNormalFollowsEyeAxis() throws {
        let m = CGPoint(x: 640, y: 450)
        let angle = CGFloat.pi / 6
        let u = CGPoint(x: cos(angle), y: sin(angle))
        let n = CGPoint(x: -u.y, y: u.x)
        let mid = CGPoint(x: m.x - 1.1 * d * n.x, y: m.y - 1.1 * d * n.y)
        let eyes = [CGPoint(x: mid.x - u.x * d / 2, y: mid.y - u.y * d / 2),
                    CGPoint(x: mid.x + u.x * d / 2, y: mid.y + u.y * d / 2)]
        let corners = (left: CGPoint(x: m.x - 50 * u.x, y: m.y - 50 * u.y),
                       right: CGPoint(x: m.x + 50 * u.x, y: m.y + 50 * u.y))
        let f = try XCTUnwrap(LipMirrorCamera.fix(corners: corners, eyes: eyes, box: nil))
        XCTAssertEqual(f.scale, d, accuracy: 1e-9)
        XCTAssertEqual(f.center.x, m.x + n.x * LipMirrorCamera.drop * d, accuracy: 1e-9)
        XCTAssertEqual(f.center.y, m.y + n.y * LipMirrorCamera.drop * d, accuracy: 1e-9)
    }

    // MARK: - Покой и речь

    /// В покое окно — ровно `zoom` ширин рта.
    func testRegionMatchesCurrentFramingAtRest() {
        var rig = rig()
        let f = fix(CGPoint(x: 640, y: 450))
        let rect = rig.hold(f, seconds: 2)
        XCTAssertEqual(rect.width / mouthWidth, LipMirrorCamera.zoom, accuracy: LipMirrorCamera.zoom * 0.02)
        XCTAssertEqual(rect.height / rect.width, aspect, accuracy: 1e-9)
        XCTAssertEqual(rect.midX, f.center.x, accuracy: 0.5)
        XCTAssertEqual(rect.midY, f.center.y, accuracy: 0.5)
    }

    /// Речь (уголки опускаются и сходятся, рот раскрывается, 4 Гц) окно не
    /// двигает: разброс за 3 с меньше 0,5 % его ширины. Первая секунда речи
    /// не в счёт: в среднем уголки на речи ниже покоя на 0,02 межглазного, и
    /// окно плавно переезжает к этому среднему — это не дрожь.
    func testSpeechDoesNotMoveCamera() {
        var rig = rig()
        let m = CGPoint(x: 640, y: 450)
        let eyes = CGPoint(x: m.x, y: m.y - 1.1 * d)
        let rest = rig.hold(fix(m), seconds: 2)
        let start = rig.frames.count + 30
        for i in 0..<120 {
            let k = (1 - cos(2 * .pi * 4 * Double(i) / 30)) / 2
            let center = CGPoint(x: m.x, y: m.y + 0.04 * d * k)
            let width = mouthWidth * (1 - 0.05 * k)
            let lips = CGRect(x: center.x - width / 2, y: center.y - 0.12 * d,
                              width: width, height: (0.24 + 0.15 * k) * d)
            rig.step(fix(center, mouth: width, eyes: eyes), lips: lips)
        }
        let speech = rig.frames[start...]
        for spread in [speech.map(\.midX), speech.map(\.midY), speech.map(\.width)] {
            XCTAssertLessThan(spread.max()! - spread.min()!, 0.005 * rest.width)
        }
    }

    /// Голова едет 1 межглазное в секунду — окно идёт следом без рывков и
    /// отстаёт меньше чем на 0,3 межглазного.
    func testHeadMoveIsFollowedSmoothly() {
        var rig = rig()
        var m = CGPoint(x: 400, y: 450)
        rig.hold(fix(m), seconds: 2)
        let start = rig.frames.count - 1
        var last = fix(m)
        for _ in 0..<90 {
            m.x += d / 30
            last = fix(m)
            rig.step(last)
        }
        XCTAssertLessThanOrEqual(maxStep(rig.frames[start...]), maxStep)
        XCTAssertLessThan(abs(rig.frames.last!.midX - last.center.x), 0.3 * d)
    }

    /// Быстрый наклон головы (межглазное за 0,5 с, пик 3 межглазных в
    /// секунду) и ровное движение 2 и 3 межглазных в секунду: окно идёт
    /// следом, не встаёт на месте и не теряет рот. Ступенька цели — это
    /// скачок самой цели, а не отставание фильтра: иначе на таких скоростях
    /// окно перезапускало бы глайд каждые несколько кадров.
    func testFastHeadMoveKeepsMouthInWindow() {
        var rig = rig()
        let m0 = CGPoint(x: 400, y: 450)
        rig.hold(fix(m0), seconds: 2)
        for k in 1...15 {
            let x = Double(k) / 15
            let f = fix(CGPoint(x: m0.x + d * CGFloat(x * x * (3 - 2 * x)), y: m0.y))
            let r = rig.step(f)
            XCTAssertLessThan(abs(f.center.x - r.midX), 0.2 * r.width, "кадр \(k)")
        }

        for speed: CGFloat in [2, 3] {
            var moving = self.rig()
            var m = CGPoint(x: 300, y: 450)
            moving.hold(fix(m), seconds: 2)
            for k in 0..<60 {
                m.x += speed * d / 30
                let f = fix(m)
                let before = moving.frames.last!
                let r = moving.step(f)
                // Первые кадры разгона фильтр ещё набирает скорость.
                if k > 2 { XCTAssertGreaterThan(r.midX - before.midX, 0.5, "\(speed) d/с, кадр \(k)") }
                let lips = CGRect(x: m.x - mouthWidth / 2, y: m.y - 0.12 * d, width: mouthWidth, height: 0.24 * d)
                XCTAssertTrue(r.contains(lips), "\(speed) d/с, кадр \(k)")
            }
        }
    }

    // MARK: - Глайды

    /// Лицо пропало на 0,4 с, а вернулось на межглазное правее: камера не
    /// прыгает, а доезжает за глайд.
    func testReacquireAfterShortLossPansSmoothly() {
        var rig = rig()
        let m = CGPoint(x: 600, y: 450)
        rig.hold(fix(m), seconds: 2)
        let start = rig.frames.count - 1
        rig.hold(nil, seconds: 0.4)
        let moved = fix(CGPoint(x: m.x + d, y: m.y))
        rig.hold(moved, seconds: 0.4)
        XCTAssertLessThanOrEqual(maxStep(rig.frames[start...]), maxStep)
        let rect = rig.frames.last!
        XCTAssertEqual(rect.midX, moved.center.x, accuracy: 0.5)
        XCTAssertEqual(rect.midY, moved.center.y, accuracy: 0.5)
    }

    /// Крупнейшим стало другое лицо в трёх межглазных — цель прыгнула без
    /// пропуска кадров, а окно едет глайдом: старт без толчка, быстрее
    /// самого глайда нигде, у цели — не раньше чем через ~0,35 с.
    func testLargestFaceSwitchGlides() {
        var rig = rig()
        let m = CGPoint(x: 400, y: 450)
        rig.hold(fix(m), seconds: 2)
        let start = rig.frames.count - 1
        let other = fix(CGPoint(x: m.x + 3 * d, y: m.y))
        rig.hold(other, seconds: 0.5)
        let frames = rig.frames[start...]
        // Кадр смены лица — старт глайда, окно ещё на месте; первый
        // настоящий шаг smoothstep мал (у линейного глайда — 15 % ширины).
        XCTAssertEqual(step(frames[start], frames[start + 1]), 0, accuracy: 1e-12)
        XCTAssertLessThanOrEqual(step(frames[start + 1], frames[start + 2]), 0.05)
        // Фильтр сброшен на постоянную цель, ширина та же — центр идёт ровно
        // по smoothstep.
        for k in 0...11 {
            let x = min(Double(k) / (LipMirrorCamera.glide * 30), 1)
            XCTAssertEqual(frames[start + 1 + k].midX, m.x + 3 * d * CGFloat(x * x * (3 - 2 * x)), accuracy: 0.5)
        }
        // Пик smoothstep — 1,5 средней скорости глайда.
        let peak = 3 * d * 1.5 / CGFloat(LipMirrorCamera.glide * 30) / frames[start].width
        XCTAssertLessThanOrEqual(maxStep(frames), peak * 1.02)
        XCTAssertGreaterThan(abs(frames[start + 9].midX - other.center.x), 1)
        XCTAssertEqual(frames.last!.midX, other.center.x, accuracy: 0.5)
    }

    /// Лицо на том же месте стало в 1,4 раза крупнее (ступенька масштаба) —
    /// зум глайдом: у цели к концу глайда, первый шаг мал. One Euro за это
    /// время не доехал бы.
    func testZoomStepGlides() {
        var rig = rig()
        let f = fix(CGPoint(x: 640, y: 450))
        let rest = rig.hold(f, seconds: 2)
        let start = rig.frames.count - 1
        let closer = LipMirrorCamera.Fix(center: f.center, scale: f.scale * 1.4)
        rig.hold(closer, seconds: 0.5)
        let frames = rig.frames[start...]
        XCTAssertLessThanOrEqual(step(frames[start + 1], frames[start + 2]), maxStep)
        XCTAssertLessThan(frames[start + 9].width, rest.width * 1.4 - 1)
        XCTAssertEqual(frames[start + 12].width, rest.width * 1.4, accuracy: 0.01)
    }

    /// Старт: пока фиксов меньше трёх — сцена, дальше глайд к лицу за 0,35 с.
    func testEntryGlidesFromScene() {
        var rig = rig()
        let f = fix(CGPoint(x: 640, y: 450))
        assertRect(rig.step(f), scene, accuracy: 1e-6)
        assertRect(rig.step(f), scene, accuracy: 1e-6)
        assertRect(rig.step(f), scene, accuracy: 1e-6)   // третий фикс — глайд стартует со сцены
        var widths: [CGFloat] = []
        for _ in 0..<10 { widths.append(rig.step(f).width) }
        XCTAssertEqual(widths, widths.sorted(by: >))
        XCTAssertLessThan(widths[0], scene.width - 1)
        let expected = LipMirrorCamera.zoom * mouthWidth
        XCTAssertGreaterThan(widths[8], expected * 1.001)
        XCTAssertEqual(rig.step(f).width, expected, accuracy: 0.01)
    }

    /// На въезде рот (точка опоры) монотонно подходит к центру окна, а не
    /// уплывает в сторону и возвращается.
    func testEntryGlideMovesMouthMonotonicallyToCenter() {
        var rig = rig()
        let f = fix(CGPoint(x: 950, y: 520))
        var offsets: [CGFloat] = []
        for _ in 0..<16 {
            let r = rig.step(f)
            offsets.append(hypot(f.center.x - r.midX, f.center.y - r.midY) / r.width)
        }
        for (a, b) in zip(offsets, offsets.dropFirst()) { XCTAssertLessThanOrEqual(b, a + 1e-9) }
        XCTAssertGreaterThan(offsets.first!, 0.2)
        XCTAssertLessThan(offsets.last!, 1e-3)
    }

    /// Vision отдаёт лицо реже (4 к/с): въезд уже со второго фикса — после
    /// 0,1 с фиксов подряд, не дожидаясь трёх.
    func testSlowFixesEnterAfterReacquireTime() {
        var cam = LipMirrorCamera()
        let f = fix(CGPoint(x: 640, y: 450))
        _ = cam.update(f, lips: nil, at: 10, camera: camera, aspect: aspect)
        XCTAssertEqual(cam.mode, .scene)
        _ = cam.update(f, lips: nil, at: 10.25, camera: camera, aspect: aspect)
        XCTAssertEqual(cam.mode, .tracking)
    }

    /// Лицо мелькает на кадр раз в 0,6 с — камера остаётся на сцене.
    func testFlickeringFaceDoesNotPump() {
        var rig = rig()
        let f = fix(CGPoint(x: 640, y: 450))
        for _ in 0..<5 {
            rig.step(f)
            rig.hold(nil, seconds: 0.6)
        }
        for rect in rig.frames { assertRect(rect, scene, accuracy: 1e-6) }
    }

    // MARK: - Потеря лица

    /// Потеря короче 0,5 с — окно стоит.
    func testShortLossHoldsCamera() {
        var rig = rig()
        let rest = rig.hold(fix(CGPoint(x: 640, y: 450)), seconds: 2)
        let start = rig.frames.count
        rig.hold(nil, seconds: 0.45)
        for rect in rig.frames[start...] { assertRect(rect, rest, accuracy: 0.005 * rest.width) }
    }

    /// Голова ехала 1 межглазное в секунду и пропала на 0,4 с: фильтр
    /// дотягивает окно до последней цели, а не замирает на кадре потери.
    func testShortLossWhileMovingCoastsToLastTarget() {
        var rig = rig()
        var m = CGPoint(x: 400, y: 450)
        rig.hold(fix(m), seconds: 2)
        var last = fix(m)
        for _ in 0..<60 {
            m.x += d / 30
            last = fix(m)
            rig.step(last)
        }
        let before = rig.frames[rig.frames.count - 2], moving = rig.frames.last!
        let first = rig.step(nil)
        XCTAssertGreaterThan(first.midX - moving.midX, 0.5 * (moving.midX - before.midX))
        let end = rig.hold(nil, seconds: 0.4 - dt)
        XCTAssertEqual(end.midX, last.center.x, accuracy: 0.05 * d)
    }

    /// Потеря дольше 0,5 с — глайд на сцену, к 0,9 с — сцена.
    func testLongLossGlidesToScene() {
        var rig = rig()
        let rest = rig.hold(fix(CGPoint(x: 800, y: 450)), seconds: 2)
        let start = rig.frames.count
        rig.hold(nil, seconds: 1)
        let loss = rig.frames[start...]
        assertRect(loss[start + 13], rest, accuracy: 1e-6)   // 0,47 с — ещё удержание
        let mid = loss[start + 20]
        XCTAssertGreaterThan(mid.width, rest.width + 1)
        XCTAssertLessThan(mid.width, scene.width - 1)
        assertRect(loss[start + 26], scene, accuracy: 1e-6)   // 0,9 с
        XCTAssertEqual(rig.camera.mode, .scene)
        // Якорь выезда — рот: он ровно переходит на своё место в сцене, а не
        // качается туда-обратно.
        let f = fix(CGPoint(x: 800, y: 450))
        let xs = loss.map { onScreen(f.center, $0).x }
        for (a, b) in zip(xs, xs.dropFirst()) { XCTAssertGreaterThanOrEqual(b, a - 1e-9) }
        XCTAssertEqual(xs.last!, (f.center.x - scene.minX) / scene.width, accuracy: 1e-9)
    }

    /// Лицо вернулось посреди выезда: окно не дёргается — рот на экране
    /// ползёт плавно, а зум нигде не быстрее цельного выезда.
    func testReturnDuringExitGlideDoesNotJump() {
        var rig = rig()
        let f = fix(CGPoint(x: 900, y: 470))
        rig.hold(f, seconds: 2)
        let start = rig.frames.count - 1
        rig.hold(nil, seconds: 0.6)                 // выезд начался на 0,5 с
        let returned = rig.frames.count - 1
        rig.hold(f, seconds: 0.8)
        let frames = rig.frames[start...]
        for (a, b) in zip(frames, frames.dropFirst()) {
            let pa = onScreen(f.center, a), pb = onScreen(f.center, b)
            XCTAssertLessThanOrEqual(hypot(pb.x - pa.x, pb.y - pa.y), maxStep)
        }
        // Пик smoothstep цельного выезда — 1,5 средней скорости зума.
        let exitPeak = log(scene.width / frames[start].width) * 1.5 / CGFloat(LipMirrorCamera.glide * 30)
        let zoom = zip(frames, frames.dropFirst()).map { abs(log($1.width / $0.width)) }.max()!
        XCTAssertLessThanOrEqual(zoom, exitPeak * 1.02)
        XCTAssertGreaterThan(rig.frames[returned].width, frames[start].width + 1)
        assertRect(rig.frames.last!, frames[start], accuracy: 0.5)
    }

    /// Reduce Motion: въезд и выезд за один кадр, без промежуточных.
    func testReduceMotionJumpsInstantly() {
        var rig = rig(reduceMotion: true)
        let f = fix(CGPoint(x: 640, y: 450))
        assertRect(rig.step(f), scene, accuracy: 1e-6)
        assertRect(rig.step(f), scene, accuracy: 1e-6)
        let tracked = rig.step(f)
        XCTAssertEqual(tracked.width, LipMirrorCamera.zoom * mouthWidth, accuracy: 0.01)
        XCTAssertEqual(tracked.midX, f.center.x, accuracy: 0.01)
        let start = rig.frames.count
        rig.hold(nil, seconds: 0.6)
        assertRect(rig.frames[start + 12], tracked, accuracy: 1e-6)
        assertRect(rig.frames.last!, scene, accuracy: 1e-6)
        // Каждый кадр — либо окно лица, либо сцена.
        for rect in rig.frames[start...] {
            XCTAssertTrue(abs(rect.width - tracked.width) < 1e-6 || abs(rect.width - scene.width) < 1e-6)
        }
    }

    // MARK: - Рот в окне

    /// Широко открытый рот (бокс губ в межглазное высотой) окно раздвигает:
    /// край губ не дальше 0,45 высоты окна от центра.
    func testWideOpenMouthStaysInFrame() {
        var rig = rig()
        let m = CGPoint(x: 640, y: 450)
        rig.hold(fix(m), seconds: 2)
        let lips = CGRect(x: m.x - mouthWidth / 2, y: m.y - 0.35 * d, width: mouthWidth, height: d)
        let rect = rig.hold(fix(m), seconds: 8, lips: lips)
        let edge = max(abs(lips.minY - rect.midY), abs(lips.maxY - rect.midY))
        XCTAssertLessThanOrEqual(edge, LipMirrorCamera.guardEdge * rect.height * 1.001)
        XCTAssertGreaterThan(rect.width, LipMirrorCamera.zoom * mouthWidth * 1.01)
    }

    /// Голова повёрнута (межглазное 0,6), рот открыт на 0,72 межглазного —
    /// окно держит бокс (не предохранитель) и рот целиком в кадре. По
    /// сжатому межглазному рот в окно не влез бы.
    func testTurnedHeadKeepsOpenMouthInFrame() {
        var rig = rig()
        let m = CGPoint(x: 640, y: 450)
        let width = 0.64 * d
        let lips = CGRect(x: m.x - width / 2, y: m.y - 0.25 * d, width: width, height: 0.72 * d)
        let rect = rig.hold(fix(m, eyeScale: 0.6, mouth: width), seconds: 4, lips: lips)
        XCTAssertEqual(rect.width,
                       LipMirrorCamera.zoom * LipMirrorCamera.mouthPerEyes * LipMirrorCamera.kappa * boxSide,
                       accuracy: 0.01 * rect.width)
        XCTAssertTrue(rect.contains(lips))
    }

    /// Рот растянут шире окна (улыбка) — предохранитель раздвигает его и по
    /// горизонтали.
    func testWideMouthWidensWindowHorizontally() {
        let f = LipMirrorCamera.Fix(center: CGPoint(x: 640, y: 450), scale: d)
        let lips = CGRect(x: 640 - 1.2 * d, y: 440, width: 2.4 * d, height: 0.2 * d)
        XCTAssertEqual(LipMirrorCamera.windowWidth(for: f, lips: lips, aspect: aspect),
                       1.2 * d / LipMirrorCamera.guardEdge, accuracy: 1e-9)
        XCTAssertEqual(LipMirrorCamera.windowWidth(for: f, lips: nil, aspect: aspect),
                       LipMirrorCamera.zoom * LipMirrorCamera.mouthPerEyes * d, accuracy: 1e-9)
    }

    /// Лицо у края кадра: окно прижимается к краю, но из кадра не выходит;
    /// сцена тоже в кадре при любом аспекте.
    func testRegionStaysInsideCameraFrame() {
        let frame = CGRect(origin: .zero, size: camera)
        for m in [CGPoint(x: 20, y: 700), CGPoint(x: 1270, y: 15)] {
            var rig = rig()
            rig.hold(fix(m), seconds: 2)
            for rect in rig.frames {
                XCTAssertTrue(frame.insetBy(dx: -1e-6, dy: -1e-6).contains(rect), "\(rect)")
            }
        }
        for a: CGFloat in [aspect, 1, 2, 0.3] {
            let region = LipMirrorGeometry.sceneRegion(camera: camera, aspect: a)
            XCTAssertTrue(frame.insetBy(dx: -1e-6, dy: -1e-6).contains(region))
        }
    }

    // MARK: - Маска

    private func mesh(_ x: CGFloat) -> LipMesh {
        LipMesh(outer: [CGPoint(x: x, y: 0)], inner: [CGPoint(x: x, y: 1)], keypoints: [])
    }

    /// Одиночный промах Vision маску не гасит.
    func testMaskHoldsThroughSingleMiss() {
        var hold = LipMaskHold()
        XCTAssertEqual(hold.update(mesh(1), at: 10), mesh(1))
        XCTAssertEqual(hold.update(nil, at: 10 + dt), mesh(1))
        XCTAssertEqual(hold.update(nil, at: 10.14), mesh(1))
        XCTAssertEqual(hold.update(mesh(2), at: 10.2), mesh(2))
    }

    /// Дольше удержания — маски нет, и прошлая не всплывает.
    func testMaskHiddenAfterHold() {
        var hold = LipMaskHold()
        _ = hold.update(mesh(1), at: 10)
        XCTAssertNil(hold.update(nil, at: 10.2))
        XCTAssertNil(hold.update(nil, at: 10.21))
        _ = hold.update(mesh(2), at: 11)
        hold.reset()
        XCTAssertNil(hold.update(nil, at: 11.01))
    }
}
