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
            (plain.band, mirrored.band), (plain.grid, mirrored.grid), (plain.halo, mirrored.halo),
            (plain.nodes, mirrored.nodes), (plain.keys, mirrored.keys), (plain.brackets, mirrored.brackets),
        ]
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
        let nodes = mesh.bands.reduce(0) { $0 + $1.count } + mesh.outer.count + mesh.inner.count + mesh.halo.count
        XCTAssertEqual(subpaths(paths.nodes), nodes)
    }
}
