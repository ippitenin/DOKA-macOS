import CoreGraphics
import XCTest
@testable import DOKA

/// Маска-сетка губ в зеркале: из десятка точек Vision — кольца постоянного
/// размера, сплайн вместо ломаной, сетка между внешним и внутренним контуром.
///
/// Зачем: узлы сетки должны соответствовать друг другу между кадрами Vision
/// (их сглаживают по одному) — поэтому число узлов не должно зависеть от
/// того, сколько точек отдал Vision. Уголки рта и
/// верх/низ определяются по координатам, а не по порядку обхода: порядок у
/// разных созвездий Vision разный, и сетка не должна от него зависеть.
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

    /// Ключевые точки — настоящие точки Vision, без изменений.
    func testKeypointsAreRawVisionPoints() throws {
        let outer = ellipse(rx: 60, ry: 24, count: 14)
        let inner = ellipse(rx: 40, ry: 8, count: 10)
        let mesh = try XCTUnwrap(LipMesh.make(outer: outer, inner: inner))
        XCTAssertEqual(mesh.keypoints, outer + inner)
    }

    // MARK: - Перевыборка

    /// Перевыборка равномерна по длине дуги, концы — точно исходные.
    func testResampleIsUniformByArcLength() {
        let polyline = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 10, y: 10)]
        let points = LipMesh.resample(polyline, count: 5)
        let expected = [CGPoint(x: 0, y: 0), CGPoint(x: 5, y: 0), CGPoint(x: 10, y: 0),
                        CGPoint(x: 10, y: 5), CGPoint(x: 10, y: 10)]
        XCTAssertEqual(points.count, expected.count)
        for (p, q) in zip(points, expected) {
            XCTAssertEqual(p.x, q.x, accuracy: 1e-9)
            XCTAssertEqual(p.y, q.y, accuracy: 1e-9)
        }
    }

    /// Нулевая длина — одна и та же точка нужное число раз.
    func testResampleOfPointRepeatsIt() {
        let p = CGPoint(x: 3, y: 4)
        XCTAssertEqual(LipMesh.resample([p, p], count: 4), [p, p, p, p])
    }

    /// Шаги по верхней губе почти равны: узлы не сбиваются в кучу у уголков.
    func testRingStepsAreEven() throws {
        let mesh = try XCTUnwrap(LipMesh.make(outer: ellipse(rx: 60, ry: 24, count: 14),
                                              inner: ellipse(rx: 40, ry: 8, count: 10)))
        let upper = Array(mesh.outer[0...LipMesh.samplesPerLip])
        let steps = zip(upper, upper.dropFirst()).map { hypot($1.x - $0.x, $1.y - $0.y) }
        let mean = steps.reduce(0, +) / CGFloat(steps.count)
        for step in steps { XCTAssertEqual(step, mean, accuracy: mean * 0.1) }
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
