import XCTest
@testable import DOKA

/// Сборка решения по дублю из журнала камеры и заказа диктовки.
///
/// Зачем: здесь сходятся все части — прогрев, шкала WAV, кроп, вердикт и
/// поля `meta.json`. Ошибка сшивки (например, кадры не переведены на шкалу
/// WAV или кроп посчитан по лицам вне полезного окна) молча испортит пары.
final class LipTakePlannerTests: XCTestCase {

    /// Диктовка 3 с; камера с хост-времени 100,3 (WAV начался в 100,0), 30 к/с,
    /// лицо 300 px всё время, речь с 0,5 с.
    private func job(quiet: Bool = false, hostStart: Double? = 100.0) -> LipJob {
        LipJob(text: "привет, это проверка", language: "ru", provider: "Nexara", model: "whisper-1",
               historyID: UUID(), date: Date(timeIntervalSince1970: 1_791_115_200), duration: 3.0,
               speechSeconds: 2.0, quietSpeechSeconds: 2.2, quiet: quiet, microphone: "Mic",
               hostStart: hostStart, inputLatency: 0, speechOnset: 0.5, maxClockDrift: 0.001)
    }

    private func log() -> LipCaptureLog {
        let frames = (0..<80).map { i in
            LipCaptureLog.Frame(t: Double(i) / 30, host: 100.3 + Double(i) / 30, luma: 100)
        }
        let faces = stride(from: 0, to: 80, by: 2).map { i in
            LipCaptureLog.Face(host: 100.3 + Double(i) / 30, box: [490, 210, 300, 300], count: 1)
        }
        return LipCaptureLog(frameWidth: 1280, frameHeight: 720, camera: "FaceTime HD Camera",
                             frames: frames, faces: faces, droppedFrames: 1, failed: false,
                             effects: .init(centerStage: false, portrait: false, studioLight: false,
                                            backgroundReplacement: false, reactions: false))
    }

    func testGoodTakeIsPlannedOnWavTimeline() throws {
        let plan = LipTakePlanner.plan(job: job(), log: log())
        // Камера проснулась в 0,3 с, прогрев — ещё 0,2 с: полезное видео с 0,5 с.
        XCTAssertEqual(plan.verdict, .keep(headMissing: false))
        let schedule = try XCTUnwrap(plan.schedule)
        XCTAssertEqual(schedule.sourceIndex.count, 90)
        XCTAssertEqual(schedule.validFrom, 0.5, accuracy: 1e-6)
        XCTAssertEqual(plan.sourcePTS.first ?? -1, 0.2, accuracy: 1e-6)   // метка в raw.mp4
        XCTAssertEqual(plan.crop?.rect, CGRect(x: 296, y: 30, width: 690, height: 690))
        XCTAssertEqual(plan.measuredFps, 30, accuracy: 0.01)
    }

    func testMetaCarriesPlanAndJob() throws {
        let id = UUID()
        let job = job(quiet: true)
        let plan = LipTakePlanner.plan(job: job, log: log())
        let meta = try XCTUnwrap(LipTakePlanner.meta(id: id, job: job, log: log(), plan: plan, appVersion: "t"))
        XCTAssertEqual(meta.id, id)
        XCTAssertEqual(meta.mode, .whisper)
        XCTAssertEqual(meta.text, "привет, это проверка")
        XCTAssertEqual(meta.video.validFrom, plan.schedule?.validFrom)
        XCTAssertEqual(meta.video.cropRect, [296, 30, 690, 690])
        XCTAssertEqual(meta.video.cameraFrame, [1280, 720])
        XCTAssertEqual(meta.video.droppedFrames, 1)
        XCTAssertFalse(meta.video.mirrored)
        XCTAssertEqual(meta.audio.codec, "aac")
        XCTAssertEqual(meta.schemaVersion, LipTakeMeta.currentSchema)
    }

    /// Без хост-времени звука губы не сшить — пара отбрасывается.
    func testMissingAudioClockIsRejected() {
        XCTAssertEqual(LipTakePlanner.plan(job: job(hostStart: nil), log: log()).verdict, .reject(.syncLost))
    }

    /// Камера не дала ни одного кадра.
    func testEmptyCaptureIsCameraFailure() {
        var empty = log()
        empty.frames = []
        empty.faces = []
        XCTAssertEqual(LipTakePlanner.plan(job: job(), log: empty).verdict, .reject(.cameraFailed))
    }
}
