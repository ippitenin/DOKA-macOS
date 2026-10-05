import CoreGraphics
import XCTest
@testable import DOKA

/// Маска-сетка губ в зеркале: из десятка точек Vision — кольца постоянного
/// размера, сплайн вместо ломаной, сетка между внешним и внутренним контуром.
///
/// Зачем: узлы сетки должны соответствовать друг другу между кадрами Vision
/// (их сглаживают по одному) — поэтому число узлов не должно зависеть от
/// того, сколько точек отдал Vision. У известных созвездий уголки берутся по
/// таблице индексов и не перескакивают; всё остальное (эллипсы с произвольной
/// фазой обхода ниже) идёт запасным путём — уголки и верх/низ по координатам,
/// и порядок обхода там не важен. Узлы стоят по параметру индекса точек:
/// сдвиг одной точки двигает только соседние узлы.
final class LipMeshGeometryTests: XCTestCase {

    private var ringSize: Int { 2 * LipMesh.samplesPerLip }

    /// Эллипс губ в координатах кадра (сверху слева), обход по часовой
    /// стрелке на экране, начиная с произвольной фазы — как у Vision.
    private func ellipse(center: CGPoint = CGPoint(x: 640, y: 480), rx: CGFloat, ry: CGFloat,
                         count: Int, phase: CGFloat = 0.3, reversed: Bool = false) -> [CGPoint] {
        let points = (0..<count).map { i -> CGPoint in
            let a = phase + 2 * .pi * CGFloat(i) / CGFloat(count)
            return CGPoint(x: center.x + rx * cos(a), y: center.y + ry * sin(a))
        }
        return reversed ? points.reversed() : points
    }

    /// Губы в порядке Vision rev3/76: внешний контур — 14 точек, 13 — левый
    /// уголок, 0…6 — верх слева направо, 7 — правый уголок, 8…12 — низ справа
    /// налево; внутренний — 6 точек без уголков, 0…2 — верх слева направо,
    /// 3…5 — низ справа налево. `upper`/`lower` — точек между уголками (5 и 3 —
    /// созвездие 65: уголки 9 и 5). `spacing` раскладывает точки верхней губы по
    /// ширине (тождество — равномерно); отрицательный `gap` перекрещивает
    /// внутренний контур.
    private func visionLips(center: CGPoint = CGPoint(x: 640, y: 480), halfWidth w: CGFloat = 60,
                            gap: CGFloat = 8, upper: Int = 7, lower: Int = 5,
                            spacing: (CGFloat) -> CGFloat = { $0 })
        -> (outer: [CGPoint], inner: [CGPoint]) {
        func at(_ t: CGFloat, _ lift: CGFloat) -> CGPoint {
            CGPoint(x: center.x - w + 2 * w * t, y: center.y - lift * sin(.pi * t))
        }
        var outer = (0..<upper).map { at(spacing(CGFloat($0 + 1) / CGFloat(upper + 1)), 24) }
        outer.append(CGPoint(x: center.x + w, y: center.y))
        outer += (0..<lower).map { at(1 - CGFloat($0 + 1) / CGFloat(lower + 1), -26) }
        outer.append(CGPoint(x: center.x - w, y: center.y))
        let inner = [0.3, 0.5, 0.7].map { at($0, gap / 2) } + [0.7, 0.5, 0.3].map { at($0, -gap / 2) }
        return (outer, inner)
    }

    /// Кольцо в порядке MediaPipe: [0] — левый уголок, [1…9] — верх слева
    /// направо, [10] — правый уголок, [11…19] — низ справа налево.
    private func mediaPipeRing(rx: CGFloat, ry: CGFloat, center: CGPoint = CGPoint(x: 640, y: 480)) -> [CGPoint] {
        (0..<20).map { j in
            let a = CGFloat.pi + .pi * CGFloat(j) / 10
            return CGPoint(x: center.x + rx * cos(a), y: center.y + ry * sin(a))
        }
    }

    /// Точки, растянутые по вертикали в `scaleY` раз и повёрнутые на `angle`
    /// вокруг `center` — наклон головы.
    private func tilted(_ points: [CGPoint], angle: CGFloat, scaleY: CGFloat = 1,
                        center: CGPoint = CGPoint(x: 640, y: 480)) -> [CGPoint] {
        let c = cos(angle), s = sin(angle)
        return points.map { p in
            let x = p.x - center.x, y = (p.y - center.y) * scaleY
            return CGPoint(x: center.x + x * c - y * s, y: center.y + x * s + y * c)
        }
    }

    private func maxDistance(_ a: [CGPoint], _ b: [CGPoint]) -> CGFloat {
        zip(a, b).map { hypot($0.x - $1.x, $0.y - $1.y) }.max() ?? 0
    }

    private func meanY(_ points: ArraySlice<CGPoint>) -> CGFloat {
        points.reduce(0) { $0 + $1.y } / CGFloat(points.count)
    }

    // MARK: - Форма

    /// Сколько бы точек ни отдал Vision, колец и узлов всегда одинаково.
    func testRingSizeIsFixedForAnyInputCount() throws {
        for count in [6, 10, 14, 20] {
            let mesh = try XCTUnwrap(LipMesh.make(outer: ellipse(rx: 60, ry: 24, count: count),
                                                  inner: ellipse(rx: 40, ry: 8, count: max(6, count - 4))))
            XCTAssertEqual(mesh.outer.count, ringSize)
            XCTAssertEqual(mesh.inner.count, ringSize)
            XCTAssertEqual(mesh.halo.count, ringSize)
            XCTAssertEqual(mesh.bands.count, LipMesh.bandFractions.count)
            for band in mesh.bands { XCTAssertEqual(band.count, ringSize) }
        }
    }

    /// Кольцо начинается в левом уголке, а через K узлов приходит в правый —
    /// и уголки совпадают с исходными точками, сплайн их не сдвигает.
    func testRingStartsAtLeftCornerAndPassesRightCorner() throws {
        let outer = ellipse(rx: 60, ry: 24, count: 14)
        let mesh = try XCTUnwrap(LipMesh.make(outer: outer, inner: ellipse(rx: 40, ry: 8, count: 10)))
        let left = try XCTUnwrap(outer.min { $0.x < $1.x })
        let right = try XCTUnwrap(outer.max { $0.x < $1.x })
        XCTAssertEqual(mesh.outer[0], left)
        XCTAssertEqual(mesh.outer[LipMesh.samplesPerLip], right)
    }

    /// Первая половина кольца — верхняя губа (меньший y), вторая — нижняя.
    func testUpperHalfIsAboveLowerHalf() throws {
        let mesh = try XCTUnwrap(LipMesh.make(outer: ellipse(rx: 60, ry: 24, count: 14),
                                              inner: ellipse(rx: 40, ry: 8, count: 10)))
        let k = LipMesh.samplesPerLip
        XCTAssertLessThan(meanY(mesh.outer[1..<k]), meanY(mesh.outer[(k + 1)...]))
        XCTAssertLessThan(meanY(mesh.inner[1..<k]), meanY(mesh.inner[(k + 1)...]))
    }

    /// Обход в обратную сторону и другой стартовый индекс дают ту же сетку.
    func testTraversalOrderDoesNotMatter() throws {
        let a = try XCTUnwrap(LipMesh.make(outer: ellipse(rx: 60, ry: 24, count: 14),
                                           inner: ellipse(rx: 40, ry: 8, count: 10)))
        let b = try XCTUnwrap(LipMesh.make(outer: ellipse(rx: 60, ry: 24, count: 14, reversed: true),
                                           inner: ellipse(rx: 40, ry: 8, count: 10, reversed: true)))
        for (p, q) in zip(a.outer + a.inner, b.outer + b.inner) {
            XCTAssertEqual(p.x, q.x, accuracy: 1e-6)
            XCTAssertEqual(p.y, q.y, accuracy: 1e-6)
        }
    }

    /// Промежуточные кольца лежат между внешним и внутренним, по порядку.
    func testBandsLieBetweenOuterAndInner() throws {
        let mesh = try XCTUnwrap(LipMesh.make(outer: ellipse(rx: 60, ry: 24, count: 14),
                                              inner: ellipse(rx: 40, ry: 8, count: 10)))
        let top = LipMesh.samplesPerLip / 2   // середина верхней губы
        var previous = mesh.outer[top].y
        for band in mesh.bands {
            XCTAssertGreaterThan(band[top].y, previous)
            previous = band[top].y
        }
        XCTAssertGreaterThan(mesh.inner[top].y, previous)
    }

    /// Ореол снаружи внешнего контура.
    func testHaloIsOutsideOuter() throws {
        let center = CGPoint(x: 640, y: 480)
        let mesh = try XCTUnwrap(LipMesh.make(outer: ellipse(center: center, rx: 60, ry: 24, count: 14),
                                              inner: ellipse(center: center, rx: 40, ry: 8, count: 10)))
        for (h, o) in zip(mesh.halo, mesh.outer) {
            XCTAssertGreaterThan(hypot(h.x - center.x, h.y - center.y), hypot(o.x - center.x, o.y - center.y))
        }
        XCTAssertTrue(mesh.bounds.contains(mesh.outer[0]))
    }

    /// Закрытый рот: внутренний контур — плоская линия, верх и низ совпадают.
    /// Сетка обязана остаться конечной, без NaN.
    func testClosedMouthStaysFinite() throws {
        let inner = [CGPoint(x: 600, y: 480), CGPoint(x: 620, y: 480), CGPoint(x: 660, y: 480),
                     CGPoint(x: 680, y: 480), CGPoint(x: 660, y: 480), CGPoint(x: 620, y: 480)]
        let mesh = try XCTUnwrap(LipMesh.make(outer: ellipse(rx: 60, ry: 24, count: 14), inner: inner))
        for p in mesh.outer + mesh.inner + mesh.halo + mesh.bands.flatMap({ $0 }) {
            XCTAssertTrue(p.x.isFinite && p.y.isFinite)
        }
        for p in mesh.inner { XCTAssertEqual(p.y, 480, accuracy: 1e-6) }
    }

    /// Повторяющиеся соседние точки (Vision иногда склеивает уголки) не ломают сплайн.
    func testDuplicatePointsStayFinite() throws {
        var outer = ellipse(rx: 60, ry: 24, count: 14)
        outer.insert(outer[3], at: 3)
        let mesh = try XCTUnwrap(LipMesh.make(outer: outer, inner: ellipse(rx: 40, ry: 8, count: 10)))
        for p in mesh.outer { XCTAssertTrue(p.x.isFinite && p.y.isFinite) }
    }

    /// Меньше трёх точек или все точки на одной вертикали — сетки нет.
    func testDegenerateInputGivesNil() {
        let inner = ellipse(rx: 40, ry: 8, count: 10)
        XCTAssertNil(LipMesh.make(outer: [], inner: inner))
        XCTAssertNil(LipMesh.make(outer: [CGPoint(x: 1, y: 1), CGPoint(x: 5, y: 1)], inner: inner))
        XCTAssertNil(LipMesh.make(outer: [CGPoint(x: 1, y: 1), CGPoint(x: 1, y: 5), CGPoint(x: 1, y: 9)],
                                  inner: inner))
        XCTAssertNil(LipMesh.make(outer: ellipse(rx: 60, ry: 24, count: 14), inner: []))
    }

    /// Ключевые точки — точки источника как пришли: внешний, затем внутренний контур.
    func testKeypointsAreRawVisionPoints() throws {
        let outer = ellipse(rx: 60, ry: 24, count: 14)
        let inner = ellipse(rx: 40, ry: 8, count: 10)
        let mesh = try XCTUnwrap(LipMesh.make(outer: outer, inner: inner))
        XCTAssertEqual(mesh.keypoints, outer + inner)
    }

    // MARK: - Таблица Vision

    /// Созвездие 76: цепочки собираются по номерам точек, а внутренний контур
    /// проводится через внешние уголки.
    func testVisionTableBuildsChainsFromCornerIndices() throws {
        let (o, i) = visionLips()
        let contours = try XCTUnwrap(LipContours.vision(outer: o, inner: i))
        XCTAssertEqual(contours.outer.upper, [o[13]] + o[0...6] + [o[7]])
        XCTAssertEqual(contours.outer.lower, [o[13], o[12], o[11], o[10], o[9], o[8], o[7]])
        XCTAssertEqual(contours.inner.upper, [o[13], i[0], i[1], i[2], o[7]])
        XCTAssertEqual(contours.inner.lower, [o[13], i[5], i[4], i[3], o[7]])
        XCTAssertTrue(contours.bands.isEmpty)
        XCTAssertEqual(contours.keypoints, o + i)
    }

    /// Созвездие 65 (10 + 6): уголки 9 и 5, верх 0…4, низ 8, 7, 6.
    func testVisionTableReadsConstellation65() throws {
        let (o, i) = visionLips(upper: 5, lower: 3)
        XCTAssertEqual(o.count, 10)
        let contours = try XCTUnwrap(LipContours.vision(outer: o, inner: i))
        XCTAssertEqual(contours.outer.upper, [o[9]] + o[0...4] + [o[5]])
        XCTAssertEqual(contours.outer.lower, [o[9], o[8], o[7], o[6], o[5]])
        XCTAssertEqual(contours.inner.upper, [o[9], i[0], i[1], i[2], o[5]])
        XCTAssertEqual(contours.inner.lower, [o[9], i[5], i[4], i[3], o[5]])
        // Таблица собирает цепочки, считая левый уголок последней точкой обхода.
        for (count, corners) in LipContours.visionCorners {
            XCTAssertEqual(corners.left, count - 1)
        }
    }

    /// Ось глаз задом наперёд (например, глаза в порядке Vision) даёт те же
    /// контуры: без разворота таблица молча отключилась бы, а верх и низ поменялись.
    func testAxisSignDoesNotMatter() throws {
        let (o, i) = visionLips()
        let reference = try XCTUnwrap(LipContours.vision(outer: o, inner: i))
        XCTAssertEqual(LipContours.vision(outer: o, inner: i, axis: CGVector(dx: -1, dy: 0)), reference)
        XCTAssertEqual(reference.outer.corners?.left, o[13])
        XCTAssertEqual(reference.outer.corners?.right, o[7])
        let angle = 20 * CGFloat.pi / 180
        let (to, ti) = (tilted(o, angle: angle), tilted(i, angle: angle))
        XCTAssertEqual(LipContours.vision(outer: to, inner: ti, axis: CGVector(dx: -cos(angle), dy: -sin(angle))),
                       LipContours.vision(outer: to, inner: ti, axis: CGVector(dx: cos(angle), dy: sin(angle))))
    }

    /// Внутреннее кольцо начинается и кончается во внешних уголках: у Vision
    /// внутренний контур — только центр рта, без уголков.
    func testInnerContourRunsThroughOuterCorners() throws {
        let (o, i) = visionLips()
        let mesh = try XCTUnwrap(LipMesh.make(outer: o, inner: i))
        XCTAssertEqual(mesh.inner[0], o[13])
        XCTAssertEqual(mesh.inner[LipMesh.samplesPerLip], o[7])
        XCTAssertEqual(mesh.outer[0], o[13])
        XCTAssertEqual(mesh.outer[LipMesh.samplesPerLip], o[7])
    }

    /// 14 + 6 точек, но табличные уголки не крайние (эллипс с другой фазой
    /// обхода) — таблица неправдоподобна, уголки берутся по геометрии.
    func testVisionTableFallsBackWhenCornersAreNotExtreme() throws {
        let outer = ellipse(rx: 60, ry: 24, count: 14)
        let inner = ellipse(rx: 40, ry: 8, count: 6)
        let contours = try XCTUnwrap(LipContours.vision(outer: outer, inner: inner))
        let left = try XCTUnwrap(outer.min { $0.x < $1.x })
        let innerLeft = try XCTUnwrap(inner.min { $0.x < $1.x })
        XCTAssertEqual(contours.outer.upper.first, left)
        XCTAssertNotEqual(left, outer[13])
        XCTAssertEqual(contours.inner.upper.first, innerLeft)
        let mesh = try XCTUnwrap(LipMesh.make(contours))
        XCTAssertEqual(mesh.outer[0], left)
    }

    /// Кадр вверх ногами: уголки крайние, но верх по таблице ниже низа —
    /// таблица отвергнута, верх берётся по геометрии, открытый рот не схлопнут.
    func testVisionTableFallsBackWhenUpperIsBelowLower() throws {
        let (o, i) = visionLips()
        let flip = { (p: CGPoint) in CGPoint(x: p.x, y: 960 - p.y) }
        let fo = o.map(flip), fi = i.map(flip)
        let contours = try XCTUnwrap(LipContours.vision(outer: fo, inner: fi))
        XCTAssertNotEqual(contours.inner.upper.first, fo[13])
        XCTAssertEqual(contours.outer.upper, [fo[13], fo[12], fo[11], fo[10], fo[9], fo[8], fo[7]])
        let mesh = try XCTUnwrap(LipMesh.make(contours))
        let k = LipMesh.samplesPerLip
        XCTAssertLessThan(mesh.inner[k / 2].y, mesh.inner[2 * k - k / 2].y)
    }

    /// Порог правдоподобия — 10 % ширины рта: левый уголок отстаёт от крайней
    /// точки на 8 % — таблица, на 11 % — запасной путь. Правый уголок при этом крайний.
    func testVisionTableCornerSlackIsTenPercent() throws {
        XCTAssertEqual(LipContours.cornerSlack, 0.1)
        let (o, i) = visionLips()
        // Ширина 120 px; точка 0 уходит левее уголка 13 на d — ширина 120 + d.
        for (d, table) in [(CGFloat(10), true), (CGFloat(15), false)] {
            var shifted = o
            shifted[0].x = o[13].x - d
            let contours = try XCTUnwrap(LipContours.vision(outer: shifted, inner: i))
            XCTAssertEqual(contours.inner.upper.first == o[13], table, "отставание \(d) px")
        }
        var right = o
        right[6].x = o[7].x + 15
        XCTAssertNotEqual(try XCTUnwrap(LipContours.vision(outer: right, inner: i)).inner.upper.first, o[13])
    }

    /// Голова наклонена на 55°, рот раскрыт: по оси глаз таблица правдоподобна,
    /// без оси уголки 13 и 7 по x уже не крайние — запасной путь.
    func testVisionTableUsesEyeAxis() throws {
        let angle = 55 * CGFloat.pi / 180
        let (o, i) = visionLips()
        let to = tilted(o, angle: angle, scaleY: 2.5), ti = tilted(i, angle: angle, scaleY: 2.5)
        let withAxis = try XCTUnwrap(LipContours.vision(outer: to, inner: ti,
                                                        axis: CGVector(dx: cos(angle), dy: sin(angle))))
        XCTAssertEqual(withAxis.outer.upper, [to[13]] + to[0...6] + [to[7]])
        XCTAssertEqual(withAxis.inner.upper.first, to[13])
        let withoutAxis = try XCTUnwrap(LipContours.vision(outer: to, inner: ti))
        XCTAssertNotEqual(withoutAxis.inner.upper.first, to[13])
    }

    /// Рот наклонён на 25° вместе с осью глаз: уголки — крайние точки вдоль
    /// оси, хотя по x крайними были бы другие точки.
    func testFallbackCornersFollowEyeAxis() throws {
        let angle = 25 * CGFloat.pi / 180
        let c = cos(angle), s = sin(angle), center = CGPoint(x: 640, y: 480)
        func tilted(rx: CGFloat, ry: CGFloat, count: Int) -> [CGPoint] {
            (0..<count).map { i in
                let a = 2 * CGFloat.pi * CGFloat(i) / CGFloat(count)
                let x = rx * cos(a), y = ry * sin(a)
                return CGPoint(x: center.x + x * c - y * s, y: center.y + x * s + y * c)
            }
        }
        let outer = tilted(rx: 60, ry: 40, count: 14)
        let inner = tilted(rx: 40, ry: 10, count: 10)
        // Точка 7 — конец большой оси слева, но по x левее точка 6.
        XCTAssertLessThan(outer[6].x, outer[7].x)
        let contours = try XCTUnwrap(LipContours.vision(outer: outer, inner: inner,
                                                        axis: CGVector(dx: c, dy: s)))
        XCTAssertEqual(contours.outer.upper.first, outer[7])
        XCTAssertEqual(contours.outer.upper.last, outer[0])
        // Верх — со стороны, противоположной подбородку (локальный y < 0).
        XCTAssertEqual(contours.outer.upper, Array(outer[7...13]) + [outer[0]])
        XCTAssertEqual(contours.inner.upper.first, inner[5])
        XCTAssertEqual(contours.inner.upper.last, inner[0])
    }

    /// Запасной путь: верх — по проекции на нормаль к оси глаз, а не по y экрана.
    /// Точки верхней губы сбиты к правому уголку, нижней — к левому; при наклоне
    /// 25° средний y верхней цепочки на экране БОЛЬШЕ, чем у нижней.
    func testFallbackUpperFollowsNormalNotScreenY() throws {
        let angle = 25 * CGFloat.pi / 180
        let center = CGPoint(x: 640, y: 480)
        // 11 точек (таблицы для них нет): левый уголок, верх слева направо,
        // правый уголок, низ справа налево — до поворота.
        let upright = [CGPoint(x: center.x - 60, y: center.y)]
            + [10, 20, 30, 40, 50].map { CGPoint(x: center.x + $0, y: center.y - 12) }
            + [CGPoint(x: center.x + 60, y: center.y)]
            + [-20, -30, -40, -50].map { CGPoint(x: center.x + $0, y: center.y + 12) }
        let outer = tilted(upright, angle: angle)
        let inner = tilted(ellipse(rx: 40, ry: 10, count: 10, phase: 0), angle: angle)
        let contours = try XCTUnwrap(LipContours.vision(outer: outer, inner: inner,
                                                        axis: CGVector(dx: cos(angle), dy: sin(angle))))
        XCTAssertEqual(contours.outer.upper, Array(outer[0...6]))
        XCTAssertGreaterThan(meanY(contours.outer.upper[...]), meanY(contours.outer.lower[...]))
    }

    /// Уголок — точка 13 по таблице, даже когда соседняя точка вышла чуть
    /// левее него: правило «крайняя по x» перескочило бы на неё, и все узлы
    /// перестроились бы. Здесь сдвиг точки на 1 px сдвигает узлы меньше чем на 1 px.
    func testStickyCornersSurviveWhenAnotherPointBecomesExtreme() throws {
        var (o, i) = visionLips()
        o[0].x = o[13].x + 0.5
        let before = try XCTUnwrap(LipMesh.make(outer: o, inner: i))
        o[0].x = o[13].x - 0.5
        XCTAssertEqual(o.min { $0.x < $1.x }, o[0])
        let after = try XCTUnwrap(LipMesh.make(outer: o, inner: i))
        XCTAssertEqual(before.outer[0], o[13])
        XCTAssertEqual(after.outer[0], o[13])
        XCTAssertEqual(after.inner[0], o[13])
        XCTAssertLessThan(maxDistance(before.outer + before.inner, after.outer + after.inner), 1)
    }

    // MARK: - Выборка по индексу

    /// При целом параметре узел — ровно точка источника, сплайн её не сдвигает.
    func testIndexSamplingHitsSourcePointsAtIntegerParameters() throws {
        let (o, i) = visionLips(spacing: { $0 * $0 })
        let contours = try XCTUnwrap(LipContours.vision(outer: o, inner: i))
        for chain in contours.chains {
            for (index, p) in chain.enumerated() {
                XCTAssertEqual(LipMesh.point(on: chain, at: CGFloat(index)), p)
            }
        }
        // Верх — 9 точек: узел k при u = 8k/12, целые u — у k = 0, 3, 6, 9, 12.
        let mesh = try XCTUnwrap(LipMesh.make(contours))
        XCTAssertEqual([0, 3, 6, 9, 12].map { mesh.outer[$0] }, [o[13], o[1], o[3], o[5], o[7]])
        // Низ — 7 точек: u = k/2, узел k нижней губы лежит в кольце на месте 2K − k.
        let k = LipMesh.samplesPerLip
        XCTAssertEqual([2, 4, 6, 8, 10].map { mesh.outer[2 * k - $0] }, [o[12], o[11], o[10], o[9], o[8]])
    }

    /// Между целыми параметрами — тот же центростремительный сплайн, что у
    /// `spline`, а не ломаная. Нечисловой параметр не роняет приложение.
    func testIndexSamplingFollowsSplineBetweenPoints() {
        let chain = [CGPoint(x: 0, y: 0), CGPoint(x: 5, y: 9), CGPoint(x: 30, y: 12),
                     CGPoint(x: 34, y: 2), CGPoint(x: 80, y: -6)]
        let steps = 8
        let curve = LipMesh.spline(chain, steps: steps)
        for i in 0..<(chain.count - 1) {
            for s in 0..<steps {
                let p = LipMesh.point(on: chain, at: CGFloat(i) + CGFloat(s) / CGFloat(steps))
                XCTAssertEqual(p.x, curve[i * steps + s].x, accuracy: 1e-9)
                XCTAssertEqual(p.y, curve[i * steps + s].y, accuracy: 1e-9)
            }
        }
        XCTAssertEqual(LipMesh.point(on: chain, at: .nan), chain[0])
    }

    /// Сдвиг одной точки источника трогает только узлы в двух отрезках от неё:
    /// у сплайна Катмулла–Рома опоры локальные.
    func testNodesMoveOnlyNearChangedSourcePoint() throws {
        var (o, i) = visionLips()
        let before = try XCTUnwrap(LipMesh.make(outer: o, inner: i))
        o[3].y -= 3   // в верхней цепочке [13, 0…6, 7] это позиция 4
        let after = try XCTUnwrap(LipMesh.make(outer: o, inner: i))
        let k = LipMesh.samplesPerLip
        var moved = 0
        for j in 0...k {
            let u = CGFloat(j) * 8 / CGFloat(k)
            if abs(u - 4) >= 2 {
                XCTAssertEqual(after.outer[j], before.outer[j], "узел \(j)")
            } else if after.outer[j] != before.outer[j] {
                moved += 1
            }
        }
        XCTAssertGreaterThan(moved, 0)
        XCTAssertEqual(Array(after.outer[(k + 1)...]), Array(before.outer[(k + 1)...]))
        XCTAssertEqual(after.inner, before.inner)
    }

    // MARK: - Калибровка

    /// Точки верхней губы сбиты к левому уголку: по индексу узлы сбились бы
    /// туда же, а калибровка по средним долям дуги раскладывает их ровно.
    func testCalibrationEvensNodesOnUnevenChain() throws {
        let (o, i) = visionLips(spacing: { $0 * $0 })
        let contours = try XCTUnwrap(LipContours.vision(outer: o, inner: i))
        var calibrator = LipMeshCalibrator()
        let calibration = calibrator.update(contours)
        let plain = try XCTUnwrap(LipMesh.make(contours))
        let even = try XCTUnwrap(LipMesh.make(contours, calibration: calibration))
        func steps(_ mesh: LipMesh) -> [CGFloat] {
            let upper = Array(mesh.outer[0...LipMesh.samplesPerLip])
            return zip(upper, upper.dropFirst()).map { hypot($1.x - $0.x, $1.y - $0.y) }
        }
        let plainSteps = steps(plain), evenSteps = steps(even)
        XCTAssertGreaterThan(try XCTUnwrap(plainSteps.max()) / (try XCTUnwrap(plainSteps.min())), 3)
        let mean = evenSteps.reduce(0, +) / CGFloat(evenSteps.count)
        for step in evenSteps { XCTAssertEqual(step, mean, accuracy: mean * 0.15) }
        XCTAssertEqual(even.outer[0], o[13])
        XCTAssertEqual(even.outer[LipMesh.samplesPerLip], o[7])
        // Каждая цепочка берёт СВОИ доли: внешний и внутренний верх и низ.
        let fractions = try XCTUnwrap(calibration).fractions
        let k = LipMesh.samplesPerLip
        let rings = [even.outer, even.outer, even.inner, even.inner]
        for c in 0..<4 {
            for j in 1..<k {
                let expected = LipMesh.point(on: contours.chains[c],
                                             at: LipMesh.parameter(at: CGFloat(j) / CGFloat(k), fractions: fractions[c]))
                let node = rings[c][c.isMultiple(of: 2) ? j : 2 * k - j]
                XCTAssertEqual(node.x, expected.x, accuracy: 1e-9, "цепочка \(c), узел \(j)")
                XCTAssertEqual(node.y, expected.y, accuracy: 1e-9, "цепочка \(c), узел \(j)")
            }
        }
    }

    /// Первые 15 кадров копятся в среднее, потом калибровка замораживается и
    /// другие кадры её не меняют.
    func testCalibrationFreezesAfterFifteenFrames() throws {
        let a = try XCTUnwrap(LipContours.vision(outer: visionLips().outer, inner: visionLips().inner))
        let skewed = visionLips(spacing: { $0 * $0 })
        let b = try XCTUnwrap(LipContours.vision(outer: skewed.outer, inner: skewed.inner))
        XCTAssertEqual(LipMeshCalibrator.frames, 15)
        var calibrator = LipMeshCalibrator()
        XCTAssertNil(calibrator.calibration)
        let first = try XCTUnwrap(calibrator.update(a))
        let mixed = try XCTUnwrap(calibrator.update(b))
        let fa = LipMeshCalibrator.fractions(a.outer.upper), fb = LipMeshCalibrator.fractions(b.outer.upper)
        XCTAssertEqual(first.fractions[0], fa)
        XCTAssertEqual(mixed.fractions[0][3], (fa[3] + fb[3]) / 2, accuracy: 1e-12)
        for _ in 2..<(LipMeshCalibrator.frames - 1) { _ = calibrator.update(a) }
        XCTAssertFalse(calibrator.isFrozen)
        let frozen = calibrator.update(a)
        XCTAssertTrue(calibrator.isFrozen)
        for _ in 0..<5 { XCTAssertEqual(calibrator.update(b), frozen) }
        XCTAssertEqual(calibrator.frameCount, LipMeshCalibrator.frames)
        // Средние доли не убывают и идут от 0 до 1.
        for chain in try XCTUnwrap(frozen).fractions {
            XCTAssertEqual(chain.first, 0)
            XCTAssertEqual(chain.last, 1)
            XCTAssertEqual(chain, chain.sorted())
        }
    }

    /// Сменилось число точек (другое созвездие) — у новой раскладки своя
    /// калибровка с нуля, а старая к новым цепочкам не применяется.
    func testCalibratorRestartsWhenPointCountChanges() throws {
        let a = try XCTUnwrap(LipContours.vision(outer: visionLips().outer, inner: visionLips().inner))
        var calibrator = LipMeshCalibrator()
        for _ in 0..<LipMeshCalibrator.frames { _ = calibrator.update(a) }
        let old = try XCTUnwrap(calibrator.calibration)
        XCTAssertTrue(calibrator.isFrozen)
        let b = try XCTUnwrap(LipContours.vision(outer: ellipse(rx: 60, ry: 24, count: 10),
                                                 inner: ellipse(rx: 40, ry: 8, count: 6)))
        let fresh = try XCTUnwrap(calibrator.update(b))
        XCTAssertFalse(calibrator.isFrozen)
        XCTAssertEqual(calibrator.frameCount, 1)
        XCTAssertEqual(fresh.fractions.map(\.count), b.chains.map(\.count))
        // Чужая калибровка молча игнорируется — узлы по индексу.
        XCTAssertEqual(LipMesh.make(b, calibration: old), LipMesh.make(b))
        calibrator.reset()
        XCTAssertNil(calibrator.calibration)
        XCTAssertEqual(calibrator.frameCount, 0)
    }

    /// Один кадр запасного пути (таблица неправдоподобна, раскладка другая)
    /// не стирает замороженную калибровку таблицы.
    func testFallbackFrameKeepsFrozenCalibration() throws {
        let (o, i) = visionLips()
        let table = try XCTUnwrap(LipContours.vision(outer: o, inner: i))
        var shifted = o
        shifted[0].x = o[13].x - 20
        let fallback = try XCTUnwrap(LipContours.vision(outer: shifted, inner: i))
        XCTAssertNotEqual(fallback.chains.map(\.count), table.chains.map(\.count))
        var calibrator = LipMeshCalibrator()
        for _ in 0..<LipMeshCalibrator.frames { _ = calibrator.update(table) }
        let frozen = try XCTUnwrap(calibrator.calibration)
        _ = calibrator.update(fallback)
        XCTAssertEqual(calibrator.update(table), frozen)
        XCTAssertTrue(calibrator.isFrozen)
        XCTAssertEqual(calibrator.frameCount, LipMeshCalibrator.frames)
    }

    // MARK: - Сомкнутые губы

    /// Внутренний контур перекрещён (верх ниже низа) — пары узлов схлопываются
    /// в середину, контур ложится линией, а не перекручивается.
    func testCrossedInnerContourCollapsesToLine() throws {
        let k = LipMesh.samplesPerLip
        let (o, i) = visionLips(gap: -4)
        let mesh = try XCTUnwrap(LipMesh.make(outer: o, inner: i))
        for j in 1..<k {
            XCTAssertEqual(mesh.inner[j], mesh.inner[2 * k - j], "пара \(j)")
        }
        for p in mesh.inner + mesh.bands.flatMap({ $0 }) { XCTAssertTrue(p.x.isFinite && p.y.isFinite) }
        // Открытый рот не трогается.
        let (o2, i2) = visionLips(gap: 8)
        let open = try XCTUnwrap(LipMesh.make(outer: o2, inner: i2))
        XCTAssertLessThan(open.inner[k / 2].y, open.inner[2 * k - k / 2].y)
    }

    // MARK: - MediaPipe

    /// Четыре кольца по 20 точек: внешнее и внутреннее — контуры, два средних —
    /// настоящие кольца; всё прочее — nil.
    func testMediaPipeAdapterReadsRingLayout() throws {
        XCTAssertEqual(LipContours.mediaPipeRings.map(\.count), [20, 20, 20, 20])
        XCTAssertEqual(Set(LipContours.mediaPipeRings.joined()).count, 80)
        let rings = (0..<4).map { mediaPipeRing(rx: 60 - 6 * CGFloat($0), ry: 24 - 5 * CGFloat($0)) }
        let contours = try XCTUnwrap(LipContours.mediaPipe(rings: rings))
        let r0 = rings[0], r3 = rings[3]
        XCTAssertEqual(contours.outer.upper, Array(r0[0...10]))
        XCTAssertEqual(contours.outer.lower, [r0[0]] + r0[11...19].reversed() + [r0[10]])
        XCTAssertEqual(contours.inner.upper, Array(r3[0...10]))
        XCTAssertEqual(contours.bands.count, 2)
        XCTAssertEqual(contours.bands[0].upper, Array(rings[1][0...10]))
        XCTAssertEqual(contours.keypoints, Array(rings.joined()))
        XCTAssertLessThan(meanY(contours.outer.upper[1..<10]), meanY(contours.outer.lower[1..<10]))

        XCTAssertNil(LipContours.mediaPipe(rings: Array(rings.prefix(3))))
        XCTAssertNil(LipContours.mediaPipe(rings: [Array(r0.dropLast())] + rings.dropFirst()))
        var broken = rings
        broken[2][4].x = .nan
        XCTAssertNil(LipContours.mediaPipe(rings: broken))
    }

    /// Настоящие кольца MediaPipe попадают в сетку как есть, вместо интерполяции.
    func testRealBandsReplaceInterpolation() throws {
        // Второе кольцо нарочно не на трети пути между внешним и внутренним.
        let rings = [mediaPipeRing(rx: 60, ry: 24), mediaPipeRing(rx: 58, ry: 30),
                     mediaPipeRing(rx: 50, ry: 12), mediaPipeRing(rx: 44, ry: 8)]
        let contours = try XCTUnwrap(LipContours.mediaPipe(rings: rings))
        let mesh = try XCTUnwrap(LipMesh.make(contours))
        let k = LipMesh.samplesPerLip
        XCTAssertEqual(mesh.bands.count, 2)
        for band in mesh.bands { XCTAssertEqual(band.count, 2 * k) }
        // Верх — 11 точек: середина губы (k = 6) — ровно точка 5 кольца.
        XCTAssertEqual(mesh.bands[0][k / 2], rings[1][5])
        XCTAssertEqual(mesh.bands[1][k / 2], rings[2][5])
        XCTAssertEqual(mesh.inner[k / 2], rings[3][5])
        let interpolated = LipMesh(outer: mesh.outer, inner: mesh.inner, keypoints: mesh.keypoints)
        XCTAssertNotEqual(mesh.bands, interpolated.bands)
    }

    /// Плавный контур для отрисовки: размер постоянный, через узлы проходит,
    /// уголки рта на месте.
    func testSmoothRingPassesThroughNodes() throws {
        let mesh = try XCTUnwrap(LipMesh.make(outer: ellipse(rx: 60, ry: 24, count: 14),
                                              inner: ellipse(rx: 40, ry: 8, count: 10)))
        let steps = LipMesh.contourSteps
        let curve = LipMesh.smoothRing(mesh.outer)
        XCTAssertEqual(curve.count, mesh.outer.count * steps)
        for (j, node) in mesh.outer.enumerated() {
            XCTAssertEqual(curve[j * steps].x, node.x, accuracy: 1e-6)
            XCTAssertEqual(curve[j * steps].y, node.y, accuracy: 1e-6)
        }
    }

    // MARK: - Сглаживание

    /// Сглаживатель догоняет цель постепенно и сохраняет форму сетки.
    func testSmootherFollowsGradually() throws {
        var smoother = LipMeshSmoother()
        let a = try XCTUnwrap(LipMesh.make(outer: ellipse(rx: 60, ry: 24, count: 14),
                                           inner: ellipse(rx: 40, ry: 8, count: 10)))
        let b = try XCTUnwrap(LipMesh.make(outer: ellipse(center: CGPoint(x: 700, y: 480), rx: 60, ry: 24, count: 14),
                                           inner: ellipse(center: CGPoint(x: 700, y: 480), rx: 40, ry: 8, count: 10)))
        XCTAssertEqual(smoother.update(a), a)
        let first = smoother.update(b)
        XCTAssertGreaterThan(first.outer[0].x, a.outer[0].x)
        XCTAssertLessThan(first.outer[0].x, b.outer[0].x)
        XCTAssertEqual(first.outer.count, ringSize)
        XCTAssertEqual(first.keypoints.count, b.keypoints.count)
        // Кольца сглаживаются вместе с контурами, а не прыгают к цели.
        let mid = LipMesh.samplesPerLip / 2
        XCTAssertGreaterThan(first.bands[0][mid].x, a.bands[0][mid].x)
        XCTAssertLessThan(first.bands[0][mid].x, b.bands[0][mid].x)
        var last = first
        for _ in 0..<30 { last = smoother.update(b) }
        XCTAssertEqual(last.outer[0].x, b.outer[0].x, accuracy: 0.01)
    }

    /// Сменилось число точек Vision — сглаживать не с чем, берётся новая сетка.
    func testSmootherRestartsWhenShapeChanges() throws {
        var smoother = LipMeshSmoother()
        let a = try XCTUnwrap(LipMesh.make(outer: ellipse(rx: 60, ry: 24, count: 14),
                                           inner: ellipse(rx: 40, ry: 8, count: 10)))
        let b = try XCTUnwrap(LipMesh.make(outer: ellipse(center: CGPoint(x: 700, y: 480), rx: 60, ry: 24, count: 10),
                                           inner: ellipse(center: CGPoint(x: 700, y: 480), rx: 40, ry: 8, count: 6)))
        _ = smoother.update(a)
        XCTAssertEqual(smoother.update(b), b)
        smoother.reset()
        XCTAssertEqual(smoother.update(a), a)
    }
}
