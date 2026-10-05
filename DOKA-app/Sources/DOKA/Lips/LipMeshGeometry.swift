import CoreGraphics
import Foundation

/// Маска-сетка губ для зеркала: внешний и внутренний контуры сплайном, между
/// ними промежуточные кольца, снаружи — ореол. Координаты — пиксели кадра
/// камеры, начало сверху слева, без зеркала (как у `LipFaceSample`).
///
/// Это ТОЛЬКО картинка превью: все узлы — интерполяция тех же точек
/// источника, новой информации о губах в них нет, и в `clip.mp4` маска не попадает.
///
/// Число узлов фиксированное, сколько бы точек ни отдал источник: так узлы
/// соответствуют друг другу между кадрами. Узлы ставятся по ПАРАМЕТРУ ИНДЕКСА
/// точек источника (сплайн проходит через сами точки), а не по длине дуги:
/// сдвиг одной точки двигает только соседние узлы, и узлы не скользят вдоль губы.
struct LipMesh: Equatable {
    /// Узлов на губу (верхнюю и нижнюю) от уголка до уголка; кольцо — `2K`.
    static let samplesPerLip = 12
    /// Где между внешним (0) и внутренним (1) контуром лежат промежуточные кольца,
    /// когда настоящих колец у источника нет.
    static let bandFractions: [CGFloat] = [1.0 / 3, 2.0 / 3]
    /// Насколько ореол дальше от центра рта, чем внешний контур.
    static let haloScale: CGFloat = 0.22
    /// Отрезков сплайна между соседними точками в `spline` по умолчанию.
    static let splineSteps = 8
    /// Отрезков плавного контура между соседними узлами кольца при отрисовке.
    static let contourSteps = 4

    /// Кольцо внешнего контура: `outer[0]` — левый уголок, `[1..<K]` —
    /// верхняя губа слева направо, `[K]` — правый уголок, дальше — нижняя
    /// губа справа налево.
    let outer: [CGPoint]
    /// Кольцо внутреннего контура в том же порядке: `inner[j]` соответствует `outer[j]`.
    let inner: [CGPoint]
    /// Промежуточные кольца от внешнего к внутреннему: настоящие, если они есть
    /// у источника (MediaPipe), иначе интерполяция по `bandFractions`.
    let bands: [[CGPoint]]
    /// Точки источника как пришли (после фильтра) — «ключевые точки» маски.
    let keypoints: [CGPoint]

    /// `bands == nil` — промежуточные кольца интерполируются между `outer` и `inner`.
    init(outer: [CGPoint], inner: [CGPoint], bands: [[CGPoint]]? = nil, keypoints: [CGPoint]) {
        self.outer = outer
        self.inner = inner
        self.bands = bands ?? Self.bandFractions.map { t in
            zip(outer, inner).map { o, i in CGPoint(x: o.x + (i.x - o.x) * t, y: o.y + (i.y - o.y) * t) }
        }
        self.keypoints = keypoints
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

    /// Оболочка для зеркала на точках Vision без оси глаз и без калибровки.
    static func make(outer: [CGPoint], inner: [CGPoint]) -> LipMesh? {
        LipContours.vision(outer: outer, inner: inner).flatMap { make($0) }
    }

    /// Контуры губ → сетка. Узел k цепочки из n точек — при параметре индекса
    /// `u = calibration ?? k·(n−1)/K`; узлы 0 и K — ровно уголки. Калибровка с
    /// другим числом точек (сменилось созвездие) не применяется.
    ///
    /// nil — в какой-то цепочке меньше двух точек или есть нечисловые.
    static func make(_ contours: LipContours, calibration: LipMeshCalibration? = nil) -> LipMesh? {
        let chains = contours.chains
        guard chains.allSatisfy({ $0.count >= 2 && $0.allSatisfy { $0.x.isFinite && $0.y.isFinite } }),
              let (left, right) = contours.outer.corners else {
            return nil
        }
        let fractions = calibration?.fractions.map(\.count) == chains.map(\.count) ? calibration?.fractions : nil
        let k = samplesPerLip
        func nodes(_ c: Int) -> [CGPoint] {
            let chain = chains[c]
            let last = CGFloat(chain.count - 1)
            return (0...k).map { j in
                let u: CGFloat
                if j == 0 { u = 0 }
                else if j == k { u = last }
                else {
                    u = fractions.map { parameter(at: CGFloat(j) / CGFloat(k), fractions: $0[c]) }
                        ?? CGFloat(j) * last / CGFloat(k)
                }
                return point(on: chain, at: u)
            }
        }
        func ring(_ c: Int) -> [CGPoint] { nodes(c) + nodes(c + 1).dropFirst().dropLast().reversed() }
        let outer = ring(0)
        let inner = uncrossed(ring(2), down: CGVector(dx: left.y - right.y, dy: right.x - left.x))
        let bands = contours.bands.isEmpty ? nil : contours.bands.indices.map { ring(4 + 2 * $0) }
        return LipMesh(outer: outer, inner: inner, bands: bands, keypoints: contours.keypoints)
    }

    /// Обратная кусочно-линейная интерполяция: параметр индекса, при котором
    /// средняя доля длины дуги равна `target`. Доли не убывают по построению.
    static func parameter(at target: CGFloat, fractions: [CGFloat]) -> CGFloat {
        guard fractions.count >= 2 else { return 0 }
        for i in 0..<(fractions.count - 1) where fractions[i + 1] >= target {
            let span = fractions[i + 1] - fractions[i]
            return CGFloat(i) + (span > 0 ? max(0, target - fractions[i]) / span : 0)
        }
        return CGFloat(fractions.count - 1)
    }

    /// На сомкнутых губах внутренний контур Vision бывает перекрещён (верх ниже
    /// низа) и рисовался бы перекрученной линией. Такая пара узлов схлопывается
    /// в свою середину — контур ложится линией. `down` — к подбородку.
    private static func uncrossed(_ ring: [CGPoint], down: CGVector) -> [CGPoint] {
        let k = ring.count / 2
        guard k >= 2 else { return ring }
        var result = ring
        for j in 1..<k {
            let top = ring[j], bottom = ring[2 * k - j]
            guard (top.x - bottom.x) * down.dx + (top.y - bottom.y) * down.dy > 0 else { continue }
            let mid = CGPoint(x: (top.x + bottom.x) / 2, y: (top.y + bottom.y) / 2)
            result[j] = mid
            result[2 * k - j] = mid
        }
        return result
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
        var result: [CGPoint] = []
        result.reserveCapacity((points.count - 1) * steps + 1)
        for i in 0..<(points.count - 1) {
            let (p0, p3) = neighbours(points, segment: i)
            for s in 0..<steps {
                result.append(segmentPoint(p0, points[i], points[i + 1], p3, CGFloat(s) / CGFloat(steps)))
            }
        }
        result.append(points[points.count - 1])
        return result
    }

    /// Точка цепочки при параметре индекса `u ∈ [0, n−1]`: при целом `u` —
    /// ровно исходная точка, между ними — тот же сплайн, что у `spline`.
    static func point(on chain: [CGPoint], at u: CGFloat) -> CGPoint {
        guard chain.count >= 2 else { return chain.first ?? .zero }
        // NaN прошёл бы сквозь min/max, а Int(NaN) — аварийная остановка.
        guard u.isFinite else { return chain[0] }
        let u = min(max(u, 0), CGFloat(chain.count - 1))
        let i = min(Int(u.rounded(.down)), chain.count - 2)
        let f = u - CGFloat(i)
        if f <= 0 { return chain[i] }
        if f >= 1 { return chain[i + 1] }
        let (p0, p3) = neighbours(chain, segment: i)
        return segmentPoint(p0, chain[i], chain[i + 1], p3, f)
    }

    /// Внешние опоры отрезка i→i+1; за концами цепочки — отражение соседа.
    private static func neighbours(_ points: [CGPoint], segment i: Int) -> (CGPoint, CGPoint) {
        let n = points.count
        let p0 = i > 0 ? points[i - 1]
            : CGPoint(x: 2 * points[0].x - points[1].x, y: 2 * points[0].y - points[1].y)
        let p3 = i + 2 < n ? points[i + 2]
            : CGPoint(x: 2 * points[n - 1].x - points[n - 2].x, y: 2 * points[n - 1].y - points[n - 2].y)
        return (p0, p3)
    }

    /// Точка отрезка p1→p2 на доле `f ∈ [0, 1]`, формула Барри–Голдмана, α = 0,5.
    private static func segmentPoint(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint,
                                     _ f: CGFloat) -> CGPoint {
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
        let t = t1 + (t2 - t1) * f
        let a1 = mix(p0, p1, t0, t1, t)
        let a2 = mix(p1, p2, t1, t2, t)
        let a3 = mix(p2, p3, t2, t3, t)
        let b1 = mix(a1, a2, t0, t2, t)
        let b2 = mix(a2, a3, t1, t3, t)
        return mix(b1, b2, t1, t2, t)
    }
}

/// Калибровка выборки узлов: средние доли длины дуги по точкам источника,
/// по цепочке на элемент в порядке `LipContours.chains`. Узел k ставится туда,
/// где средняя доля равна k/K, — в среднем узлы ложатся равномерно, а на
/// конкретном кадре остаются привязанными к индексам и не скользят.
struct LipMeshCalibration: Equatable {
    var fractions: [[CGFloat]]
}

/// Калибратор дубля: копит доли длины дуги за первые `frames` кадров и
/// замораживает их. Настоящие кольца MediaPipe калибруются так же, по своим
/// цепочкам: у колец FaceMesh тоже неравные шаги. До заморозки отдаёт текущее
/// среднее — узлы сходятся к нему плавно.
///
/// Копится отдельно для каждой раскладки цепочек (число точек в каждой). Созвездие
/// Vision внутри дубля не меняется, но кадр, где таблица неправдоподобна, идёт
/// запасным путём с другой раскладкой — и один такой кадр не должен стирать
/// замороженную калибровку таблицы. Новое созвездие — новая раскладка, то есть
/// калибровка с нуля. Раскладок запасного пути — считанные единицы.
struct LipMeshCalibrator {
    static let frames = 15

    private struct Accumulator {
        var sums: [[CGFloat]]
        var frameCount = 0
    }

    private var accumulators: [[Int]: Accumulator] = [:]
    /// Раскладка последнего кадра: к ней относятся `calibration`, `frameCount` и `isFrozen`.
    private var layout: [Int]?

    var frameCount: Int { layout.flatMap { accumulators[$0]?.frameCount } ?? 0 }

    var isFrozen: Bool { frameCount >= Self.frames }

    var calibration: LipMeshCalibration? {
        guard let layout, let accumulator = accumulators[layout], accumulator.frameCount > 0 else { return nil }
        let n = CGFloat(accumulator.frameCount)
        return LipMeshCalibration(fractions: accumulator.sums.map { $0.map { $0 / n } })
    }

    mutating func update(_ contours: LipContours) -> LipMeshCalibration? {
        let chains = contours.chains
        let key = chains.map(\.count)
        layout = key
        var accumulator = accumulators[key] ?? Accumulator(sums: chains.map { Array(repeating: 0, count: $0.count) })
        if accumulator.frameCount < Self.frames {
            for (c, chain) in chains.enumerated() {
                for (i, f) in Self.fractions(chain).enumerated() { accumulator.sums[c][i] += f }
            }
            accumulator.frameCount += 1
            accumulators[key] = accumulator
        }
        return calibration
    }

    mutating func reset() {
        accumulators = [:]
        layout = nil
    }

    /// Доли длины ломаной по точкам: от 0 до 1; нулевая длина — равномерно по индексу.
    static func fractions(_ chain: [CGPoint]) -> [CGFloat] {
        guard chain.count >= 2 else { return chain.map { _ in 0 } }
        var lengths: [CGFloat] = [0]
        for (a, b) in zip(chain, chain.dropFirst()) {
            lengths.append(lengths[lengths.count - 1] + hypot(b.x - a.x, b.y - a.y))
        }
        let total = lengths[lengths.count - 1]
        let last = CGFloat(chain.count - 1)
        guard total > 1e-9, total.isFinite else { return chain.indices.map { CGFloat($0) / last } }
        var result = lengths.map { $0 / total }
        result[result.count - 1] = 1
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
        let bands = previous.bands.count == mesh.bands.count ? zip(previous.bands, mesh.bands).map(mix) : mesh.bands
        let next = LipMesh(outer: mix(previous.outer, mesh.outer), inner: mix(previous.inner, mesh.inner),
                           bands: bands, keypoints: mix(previous.keypoints, mesh.keypoints))
        current = next
        return next
    }

    mutating func reset() { current = nil }
}
