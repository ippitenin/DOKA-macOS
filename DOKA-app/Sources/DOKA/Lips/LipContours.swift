import CoreGraphics
import Foundation

/// Губа от левого уголка до правого (в кадре), уголки включены.
/// Координаты — пиксели кадра камеры, начало сверху слева, без зеркала.
struct LipChain: Equatable {
    /// Верхняя губа слева направо.
    var upper: [CGPoint]
    /// Нижняя губа слева направо.
    var lower: [CGPoint]

    /// Уголки рта — общие концы губ. Их же берёт камера зеркала.
    var corners: (left: CGPoint, right: CGPoint)? {
        guard let left = upper.first, let right = upper.last else { return nil }
        return (left, right)
    }
}

/// Губы от любого источника точек: сетка `LipMesh` строится из этого
/// описания, а не из точек Vision напрямую. Vision — лишь один адаптер;
/// второй, MediaPipe, готов заранее — на случай, если Vision не потянет.
struct LipContours: Equatable {
    var outer: LipChain
    var inner: LipChain
    /// Настоящие промежуточные кольца от внешнего к внутреннему (MediaPipe);
    /// пусто — сетка интерполирует их между внешним и внутренним контуром.
    var bands: [LipChain] = []
    /// Точки источника как есть (после фильтра) — рисуются яркими «ключевыми точками».
    var keypoints: [CGPoint]

    /// Все цепочки по порядку: внешний верх и низ, внутренний верх и низ,
    /// затем кольца `bands`. В этом же порядке их калибрует `LipMeshCalibrator`.
    var chains: [[CGPoint]] {
        [outer.upper, outer.lower, inner.upper, inner.lower] + bands.flatMap { [$0.upper, $0.lower] }
    }

    // MARK: - Vision

    /// Уголки внешнего контура Vision по числу его точек (внутренний — 6 точек
    /// без уголков). Обход по часовой на экране: левый уголок, верх слева
    /// направо, правый уголок, низ справа налево. Стенд (rev3/76, 8774 кадра):
    /// у 14 точек уголки 13 и 7 стабильны на всех кадрах; 10 точек — созвездие
    /// 65, на случай macOS без явного 76. `visionTable` полагается на эту
    /// раскладку: верх начинается с точки 0, левый уголок — последняя точка обхода.
    static let visionCorners: [Int: (left: Int, right: Int)] = [14: (13, 7), 10: (9, 5)]
    /// Во внутреннем контуре Vision: 0…2 — верх слева направо, 3…5 — низ справа налево.
    static let visionInnerCount = 6
    /// На сколько ширины рта табличный уголок может не дотянуть до крайней
    /// точки вдоль оси, чтобы таблица ещё считалась правдоподобной.
    static let cornerSlack: CGFloat = 0.1

    /// Контуры губ из точек Vision. `axis` — направление слева направо в кадре
    /// (ось глаз); по нему определяются крайние точки и «вниз, к подбородку».
    /// Знак оси не важен: кадр не зеркальный, голова не наклоняется на 90°,
    /// поэтому ось всегда разворачивается слева направо — глаза в порядке
    /// Vision (левый, правый) дали бы её задом наперёд.
    ///
    /// Сначала — таблица индексов: уголки по номеру точки не перескакивают
    /// с кадра на кадр (правило «крайняя по x» меняло уголок внутреннего
    /// контура на 11,7 % пар соседних кадров), а внутренний контур, который у
    /// Vision покрывает только центр рта, проводится через ВНЕШНИЕ уголки —
    /// ошибка формы против MediaPipe падает с 7,6 до 1,7 % межглазного.
    /// Таблица берётся, только если на этом кадре она правдоподобна (уголки
    /// крайние вдоль оси, верх выше низа), иначе — запасной путь по геометрии.
    ///
    /// nil — точек меньше трёх, есть нечисловые или контур вырожден вдоль оси.
    static func vision(outer: [CGPoint], inner: [CGPoint],
                       axis: CGVector = CGVector(dx: 1, dy: 0)) -> LipContours? {
        guard outer.count >= 3, inner.count >= 3,
              (outer + inner).allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        var a = unit(axis)
        if a.dx < 0 { a = CGVector(dx: -a.dx, dy: -a.dy) }
        let down = CGVector(dx: -a.dy, dy: a.dx)
        let keypoints = outer + inner
        if let table = visionTable(outer: outer, inner: inner, axis: a, down: down) {
            return LipContours(outer: table.outer, inner: table.inner, keypoints: keypoints)
        }
        guard let outerChain = extremeChains(outer, axis: a, down: down),
              let innerChain = extremeChains(inner, axis: a, down: down) else { return nil }
        return LipContours(outer: outerChain, inner: innerChain, keypoints: keypoints)
    }

    private static func visionTable(outer: [CGPoint], inner: [CGPoint], axis: CGVector,
                                    down: CGVector) -> (outer: LipChain, inner: LipChain)? {
        guard inner.count == visionInnerCount, let (l, r) = visionCorners[outer.count],
              l == outer.count - 1, r > 0 else { return nil }
        let projections = outer.map { project($0, axis) }
        guard let minP = projections.min(), let maxP = projections.max() else { return nil }
        let slack = (maxP - minP) * cornerSlack
        guard maxP - minP > 1e-6, projections[l] - minP <= slack, maxP - projections[r] <= slack else {
            return nil
        }
        let left = outer[l], right = outer[r]
        let upperInterior = Array(outer[0..<r])
        let lowerInterior = Array(outer[(r + 1)..<l].reversed())
        guard meanProjection(upperInterior, down) < meanProjection(lowerInterior, down) else { return nil }
        let outerChain = LipChain(upper: [left] + upperInterior + [right],
                                  lower: [left] + lowerInterior + [right])
        let innerChain = LipChain(upper: [left] + inner[0...2] + [right],
                                  lower: [left] + [inner[5], inner[4], inner[3]] + [right])
        return (outerChain, innerChain)
    }

    /// Запасной путь без состояния: уголки — крайние точки вдоль оси (самая
    /// далёкая пара на широко открытом рте сломалась бы: высота там почти
    /// равна ширине), верх и низ — по средней проекции на «вниз», поэтому
    /// направление обхода и стартовый индекс не важны.
    private static func extremeChains(_ points: [CGPoint], axis: CGVector, down: CGVector) -> LipChain? {
        let n = points.count
        let projections = points.map { project($0, axis) }
        guard let left = projections.indices.min(by: { projections[$0] < projections[$1] }),
              let right = projections.indices.max(by: { projections[$0] < projections[$1] }),
              projections[right] - projections[left] > 1e-6 else { return nil }
        func chain(from start: Int, to end: Int) -> [CGPoint] {
            var result = [points[start]]
            var i = start
            while i != end {
                i = (i + 1) % n
                result.append(points[i])
            }
            return result
        }
        let forward = chain(from: left, to: right)
        let backward = Array(chain(from: right, to: left).reversed())
        return meanProjection(forward, down) <= meanProjection(backward, down)
            ? LipChain(upper: forward, lower: backward)
            : LipChain(upper: backward, lower: forward)
    }

    // MARK: - MediaPipe

    /// Индексы FaceMesh четырёх колец губ, от внешнего к внутреннему, в порядке
    /// lipflow и стенда: [0] — левый уголок, [1…9] — верх слева направо, [10] —
    /// правый уголок, [11…19] — низ справа налево. Источника MediaPipe в
    /// приложении пока нет — константа ждёт его здесь.
    static let mediaPipeRings: [[Int]] = [
        [61, 185, 40, 39, 37, 0, 267, 269, 270, 409, 291, 375, 321, 405, 314, 17, 84, 181, 91, 146],
        [76, 184, 74, 73, 72, 11, 302, 303, 304, 408, 306, 307, 320, 404, 315, 16, 85, 180, 90, 77],
        [62, 183, 42, 41, 38, 12, 268, 271, 272, 407, 292, 325, 319, 403, 316, 15, 86, 179, 89, 96],
        [78, 191, 80, 81, 82, 13, 312, 311, 310, 415, 308, 324, 318, 402, 317, 14, 87, 178, 88, 95],
    ]
    static let mediaPipeRingSize = 20

    /// Контуры из четырёх колец MediaPipe (раскладка — `mediaPipeRings`):
    /// внешнее и внутреннее — контуры, два средних — настоящие `bands`.
    /// nil — не четыре кольца по 20 точек, нечисловые точки или кольцо без ширины.
    static func mediaPipe(rings: [[CGPoint]]) -> LipContours? {
        guard rings.count == mediaPipeRings.count,
              rings.allSatisfy({ $0.count == mediaPipeRingSize }),
              rings.joined().allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        let corner = mediaPipeRingSize / 2
        func chain(_ ring: [CGPoint]) -> LipChain? {
            guard hypot(ring[corner].x - ring[0].x, ring[corner].y - ring[0].y) > 1e-6 else { return nil }
            return LipChain(upper: Array(ring[0...corner]),
                            lower: [ring[0]] + ring[(corner + 1)...].reversed() + [ring[corner]])
        }
        let chains = rings.compactMap(chain)
        guard chains.count == rings.count else { return nil }
        return LipContours(outer: chains[0], inner: chains[3], bands: [chains[1], chains[2]],
                           keypoints: Array(rings.joined()))
    }

    // MARK: - Геометрия

    private static func unit(_ v: CGVector) -> CGVector {
        let length = hypot(v.dx, v.dy)
        guard length.isFinite, length > 1e-9 else { return CGVector(dx: 1, dy: 0) }
        return CGVector(dx: v.dx / length, dy: v.dy / length)
    }

    private static func project(_ p: CGPoint, _ v: CGVector) -> CGFloat { p.x * v.dx + p.y * v.dy }

    private static func meanProjection(_ points: [CGPoint], _ v: CGVector) -> CGFloat {
        points.reduce(0) { $0 + project($1, v) } / CGFloat(max(points.count, 1))
    }
}
