import CoreGraphics
import Foundation

/// Маска-сетка губ для зеркала: внешний и внутренний контуры сплайном, между
/// ними промежуточные кольца, снаружи — ореол. Координаты — пиксели кадра
/// камеры, начало сверху слева, без зеркала (как у `LipFaceSample`).
///
/// Это ТОЛЬКО картинка превью: все узлы — интерполяция тех же точек Vision,
/// новой информации о губах в них нет, и в `clip.mp4` маска не попадает.
///
/// Число узлов фиксированное, сколько бы точек ни отдал Vision: так узлы
/// соответствуют друг другу между кадрами и их можно сглаживать по одному.
struct LipMesh: Equatable {
    /// Узлов на губу (верхнюю и нижнюю) от уголка до уголка; кольцо — `2K`.
    static let samplesPerLip = 12
    /// Где между внешним (0) и внутренним (1) контуром лежат промежуточные кольца.
    static let bandFractions: [CGFloat] = [1.0 / 3, 2.0 / 3]
    /// Насколько ореол дальше от центра рта, чем внешний контур.
    static let haloScale: CGFloat = 0.22
    /// Отрезков сплайна между соседними точками Vision до перевыборки.
    static let splineSteps = 8
    /// Отрезков плавного контура между соседними узлами кольца при отрисовке.
    static let contourSteps = 4

    /// Кольцо внешнего контура: `outer[0]` — левый уголок, `[1..<K]` —
    /// верхняя губа слева направо, `[K]` — правый уголок, дальше — нижняя
    /// губа справа налево.
    let outer: [CGPoint]
    /// Кольцо внутреннего контура в том же порядке: `inner[j]` соответствует `outer[j]`.
    let inner: [CGPoint]
    /// Настоящие точки Vision (внешний, затем внутренний контур).
    let keypoints: [CGPoint]

    /// Промежуточные кольца, от внешнего к внутреннему.
    var bands: [[CGPoint]] {
        Self.bandFractions.map { t in
            zip(outer, inner).map { o, i in CGPoint(x: o.x + (i.x - o.x) * t, y: o.y + (i.y - o.y) * t) }
        }
    }

    /// Ореол: внешний контур, отодвинутый от центра рта.
    var halo: [CGPoint] {
        let count = CGFloat(max(outer.count, 1))
        let cx = outer.reduce(0) { $0 + $1.x } / count
        let cy = outer.reduce(0) { $0 + $1.y } / count
        let k = 1 + Self.haloScale
        return outer.map { CGPoint(x: cx + ($0.x - cx) * k, y: cy + ($0.y - cy) * k) }
    }

    /// Рамка ореола — по ней стоят угловые скобки.
    var bounds: CGRect {
        let points = halo
        guard let first = points.first else { return .null }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in points.dropFirst() {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// nil — точек меньше трёх или контур вырожден (все точки на одной вертикали).
    static func make(outer: [CGPoint], inner: [CGPoint]) -> LipMesh? {
        guard let outerRing = ring(outer), let innerRing = ring(inner) else { return nil }
        return LipMesh(outer: outerRing, inner: innerRing, keypoints: outer + inner)
    }

    /// Замкнутый контур Vision → кольцо из `2K` узлов. Уголки — крайние точки
    /// по x (самая далёкая пара на широко открытом рте сломалась бы: высота
    /// там почти равна ширине), верх и низ — по среднему y, поэтому
    /// направление обхода и стартовый индекс у Vision не важны.
    private static func ring(_ points: [CGPoint]) -> [CGPoint]? {
        let n = points.count
        guard n >= 3, points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
              let left = points.indices.min(by: { points[$0].x < points[$1].x }),
              let right = points.indices.max(by: { points[$0].x < points[$1].x }),
              points[right].x - points[left].x > 1e-6 else { return nil }
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
        func meanY(_ chain: [CGPoint]) -> CGFloat { chain.reduce(0) { $0 + $1.y } / CGFloat(chain.count) }
        let (upper, lower) = meanY(forward) <= meanY(backward) ? (forward, backward) : (backward, forward)
        let count = samplesPerLip + 1
        let top = resample(spline(upper), count: count)
        let bottom = resample(spline(lower), count: count)
        return top + bottom.dropFirst().dropLast().reversed()
    }

    /// Кольцо узлов → плавный контур для отрисовки (`2K × contourSteps`
    /// точек, через каждый `contourSteps`-й проходит узел). Каждая губа — свой
    /// сплайн от уголка до уголка, поэтому уголки рта остаются острыми.
    static func smoothRing(_ ring: [CGPoint]) -> [CGPoint] {
        guard ring.count >= 4, ring.count.isMultiple(of: 2) else { return ring }
        let k = ring.count / 2
        let top = spline(Array(ring[0...k]), steps: contourSteps)
        let bottom = spline(Array(ring[k...]) + [ring[0]], steps: contourSteps)
        return top + bottom.dropFirst().dropLast()
    }

    /// Центростремительный сплайн Катмулла–Рома через точки цепочки (без
    /// петель и выбросов на неравных шагах). Концы продолжаются отражением.
    static func spline(_ points: [CGPoint], steps: Int = splineSteps) -> [CGPoint] {
        guard points.count >= 2 else { return points }
        let first = points[0], last = points[points.count - 1]
        let head = CGPoint(x: 2 * first.x - points[1].x, y: 2 * first.y - points[1].y)
        let beforeLast = points[points.count - 2]
        let tail = CGPoint(x: 2 * last.x - beforeLast.x, y: 2 * last.y - beforeLast.y)
        let control = [head] + points + [tail]
        var result: [CGPoint] = []
        result.reserveCapacity((points.count - 1) * steps + 1)
        for i in 1..<(control.count - 2) {
            result += segment(control[i - 1], control[i], control[i + 1], control[i + 2], steps: steps)
        }
        result.append(last)
        return result
    }

    /// Точки отрезка p1→p2 (без p2), формула Барри–Голдмана, α = 0,5.
    private static func segment(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint,
                                steps: Int) -> [CGPoint] {
        // Совпавшие точки дали бы нулевой шаг узлов и деление на ноль.
        func knot(_ a: CGPoint, _ b: CGPoint) -> CGFloat { max(sqrt(hypot(b.x - a.x, b.y - a.y)), 1e-4) }
        func mix(_ a: CGPoint, _ b: CGPoint, _ ta: CGFloat, _ tb: CGFloat, _ t: CGFloat) -> CGPoint {
            let wa = (tb - t) / (tb - ta), wb = (t - ta) / (tb - ta)
            return CGPoint(x: a.x * wa + b.x * wb, y: a.y * wa + b.y * wb)
        }
        let t0: CGFloat = 0
        let t1 = t0 + knot(p0, p1)
        let t2 = t1 + knot(p1, p2)
        let t3 = t2 + knot(p2, p3)
        return (0..<steps).map { s in
            let t = t1 + (t2 - t1) * CGFloat(s) / CGFloat(steps)
            let a1 = mix(p0, p1, t0, t1, t)
            let a2 = mix(p1, p2, t1, t2, t)
            let a3 = mix(p2, p3, t2, t3, t)
            let b1 = mix(a1, a2, t0, t2, t)
            let b2 = mix(a2, a3, t1, t3, t)
            return mix(b1, b2, t1, t2, t)
        }
    }

    /// `count` точек ломаной через равные шаги по длине дуги; концы — точно исходные.
    static func resample(_ polyline: [CGPoint], count: Int) -> [CGPoint] {
        guard let first = polyline.first, let last = polyline.last, count >= 2 else {
            return Array(polyline.prefix(count))
        }
        var lengths: [CGFloat] = [0]
        for (a, b) in zip(polyline, polyline.dropFirst()) {
            lengths.append(lengths[lengths.count - 1] + hypot(b.x - a.x, b.y - a.y))
        }
        let total = lengths[lengths.count - 1]
        guard total > 0 else { return Array(repeating: first, count: count) }
        var result = [first]
        var segment = 1
        for k in 1..<(count - 1) {
            let target = total * CGFloat(k) / CGFloat(count - 1)
            while segment < lengths.count - 1, lengths[segment] < target { segment += 1 }
            let a = polyline[segment - 1], b = polyline[segment]
            let span = lengths[segment] - lengths[segment - 1]
            let t = span > 0 ? (target - lengths[segment - 1]) / span : 0
            result.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
        }
        result.append(last)
        return result
    }
}

/// Сглаживание маски между кадрами Vision: экспоненциальное среднее по каждому
/// узлу. Губы на речи двигаются быстро, поэтому отклик высокий — сетка
/// перестаёт дрожать, но не отстаёт от артикуляции.
struct LipMeshSmoother {
    static let response: CGFloat = 0.6

    private(set) var current: LipMesh?

    mutating func update(_ mesh: LipMesh) -> LipMesh {
        // Другое число точек Vision — узлы не соответствуют, сглаживать не с чем.
        guard let previous = current, previous.keypoints.count == mesh.keypoints.count,
              previous.outer.count == mesh.outer.count else {
            current = mesh
            return mesh
        }
        func mix(_ a: [CGPoint], _ b: [CGPoint]) -> [CGPoint] {
            zip(a, b).map { p, q in
                CGPoint(x: p.x + (q.x - p.x) * Self.response, y: p.y + (q.y - p.y) * Self.response)
            }
        }
        let next = LipMesh(outer: mix(previous.outer, mesh.outer), inner: mix(previous.inner, mesh.inner),
                           keypoints: mix(previous.keypoints, mesh.keypoints))
        current = next
        return next
    }

    mutating func reset() { current = nil }
}
