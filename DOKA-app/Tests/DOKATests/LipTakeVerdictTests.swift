import XCTest
@testable import DOKA

/// Решение по дублю губ: оставить пару или отбросить с понятной причиной.
///
/// Зачем: плохая пара хуже отсутствующей — модель учится на шуме. Но и
/// выбрасывать лишнее нельзя: камера холодная почти в каждом дубле, и
/// правило «речь началась раньше первого кадра → отброс» съело бы бо́льшую
/// часть длинных диктовок.
final class LipTakeVerdictTests: XCTestCase {

    /// Хороший дубль: 10 с, лицо всё время, камера с 0,3 с, речь с 0,8 с.
    private func facts(_ change: (inout LipTakeFacts) -> Void = { _ in }) -> LipTakeFacts {
        var f = LipTakeFacts(
            text: "Привет, это проверка",
            cameraFailed: false,
            measuredFps: 30,
            timingKnown: true,
            maxClockDrift: 0.002,
            duration: 10,
            speechOnset: 0.8,
            validFrom: 0.3,
            validTo: 10,
            faceSamples: stride(from: 0.3, to: 10, by: 1.0 / 15).map { LipFaceMark(t: $0, lipsVisible: true) },
            faceInOutputPx: 200)
        change(&f)
        return f
    }

    func testGoodTakeIsKept() {
        XCTAssertEqual(LipTakeVerdict.decide(facts()), .keep(headMissing: false))
    }

    /// Камера проснулась после начала речи — пару оставляем, но считаем.
    func testLateCameraHeadIsKeptAndCounted() {
        XCTAssertEqual(LipTakeVerdict.decide(facts { $0.validFrom = 1.5 }), .keep(headMissing: true))
    }

    func testEmptyTextIsRejected() {
        XCTAssertEqual(LipTakeVerdict.decide(facts { $0.text = "  \n" }), .reject(.emptyText))
    }

    func testCameraFailureIsRejected() {
        XCTAssertEqual(LipTakeVerdict.decide(facts { $0.cameraFailed = true }), .reject(.cameraFailed))
    }

    func testLostClockIsRejected() {
        XCTAssertEqual(LipTakeVerdict.decide(facts { $0.timingKnown = false }), .reject(.syncLost))
        XCTAssertEqual(LipTakeVerdict.decide(facts { $0.maxClockDrift = 0.05 }), .reject(.syncLost))
    }

    func testLowFrameRateIsRejected() {
        XCTAssertEqual(LipTakeVerdict.decide(facts { $0.measuredFps = 15 }), .reject(.lowFps))
    }

    /// Лицо было в кадре меньше половины времени — пара не годится.
    func testMissingFaceIsRejected() {
        let rejected = LipTakeVerdict.decide(facts {
            $0.faceSamples = $0.faceSamples.enumerated().map { LipFaceMark(t: $1.t, lipsVisible: $0 % 3 == 0) }
        })
        XCTAssertEqual(rejected, .reject(.noLips))
    }

    /// Полезного видео меньше полутора секунд, хотя лицо было всё время —
    /// это «слишком коротко», а не «лица не видно»: иначе владелец чинил бы
    /// свет вместо длины фразы.
    func testTooLittleUsefulVideoIsRejected() {
        let rejected = LipTakeVerdict.decide(facts {
            $0.duration = 1.2; $0.validTo = 1.2; $0.speechOnset = 0.3
            $0.faceSamples = $0.faceSamples.filter { $0.t < 1.2 }
        })
        XCTAssertEqual(rejected, .reject(.tooShort))
    }

    /// Окно видео длинное, но лицо в кадре меньше половины времени — «лица не видно».
    func testShortFaceTimeInLongWindowIsNoFace() {
        let rejected = LipTakeVerdict.decide(facts {
            $0.faceSamples = $0.faceSamples.map { LipFaceMark(t: $0.t, lipsVisible: $0.t < 2.0) }
        })
        XCTAssertEqual(rejected, .reject(.noLips))
    }

    func testSmallFaceIsRejected() {
        XCTAssertEqual(LipTakeVerdict.decide(facts { $0.faceInOutputPx = 90 }), .reject(.faceTooSmall))
    }

    /// Видео покрывает меньше половины речи.
    func testVeryLateCameraIsRejected() {
        let rejected = LipTakeVerdict.decide(facts {
            $0.validFrom = 6
            $0.faceSamples = $0.faceSamples.filter { $0.t >= 6 }
        })
        XCTAssertEqual(rejected, .reject(.lateCamera))
    }

    // MARK: - Лицо по времени

    /// Пропуски лица дольше 0,2 с попадают в `faceGaps` — импортёр WISLIP
    /// не режет фразы через них.
    func testFaceGaps() {
        var samples = stride(from: 0.0, to: 4.0, by: 1.0 / 15).map { LipFaceMark(t: $0, lipsVisible: true) }
        for i in samples.indices where samples[i].t >= 1.0 && samples[i].t < 1.6 { samples[i].lipsVisible = false }
        for i in samples.indices where samples[i].t >= 2.0 && samples[i].t < 2.1 { samples[i].lipsVisible = false }
        let gaps = LipTakeVerdict.faceGaps(samples, validFrom: 0, validTo: 4)
        XCTAssertEqual(gaps.count, 1)
        XCTAssertEqual(gaps[0][0], 1.0, accuracy: 0.07)
        XCTAssertEqual(gaps[0][1], 1.6, accuracy: 0.07)
    }

    func testFaceCoverageCountsOnlyValidWindow() {
        let samples = [LipFaceMark(t: 0.1, lipsVisible: false), LipFaceMark(t: 0.5, lipsVisible: true),
                       LipFaceMark(t: 0.9, lipsVisible: true)]
        XCTAssertEqual(LipTakeVerdict.faceCoverage(samples, validFrom: 0.3, validTo: 1.0), 1.0, accuracy: 1e-9)
    }
}
