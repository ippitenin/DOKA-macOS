import CoreGraphics
import XCTest
@testable import DOKA

/// Пути маски губ, готовые для слоёв зеркала.
///
/// Зачем: пути теперь строятся на `visionQueue`, вместе с картинкой того же
/// кадра, а на главном потоке только присваиваются. Всё, что раньше делал
/// оверлей (кривые, even-odd, скобки), должно остаться прежним — и пройти
/// через тот `map`, который ему дали, а не через какой-то свой.
final class LipMeshPathsTests: XCTestCase {

    private let lips = LipSyntheticFace.lips()

    private func mesh() throws -> LipMesh {
        try XCTUnwrap(LipMesh.make(outer: lips.outer, inner: lips.inner))
    }

    /// Масштаб и сдвиг — как у настоящего окна камеры.
    private func shiftAndScale(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - 500) * 0.5, y: (p.y - 400) * 0.5)
    }

    private func bounds(_ points: [CGPoint]) -> CGRect {
        let xs = points.map(\.x), ys = points.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }

    /// Сколько подпутей (`move`) в пути — у кружков по одному на точку.
    private func subpaths(_ path: CGPath) -> Int {
        var count = 0
        path.applyWithBlock { element in
            if element.pointee.type == .moveToPoint { count += 1 }
        }
        return count
    }

    func testBandCoversMappedOuterBounds() throws {
        let mesh = try mesh()
        let paths = LipMeshPaths.make(mesh, map: shiftAndScale)
        let expected = bounds(mesh.outer.map(shiftAndScale))
        let band = paths.band.boundingBoxOfPath
        // Сплайн проходит через узлы, поэтому рамка полосы — рамка внешнего
        // контура в окне (с точностью до выпуклости сплайна между узлами).
        XCTAssertTrue(band.insetBy(dx: -0.5, dy: -0.5).contains(expected), "\(band) ⊉ \(expected)")
        XCTAssertTrue(expected.insetBy(dx: -3, dy: -3).contains(band), "\(band) шире контура")
        // Внешний и внутренний контуры — два замкнутых подпути.
        XCTAssertEqual(subpaths(paths.band), 2)
    }

    /// Контуры — отдельными путями (у каждого свой цвет), а полоса — ровно
    /// они двое: заливка и контуры не разойдутся.
    func testRimsAreSeparateAndFormBand() throws {
        let mesh = try mesh()
        let paths = LipMeshPaths.make(mesh, map: shiftAndScale)
        XCTAssertEqual(subpaths(paths.outerRim), 1)
        XCTAssertEqual(subpaths(paths.innerRim), 1)
        let expected = CGMutablePath()
        expected.addPath(paths.outerRim)
        expected.addPath(paths.innerRim)
        XCTAssertEqual(paths.band, expected)
        // Сама кривая — независимо от реализации: сплайн узлов через тот же
        // `map`, замкнутый одним подпутём.
        func reference(_ ring: [CGPoint]) -> CGPath {
            let path = CGMutablePath()
            path.addLines(between: LipMesh.smoothRing(ring).map(shiftAndScale))
            path.closeSubpath()
            return path
        }
        XCTAssertEqual(paths.outerRim, reference(mesh.outer))
        XCTAssertEqual(paths.innerRim, reference(mesh.inner))
        XCTAssertEqual(paths.rings, mesh.bands.map(reference))
        let outer = bounds(mesh.outer.map(shiftAndScale))
        let inner = bounds(mesh.inner.map(shiftAndScale))
        XCTAssertTrue(paths.outerRim.boundingBoxOfPath.insetBy(dx: -0.5, dy: -0.5).contains(outer))
        XCTAssertTrue(paths.innerRim.boundingBoxOfPath.insetBy(dx: -0.5, dy: -0.5).contains(inner))
        XCTAssertTrue(outer.contains(paths.innerRim.boundingBoxOfPath), "внутренний контур вне внешнего")
    }

    /// Колец — столько же, сколько промежуточных колец сетки, каждое —
    /// один замкнутый путь, снаружи внутрь: кольца сходятся в уголках рта,
    /// поэтому ширина у них общая, а высота убывает.
    func testRingsFollowMeshBands() throws {
        let mesh = try mesh()
        let paths = LipMeshPaths.make(mesh, map: shiftAndScale)
        XCTAssertEqual(paths.rings.count, mesh.bands.count)
        XCTAssertGreaterThan(paths.rings.count, 1)
        for (ring, band) in zip(paths.rings, mesh.bands) {
            XCTAssertEqual(subpaths(ring), 1)
            let nodes = bounds(band.map(shiftAndScale))
            XCTAssertTrue(ring.boundingBoxOfPath.insetBy(dx: -0.5, dy: -0.5).contains(nodes))
        }
        for (a, b) in zip(paths.rings, paths.rings.dropFirst()) {
            XCTAssertGreaterThan(a.boundingBoxOfPath.height, b.boundingBoxOfPath.height)
        }
    }

    /// Спица — от каждого узла внешнего контура к узлу внутреннего.
    func testSpokesJoinOuterAndInnerNodes() throws {
        let mesh = try mesh()
        let paths = LipMeshPaths.make(mesh, map: shiftAndScale)
        var segments: [(CGPoint, CGPoint)] = []
        var start = CGPoint.zero
        paths.spokes.applyWithBlock { element in
            switch element.pointee.type {
            case .moveToPoint: start = element.pointee.points[0]
            case .addLineToPoint: segments.append((start, element.pointee.points[0]))
            default: break
            }
        }
        XCTAssertEqual(segments.count, min(mesh.outer.count, mesh.inner.count))
        for ((a, b), (o, i)) in zip(segments, zip(mesh.outer.map(shiftAndScale), mesh.inner.map(shiftAndScale))) {
            XCTAssertEqual(a.x, o.x, accuracy: 1e-6)
            XCTAssertEqual(a.y, o.y, accuracy: 1e-6)
            XCTAssertEqual(b.x, i.x, accuracy: 1e-6)
            XCTAssertEqual(b.y, i.y, accuracy: 1e-6)
        }
    }

    func testBracketsSurroundHalo() throws {
        let mesh = try mesh()
        let paths = LipMeshPaths.make(mesh, map: shiftAndScale)
        let halo = bounds(mesh.halo.map(shiftAndScale))
        let brackets = paths.brackets.boundingBoxOfPath
        let expected = halo.insetBy(dx: -LipMeshPaths.bracketPadding, dy: -LipMeshPaths.bracketPadding)
        XCTAssertEqual(brackets.minX, expected.minX, accuracy: 1e-6)
        XCTAssertEqual(brackets.maxX, expected.maxX, accuracy: 1e-6)
        XCTAssertEqual(brackets.minY, expected.minY, accuracy: 1e-6)
        XCTAssertEqual(brackets.maxY, expected.maxY, accuracy: 1e-6)
        XCTAssertEqual(subpaths(paths.brackets), 4)
    }

    /// Сдвиг и отражение `map` видны во всех путях.
    func testMapIsApplied() throws {
        let mesh = try mesh()
        let plain = LipMeshPaths.make(mesh) { $0 }
        let width: CGFloat = 1280
        let mirrored = LipMeshPaths.make(mesh) { CGPoint(x: width - $0.x + 10, y: $0.y + 20) }
        let all: [(CGPath, CGPath)] = [
            (plain.band, mirrored.band), (plain.outerRim, mirrored.outerRim), (plain.innerRim, mirrored.innerRim),
            (plain.spokes, mirrored.spokes), (plain.halo, mirrored.halo), (plain.keys, mirrored.keys),
            (plain.brackets, mirrored.brackets),
        ] + Array(zip(plain.rings, mirrored.rings))
        for (a, b) in all {
            let r = a.boundingBoxOfPath, m = b.boundingBoxOfPath
            XCTAssertEqual(m.minX, width - r.maxX + 10, accuracy: 1e-6)
            XCTAssertEqual(m.maxX, width - r.minX + 10, accuracy: 1e-6)
            XCTAssertEqual(m.minY, r.minY + 20, accuracy: 1e-6)
            XCTAssertEqual(m.width, r.width, accuracy: 1e-6)
        }
    }

    func testKeysCountMatchesKeypoints() throws {
        let mesh = try mesh()
        let paths = LipMeshPaths.make(mesh, map: shiftAndScale)
        XCTAssertEqual(mesh.keypoints.count, 20)
        XCTAssertEqual(subpaths(paths.keys), mesh.keypoints.count)
    }

    /// Ореол — подпуть на каждый отрезок между узлами, и каждый начинается
    /// в узле: пунктир отсчитывается от начала подпути, поэтому штрихи
    /// привязаны к узлам и не ползут, когда нижняя губа растягивает контур.
    func testHaloDashesStartAtNodes() throws {
        let mesh = try mesh()
        let paths = LipMeshPaths.make(mesh, map: shiftAndScale)
        let aura = mesh.halo.map(shiftAndScale)
        let spokes = (aura.count + 1) / 2
        XCTAssertEqual(subpaths(paths.halo), aura.count + spokes)

        var starts: [CGPoint] = []
        paths.halo.applyWithBlock { element in
            if element.pointee.type == .moveToPoint { starts.append(element.pointee.points[0]) }
        }
        for (start, node) in zip(starts.prefix(aura.count), aura) {
            XCTAssertEqual(start.x, node.x, accuracy: 1e-6)
            XCTAssertEqual(start.y, node.y, accuracy: 1e-6)
        }
    }
}
