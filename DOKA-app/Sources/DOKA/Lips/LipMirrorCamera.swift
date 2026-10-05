import CoreGraphics
import Foundation

/// Спокойная камера зеркала губ: какую часть кадра камеры показывать.
/// Координаты — пиксели кадра, начало сверху слева, без зеркала (как у
/// `LipFaceSample`); время — host-секунды кадра.
///
/// Камера держится за ЛИЦО, а не за рот: опора — середина уголков рта, а
/// размер окна — от межглазного расстояния (`fix`). Рот на речи
/// раскрывается и сжимается, межглазное — нет, поэтому окно не «дышит» с
/// каждым слогом. В покое центр и ширина идут через One Euro; въезд из
/// сцены, выезд на сцену и скачок цели — глайдом от ТЕКУЩЕГО окна, так что
/// любое прерывание обходится без рывка.
///
/// Состояние — на `visionQueue` камеры, рядом с конвейером зеркала.
struct LipMirrorCamera {
    /// Окно — `zoom` ширин рта. Решение владельца после живой проверки:
    /// 2,2 было слишком близко, окно на ~23 % шире — рот целиком с запасом.
    static let zoom: CGFloat = 2.7
    /// Ширина рта к межглазному в покое (стенд).
    static let mouthPerEyes: CGFloat = 0.836
    /// Межглазное к высоте бокса детектора: p5 отношения по стенду. Медиана
    /// (0,365) поднимала бы масштаб над межглазным уже анфас, и зум качался
    /// бы от бокса.
    static let kappa: CGFloat = 0.351
    /// Центр окна ниже середины уголков (к подбородку), доля масштаба.
    static let drop: CGFloat = 0.05
    /// Край сырого бокса губ дальше этой доли окна от центра — окно шире.
    static let guardEdge: CGFloat = 0.45
    /// Лица нет дольше, с, — выезд на сцену. Тот же порог у «Лица не видно»
    /// (`LipCapture`).
    static let lostAfter: TimeInterval = 0.5
    /// Длительность въезда, выезда и перескока, с.
    static let glide: TimeInterval = 0.35
    /// Въезд из сцены — только после стольких фиксов подряд…
    static let reacquireFixes = 3
    /// …или стольких секунд фиксов подряд: мигающее лицо камеру не качает.
    static let reacquireTime: TimeInterval = 0.1
    /// Ступенька цели центра за кадр больше этой доли масштаба — глайд, а не
    /// One Euro.
    static let jumpCenter: CGFloat = 0.25
    /// Ступенька масштаба лица за кадр по `|Δ ln|` больше этого — глайд.
    static let jumpLogWidth: CGFloat = 0.10
    /// Центр: скорость — в масштабах лица в секунду.
    static let center = LipOneEuro.Parameters(minCutoff: 0.3, beta: 0.8, derivativeCutoff: 1)
    /// Ширина — по `ln W`: зум воспринимается в долях, а не в пикселях.
    static let width = LipOneEuro.Parameters(minCutoff: 0.1, beta: 0.3, derivativeCutoff: 1)

    /// Опора камеры на одном кадре.
    struct Fix: Equatable {
        /// Куда смотрит центр окна: середина уголков рта, сдвинутая к подбородку.
        let center: CGPoint
        /// Масштаб лица, px: межглазное либо (при повороте головы) доля бокса.
        let scale: CGFloat
    }

    /// Окно до ограничения кадром: центр и логарифм ширины.
    struct Pose: Equatable {
        var center: CGPoint
        var logWidth: CGFloat
    }

    enum Mode: Equatable {
        /// Лица нет — показывается сцена.
        case scene
        case tracking
    }

    private struct Glide {
        let start: Double
        let from: Pose
        /// Точка, которая на глайде остаётся на месте в долях окна.
        let anchor: CGPoint
    }

    /// Reduce Motion: въезды и выезды без глайда.
    var reduceMotion = false
    private(set) var mode = Mode.scene

    private var glideState: Glide?
    private var centerXFilter = LipOneEuro(parameters: Self.center)
    private var centerYFilter = LipOneEuro(parameters: Self.center)
    private var logWidthFilter = LipOneEuro(parameters: Self.width)
    private var filtered: Pose?
    /// Прошлая выходная поза до ограничения кадром — от неё стартует глайд.
    private var output: Pose?
    private var lastFixAt: Double?
    private var lastTarget: Pose?
    private var lastScale: CGFloat = 1
    private var runStart: Double = 0
    private var run = 0

    /// Опора по уголкам рта, центроидам глаз (0 или 2) и боксу детектора.
    /// nil — уголков нет или масштаб взять не из чего.
    static func fix(corners: (left: CGPoint, right: CGPoint)?, eyes: [CGPoint], box: CGRect?) -> Fix? {
        guard let corners else { return nil }
        let m = CGPoint(x: (corners.left.x + corners.right.x) / 2, y: (corners.left.y + corners.right.y) / 2)
        let sorted = eyes.count == 2 ? eyes.sorted { $0.x < $1.x } : []
        let eyeDistance = sorted.isEmpty ? 0 : hypot(sorted[1].x - sorted[0].x, sorted[1].y - sorted[0].y)
        let d: CGFloat
        var normal = CGPoint(x: 0, y: 1)
        // Глаза ближе пикселя — вырожденный случай, как без глаз.
        if eyeDistance >= 1 {
            let e1 = sorted[0], e2 = sorted[1]
            d = eyeDistance
            let u = CGPoint(x: (e2.x - e1.x) / d, y: (e2.y - e1.y) / d)
            normal = CGPoint(x: -u.y, y: u.x)
            // Нормаль — от глаз к рту, как бы ни была наклонена голова.
            let mid = CGPoint(x: (e1.x + e2.x) / 2, y: (e1.y + e2.y) / 2)
            if (m.x - mid.x) * normal.x + (m.y - mid.y) * normal.y < 0 {
                normal = CGPoint(x: -normal.x, y: -normal.y)
            }
        } else if let box {
            // Бокс детектора квадратный: ширина — та же высота.
            d = box.width * kappa
        } else {
            return nil
        }
        let scale = max(d, box.map { kappa * $0.height } ?? d)
        return Fix(center: CGPoint(x: m.x + normal.x * drop * scale, y: m.y + normal.y * drop * scale),
                   scale: scale)
    }

    /// Окно на этом кадре. `lips` — сырой бокс губ: широко открытый рот
    /// раздвигает окно. `aspect` — высота окна к ширине.
    mutating func update(_ fix: Fix?, lips: CGRect?, at t: Double, camera: CGSize, aspect: CGFloat) -> CGRect {
        let scene = LipMirrorGeometry.sceneRegion(camera: camera, aspect: aspect)
        let scenePose = Pose(center: CGPoint(x: scene.midX, y: scene.midY), logWidth: log(scene.width))
        let current = output ?? scenePose

        // 1. Учёт фиксов. Прошлая цель — для ступеньки: сравнивать с
        // отфильтрованной нельзя, отставание фильтра на быстром ровном
        // движении головы само переходит порог, и окно встаёт глайдом за
        // глайдом.
        let previousTarget = lastTarget
        let previousScale = lastScale
        var target: Pose?
        if let fix {
            let pose = Pose(center: fix.center,
                            logWidth: log(Self.windowWidth(for: fix, lips: lips, aspect: aspect)))
            target = pose
            if run == 0 { runStart = t }
            run += 1
            lastFixAt = t
            lastTarget = pose
            lastScale = fix.scale
        } else {
            run = 0
        }

        // 2. Переходы.
        switch mode {
        case .scene:
            if let target, run >= Self.reacquireFixes || t - runStart >= Self.reacquireTime {
                mode = .tracking
                resetFilters()
                startGlide(at: t, from: current, anchor: target.center)
            }
        case .tracking:
            if let lastFixAt, t - lastFixAt >= Self.lostAfter {
                mode = .scene
                startGlide(at: t, from: current, anchor: filtered?.center ?? current.center)
            } else if let target, let fix, let previous = previousTarget,
                      hypot(target.center.x - previous.center.x, target.center.y - previous.center.y)
                        > Self.jumpCenter * fix.scale
                        || abs(log(fix.scale / previousScale)) > Self.jumpLogWidth {
                // Ступенька цели (повторный захват, другое лицо) — глайд, а
                // не рывок One Euro. Ширина — по масштабу лица, без
                // предохранителя: широко открытый рот раздвигает окно через
                // фильтр, а не качает зум глайдами туда-обратно.
                resetFilters()
                startGlide(at: t, from: current, anchor: target.center)
            }
        }

        // 3. Фильтры тикают на каждом кадре, при потере — к удержанной цели.
        if mode == .tracking, let goal = target ?? lastTarget {
            let scale = 1 / Double(max(lastScale, 1))
            filtered = Pose(center: CGPoint(x: centerXFilter.filter(goal.center.x, at: t, scale: scale),
                                            y: centerYFilter.filter(goal.center.y, at: t, scale: scale)),
                            logWidth: logWidthFilter.filter(goal.logWidth, at: t))
        }

        // 4–5. Конец позы и глайд к нему.
        let end = mode == .tracking ? (filtered ?? scenePose) : scenePose
        var pose = end
        if let glide = glideState {
            let x = min(max((t - glide.start) / Self.glide, 0), 1)
            if reduceMotion || x >= 1 {
                glideState = nil
            } else {
                pose = Self.interpolate(glide, to: end, s: CGFloat(x * x * (3 - 2 * x)))
            }
        }
        output = pose
        return Self.clamped(pose, aspect: aspect, camera: camera)
    }

    mutating func reset() {
        mode = .scene
        glideState = nil
        resetFilters()
        filtered = nil
        output = nil
        lastFixAt = nil
        lastTarget = nil
        lastScale = 1
        runStart = 0
        run = 0
    }

    /// Ширина окна под опору: `zoom` ширин рта в покое, шире — если сырой
    /// бокс губ уходит за `guardEdge` окна от центра.
    static func windowWidth(for fix: Fix, lips: CGRect?, aspect: CGFloat) -> CGFloat {
        var width = zoom * mouthPerEyes * fix.scale
        if let lips {
            let c = fix.center
            let needX = max(abs(lips.minX - c.x), abs(lips.maxX - c.x)) / guardEdge
            let needY = max(abs(lips.minY - c.y), abs(lips.maxY - c.y)) / (guardEdge * aspect)
            width = max(width, needX, needY)
        }
        return width
    }

    /// Глайд: ширина — геометрически, а центр так, что якорь плавно
    /// переходит из своего места в старом окне в своё место в новом (в долях
    /// ширины) — рот не уплывает от центра по пути.
    private static func interpolate(_ glide: Glide, to end: Pose, s: CGFloat) -> Pose {
        let logW = glide.from.logWidth + (end.logWidth - glide.from.logWidth) * s
        let w = exp(logW)
        let fromW = exp(glide.from.logWidth), endW = exp(end.logWidth)
        let u0 = CGPoint(x: (glide.anchor.x - glide.from.center.x) / fromW,
                         y: (glide.anchor.y - glide.from.center.y) / fromW)
        let u1 = CGPoint(x: (glide.anchor.x - end.center.x) / endW, y: (glide.anchor.y - end.center.y) / endW)
        return Pose(center: CGPoint(x: glide.anchor.x - w * (u0.x + (u1.x - u0.x) * s),
                                    y: glide.anchor.y - w * (u0.y + (u1.y - u0.y) * s)),
                    logWidth: logW)
    }

    /// Прямоугольник окна внутри кадра. Только на выходе: в фильтры и
    /// глайды ограничение не возвращается, иначе лицо у края тянуло бы
    /// камеру рывками.
    private static func clamped(_ pose: Pose, aspect: CGFloat, camera: CGSize) -> CGRect {
        var w = exp(pose.logWidth)
        if w > camera.width { w = camera.width }
        if w * aspect > camera.height { w = camera.height / aspect }
        let h = w * aspect
        let x = min(max(pose.center.x - w / 2, 0), camera.width - w)
        let y = min(max(pose.center.y - h / 2, 0), camera.height - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    private mutating func startGlide(at t: Double, from: Pose, anchor: CGPoint) {
        glideState = reduceMotion ? nil : Glide(start: t, from: from, anchor: anchor)
    }

    private mutating func resetFilters() {
        centerXFilter.reset()
        centerYFilter.reset()
        logWidthFilter.reset()
    }
}

/// Сетка губ переживает одиночные промахи Vision: без неё маска мигала бы.
/// Сетка — в пикселях КАМЕРЫ, поэтому удержанная показывается через текущее
/// окно и едет вместе с ним.
struct LipMaskHold {
    /// Дольше, с, — маска гаснет.
    static let hold: TimeInterval = 0.15

    private var stored: (mesh: LipMesh, time: Double)?

    mutating func update(_ mesh: LipMesh?, at t: Double) -> LipMesh? {
        if let mesh {
            stored = (mesh, t)
            return mesh
        }
        guard let stored, t - stored.time <= Self.hold else {
            stored = nil
            return nil
        }
        return stored.mesh
    }

    mutating func reset() { stored = nil }
}
