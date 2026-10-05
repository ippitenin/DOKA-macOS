import CoreGraphics
import Foundation
import QuartzCore

/// Окно зеркала: размер в точках, масштаб экрана, Reduce Motion.
struct LipMirrorTarget: Equatable {
    let size: CGSize
    let scale: CGFloat
    let reduceMotion: Bool

    /// Размер картинки в целых пикселях, не меньше 1×1.
    var pixelSize: CGSize {
        CGSize(width: max((size.width * scale).rounded(), 1), height: max((size.height * scale).rounded(), 1))
    }

    /// Высота к ширине — и окно камеры, и `map` маски берут аспект отсюда:
    /// картинка из целых пикселей, и её аспект — истинный.
    var aspect: CGFloat {
        let pixels = pixelSize
        return pixels.height / pixels.width
    }
}

/// Кадр зеркала: картинка и маска одного кадра камеры. `image == nil` —
/// рендер не удался, `paths == nil` — губ нет (и удержание кончилось).
/// `@unchecked Sendable`: `CGImage` и `CGPath` неизменяемы.
struct LipMirrorFrame: @unchecked Sendable {
    let take: UUID
    let target: LipMirrorTarget
    /// Host-время кадра камеры, с — от него считается латентность показа.
    let host: Double
    let image: CGImage?
    let paths: LipMeshPaths?
}

/// Почтовый ящик кадров «последний побеждает»: `visionQueue` кладёт, главный
/// поток забирает. Очереди кадров нет намеренно: если main не успел, старый
/// кадр показывать незачем — показывается свежий, и зеркало не копит задержку.
///
/// Подписчик один — вью зеркала, — но вью пересоздаётся с панелью, и новая
/// может подписаться раньше, чем старая отпишется: поэтому у подписки
/// владелец, и `update`/`detach` чужую не трогают.
final class LipMirrorFeed: @unchecked Sendable {
    private struct State {
        var target: LipMirrorTarget?
        var owner: UUID?
        var onFrame: (@MainActor (LipMirrorFrame?) -> Void)?
        var take: UUID?
        var latest: LipMirrorFrame?
        var scheduled = false
        /// Латентность показа текущего дубля, с.
        var latencyTake: UUID?
        var latencies: [Double] = []
    }

    private let lock = NSLock()
    private var state = State()

    /// Окно подписчика; nil — окна нет, и зеркало не считается вовсе. С любого потока.
    var target: LipMirrorTarget? {
        lock.withLock { state.target }
    }

    /// Подписать вью. Висящий кадр выбрасывается: он мог быть под чужой размер.
    @MainActor
    func attach(target: LipMirrorTarget, onFrame: @escaping @MainActor (LipMirrorFrame?) -> Void) -> UUID {
        let owner = UUID()
        lock.withLock {
            state.owner = owner
            state.onFrame = onFrame
            state.target = target
            state.latest = nil
        }
        return owner
    }

    /// Новый размер или масштаб окна — только у своей подписки.
    @MainActor
    func update(target: LipMirrorTarget, owner: UUID) {
        lock.withLock {
            guard state.owner == owner else { return }
            state.target = target
        }
    }

    /// Снимает ТОЛЬКО свою подписку: новая вью могла подписаться раньше.
    @MainActor
    func detach(owner: UUID) {
        lock.withLock {
            guard state.owner == owner else { return }
            state.owner = nil
            state.onFrame = nil
            state.target = nil
            state.latest = nil
        }
    }

    /// Начался дубль: кадры прошлого выбрасываются, вью показывает «пусто»,
    /// пока не придёт первый кадр нового — иначе мелькнул бы рот прошлой диктовки.
    @MainActor
    func begin(take: UUID) {
        let onFrame = lock.withLock {
            state.take = take
            state.latest = nil
            state.latencyTake = take
            state.latencies = []
            return state.onFrame
        }
        onFrame?(nil)
    }

    /// Дубль кончился: запоздавшие кадры выбрасываются, последняя картинка
    /// остаётся — панель гаснет с ней, а не с чёрным прямоугольником.
    @MainActor
    func end() {
        lock.withLock {
            state.take = nil
            state.latest = nil
        }
    }

    /// Кадр с `visionQueue`. Кадр чужого дубля — мимо.
    func post(_ frame: LipMirrorFrame) {
        let schedule = lock.withLock {
            guard frame.take == state.take else { return false }
            state.latest = frame
            guard !state.scheduled else { return false }
            state.scheduled = true
            return true
        }
        guard schedule else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.drain() }
        }
    }

    /// Латентность показа дубля (от кадра камеры до передачи вью), мс; nil —
    /// кадров не показано или дубль уже другой. Хранится только у одного
    /// дубля: следующий `begin` её стирает — снимать до него, а не в
    /// завершении записи, которое может прийти уже после старта новой диктовки.
    func latencySummary(take: UUID) -> (count: Int, p50: Double, p95: Double)? {
        let sorted = lock.withLock {
            state.latencyTake == take ? state.latencies : []
        }.sorted()
        guard !sorted.isEmpty else { return nil }
        func percentile(_ p: Double) -> Double {
            sorted[Int((p * Double(sorted.count - 1)).rounded())] * 1000
        }
        return (sorted.count, percentile(0.5), percentile(0.95))
    }

    /// Забрать последний кадр. Отдаётся, только если дубль и окно всё ещё
    /// те же: иначе картинка растянулась бы под чужой размер, а маска
    /// осталась бы в старых точках.
    @MainActor
    private func drain() {
        let delivery: (LipMirrorFrame, @MainActor (LipMirrorFrame?) -> Void)? = lock.withLock {
            let frame = state.latest
            state.latest = nil
            state.scheduled = false
            guard let frame, let onFrame = state.onFrame,
                  frame.take == state.take, frame.target == state.target else { return nil }
            if state.latencyTake == frame.take {
                state.latencies.append(CACurrentMediaTime() - frame.host)
            }
            return (frame, onFrame)
        }
        guard let (frame, onFrame) = delivery else { return }
        onFrame(frame)
    }
}

/// Конвейер зеркала: из образца Vision — маска этого кадра и окно камеры
/// для следующего. Живёт только на `visionQueue`, сам не синхронизирован.
/// Чистая композиция — без CIContext и Vision: рендер и детектор у движка.
///
/// Порядок на кадре: `region` (окно, посчитанное на прошлом кадре) → рендер
/// картинки и Vision параллельно → `update`. Маска кадра идёт через тот же
/// регион, что и его картинка, — поэтому они совпадают, а камера отстаёт
/// ровно на кадр (незаметно: она и так сглажена).
final class LipMirrorPipeline {
    private var take: UUID?
    private var points = LipPointsFilter()
    private var calibrator = LipMeshCalibrator()
    private var camera = LipMirrorCamera()
    private var maskHold = LipMaskHold()
    /// Выход камеры после прошлого кадра — регион следующего.
    private var next: CGRect?

    /// Регион кадра. Новый дубль начинает со сцены и с чистым состоянием.
    func region(take: UUID, camera size: CGSize, target: LipMirrorTarget) -> CGRect {
        if take != self.take {
            self.take = take
            points.reset()
            calibrator.reset()
            camera.reset()
            maskHold.reset()
            next = nil
        }
        camera.reduceMotion = target.reduceMotion
        return next ?? LipMirrorGeometry.sceneRegion(camera: size, aspect: target.aspect)
    }

    /// Маска кадра в точках окна; заодно шаг камеры — регион следующего кадра.
    func update(sample: LipFaceSample, host: Double, camera size: CGSize, region: CGRect,
                target: LipMirrorTarget) -> LipMeshPaths? {
        var mesh: LipMesh?
        var fix: LipMirrorCamera.Fix?
        var lips: CGRect?
        if let box = sample.box, !sample.outerLips.isEmpty, !sample.innerLips.isEmpty {
            let axis = Self.eyeAxis(sample.eyes)
            let raw = sample.outerLips + sample.innerLips
            let filtered = points.filter(raw, at: host, scale: LipPointsFilter.valueScale(faceBox: box))
            let outer = Array(filtered.prefix(sample.outerLips.count))
            let inner = Array(filtered.suffix(sample.innerLips.count))
            if let contours = LipContours.vision(outer: outer, inner: inner, axis: axis) {
                mesh = LipMesh.make(contours, calibration: calibrator.update(contours))
            }
            // Камера — по СЫРЫМ точкам: у неё свой фильтр, медленнее, и
            // двойное сглаживание только добавило бы запаздывания.
            let corners = LipContours.vision(outer: sample.outerLips, inner: sample.innerLips, axis: axis)?
                .outer.corners
            fix = LipMirrorCamera.fix(corners: corners, eyes: sample.eyes, box: box)
            lips = Self.bounds(sample.outerLips)
        }
        // Губ нет — фильтр точек не сбрасывается: одиночный промах он
        // переживает, длинный перезапускает сам (`LipOneEuro.restartAfter`).
        let held = maskHold.update(mesh, at: host)
        next = camera.update(fix, lips: lips, at: host, camera: size, aspect: target.aspect)
        return held.map { mesh in
            LipMeshPaths.make(mesh) {
                LipMirrorGeometry.map($0, region: region, size: target.size, mirrored: true)
            }
        }
    }

    /// Ось глаз слева направо; без двух глаз — горизонталь.
    private static func eyeAxis(_ eyes: [CGPoint]) -> CGVector {
        guard eyes.count == 2 else { return CGVector(dx: 1, dy: 0) }
        let sorted = eyes.sorted { $0.x < $1.x }
        return CGVector(dx: sorted[1].x - sorted[0].x, dy: sorted[1].y - sorted[0].y)
    }

    private static func bounds(_ points: [CGPoint]) -> CGRect {
        let xs = points.map(\.x), ys = points.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return .null }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
