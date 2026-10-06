import CoreGraphics
import Foundation

/// План обработки дубля: из журнала камеры (`capture.json`) и заказа
/// диктовки (`job.json`) — решение, расписание кадров, кроп и поля
/// `meta.json`. Чистая логика: здесь сходятся прогрев, шкала WAV, кроп и
/// вердикт, и всё это проверяется тестами без камеры.
enum LipTakePlanner {
    struct Plan {
        let verdict: LipTakeVerdict
        /// nil — полезных кадров нет.
        let schedule: LipSchedule?
        /// Метки полезных кадров в `raw.mp4`, по индексам расписания.
        let sourcePTS: [Double]
        let crop: LipCropPlanner.Plan?
        let faceCoverage: Double
        let faceGaps: [[Double]]
        let measuredFps: Double
        let multiFaceFrames: Int
    }

    static func plan(job: LipJob, log: LipCaptureLog) -> Plan {
        let timing = job.timing
        // Полезные кадры — после прогрева экспозиции.
        let frames = log.frames
        let stable = LipSync.stableStart(times: frames.map(\.t), lumas: frames.map(\.luma))
        let valid = stable.map { Array(frames[$0...]) } ?? []
        let wavTimes = timing.map { LipSync.wavTimes(hosts: valid.map(\.host), timing: $0) } ?? []
        let schedule = LipSync.schedule(times: wavTimes, duration: job.duration)
        let validFrom = schedule?.validFrom ?? 0
        let validTo = schedule?.validTo ?? 0

        // Лицо — на той же шкале WAV. Отметка «хорошая», только если губы
        // видны: закрытые ладонью губы — такая же дыра, как пропуск лица.
        // Кроп — по всем боксам: закрытый рот лицо не двигает.
        let faceTimes = timing.map { LipSync.wavTimes(hosts: log.faces.map(\.host), timing: $0) } ?? []
        let marks = zip(faceTimes, log.faces).map {
            LipFaceMark(t: $0, lipsVisible: $1.box != nil && $1.lipsHidden != true)
        }
        let boxes: [CGRect] = zip(faceTimes, log.faces).compactMap { t, face in
            guard t >= validFrom, t <= validTo, let b = face.box, b.count == 4 else { return nil }
            return CGRect(x: b[0], y: b[1], width: b[2], height: b[3])
        }
        let crop = LipCropPlanner.plan(faces: boxes,
                                       frame: CGSize(width: log.frameWidth, height: log.frameHeight))
        let fps = LipSync.measuredFps(times: valid.map(\.t))

        let facts = LipTakeFacts(
            text: job.text,
            // Сбой камеры — только по кадрам: без хост-времени звука
            // расписания тоже нет, но это «синхронизация», а не камера.
            cameraFailed: log.failed || valid.isEmpty,
            measuredFps: fps,
            timingKnown: timing != nil,
            maxClockDrift: job.maxClockDrift,
            duration: job.duration,
            speechOnset: job.speechOnset,
            validFrom: validFrom,
            validTo: validTo,
            faceSamples: marks,
            faceInOutputPx: crop?.faceInOutputPx ?? 0)
        var verdict = LipTakeVerdict.decide(facts)
        if case .keep = verdict, crop == nil { verdict = .reject(.noLips) }

        return Plan(verdict: verdict, schedule: schedule, sourcePTS: valid.map(\.t), crop: crop,
                    faceCoverage: LipTakeVerdict.faceCoverage(marks, validFrom: validFrom, validTo: validTo),
                    faceGaps: LipTakeVerdict.faceGaps(marks, validFrom: validFrom, validTo: validTo),
                    measuredFps: fps,
                    multiFaceFrames: log.faces.filter { $0.count > 1 }.count)
    }

    /// Поля `meta.json` оставленной пары; nil — пары нет (отброшена).
    static func meta(id: UUID, job: LipJob, log: LipCaptureLog, plan: Plan, appVersion: String) -> LipTakeMeta? {
        guard case .keep = plan.verdict, let schedule = plan.schedule, let crop = plan.crop else { return nil }
        let side = Int(LipCropPlanner.outputSide)
        let r = crop.rect
        return LipTakeMeta(
            schemaVersion: LipTakeMeta.currentSchema,
            id: id,
            date: job.date,
            source: "dictation",
            mode: LipMode(quiet: job.quiet),
            text: job.text,
            language: job.language,
            provider: job.provider,
            model: job.model,
            historyID: job.historyID,
            duration: job.duration,
            speechSeconds: job.speechSeconds,
            quietSpeechSeconds: job.quietSpeechSeconds,
            speechOnset: job.speechOnset,
            quiet: job.quiet,
            video: .init(width: side, height: side, fps: Int(LipSync.outputFps),
                         validFrom: schedule.validFrom, validTo: schedule.validTo,
                         faceCoverage: plan.faceCoverage, faceGaps: plan.faceGaps,
                         cropRect: [Int(r.minX), Int(r.minY), Int(r.width), Int(r.height)],
                         cameraFrame: [log.frameWidth, log.frameHeight],
                         camera: log.camera, measuredFps: plan.measuredFps,
                         droppedFrames: log.droppedFrames, multiFaceFrames: plan.multiFaceFrames,
                         mirrored: false, effects: log.effects),
            audio: .init(sampleRate: WavWriter.sampleRate, codec: "aac", inputLatency: job.inputLatency,
                         maxClockDrift: job.maxClockDrift, microphone: job.microphone),
            appVersion: appVersion)
    }
}
