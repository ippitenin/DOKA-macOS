import XCTest
@testable import DOKA

/// Синхронизация видео губ с WAV диктовки: отсечение прогрева камеры.
///
/// Зачем: первые кадры холодной камеры — скачок экспозиции. Трекер лиц
/// WISLIP рвёт трек на резкой «смене сцены», поэтому полезное видео
/// начинается с кадра, после которого яркость стабильна.
final class LipSyncTests: XCTestCase {

    private func times(_ count: Int, fps: Double = 30) -> [Double] {
        (0..<count).map { Double($0) / fps }
    }

    // MARK: - Прогрев

    /// Экспозиция растёт полсекунды, потом стоит — полезное видео с плато.
    func testStableStartSkipsExposureRamp() {
        let t = times(60)
        let lumas = t.map { $0 < 0.5 ? $0 * 200 : 120 }   // рампа 0…100, затем 120
        let index = LipSync.stableStart(times: t, lumas: lumas)
        XCTAssertEqual(index, 15)                           // t = 0,5 с
    }

    /// Камера сразу стабильна — всё равно не раньше 0,2 с.
    func testStableStartIsNotEarlierThanMinimum() {
        let t = times(60)
        let index = LipSync.stableStart(times: t, lumas: t.map { _ in 100 })
        XCTAssertEqual(index, 6)                            // t = 0,2 с
    }

    /// Яркость так и не успокоилась — не позже 1,0 с, иначе потеряли бы весь дубль.
    func testStableStartIsCappedAtMaximum() {
        let t = times(90)
        let lumas = t.indices.map { $0.isMultiple(of: 2) ? 80.0 : 110.0 }
        XCTAssertEqual(LipSync.stableStart(times: t, lumas: lumas), 30)   // t = 1,0 с
    }

    /// Короткий клип без стабильного участка — полезного видео нет.
    func testStableStartIsNilWhenNothingUsable() {
        XCTAssertNil(LipSync.stableStart(times: [], lumas: []))
        let t = times(5)                                    // 0…0,13 с
        XCTAssertNil(LipSync.stableStart(times: t, lumas: t.map { _ in 100 }))
    }

    // MARK: - Шкала WAV

    /// Хост-время кадра переводится на шкалу WAV с поправкой на задержку
    /// входа: у Bluetooth-микрофона звук буфера прозвучал раньше его метки.
    func testWavTimesSubtractInputLatency() {
        let timing = RecordingTiming(hostStart: 100.2, inputLatency: 0.2, speechOnset: nil, maxClockDrift: 0)
        let t = LipSync.wavTimes(hosts: [100.0, 100.5, 101.0], timing: timing)
        XCTAssertEqual(t[0], 0, accuracy: 1e-9)
        XCTAssertEqual(t[1], 0.5, accuracy: 1e-9)
        XCTAssertEqual(t[2], 1.0, accuracy: 1e-9)
    }

    // MARK: - Расписание выходных кадров

    /// Ровные 30 к/с по шкале WAV — каждый выходной кадр берёт свой исходный.
    func testScheduleIsIdentityOnSteadyStream() throws {
        let schedule = try XCTUnwrap(LipSync.schedule(times: times(90), duration: 3.0))
        XCTAssertEqual(schedule.sourceIndex, Array(0..<90))
        XCTAssertEqual(schedule.validFrom, 0, accuracy: 1e-9)
        XCTAssertEqual(schedule.validTo, 3.0, accuracy: 1e-6)
    }

    /// Камера уронила два кадра — дыру закрывают соседние, файл остаётся CFR.
    func testScheduleFillsDroppedFrames() throws {
        var t = times(90)
        t.removeSubrange(10...11)
        let schedule = try XCTUnwrap(LipSync.schedule(times: t, duration: 3.0))
        XCTAssertEqual(schedule.sourceIndex.count, 90)
        XCTAssertEqual(schedule.sourceIndex[9], 9)
        XCTAssertTrue([9, 10].contains(schedule.sourceIndex[10]))   // 10 — бывший кадр 12
        XCTAssertEqual(schedule.sourceIndex[12], 10)
        XCTAssertEqual(schedule.sourceIndex, schedule.sourceIndex.sorted())
    }

    /// Камера в темноте отдаёт 15 к/с — каждый кадр повторяется дважды.
    func testScheduleDuplicatesHalfRateSource() throws {
        let schedule = try XCTUnwrap(LipSync.schedule(times: times(30, fps: 15), duration: 2.0))
        XCTAssertEqual(schedule.sourceIndex.count, 60)
        XCTAssertEqual(Set(schedule.sourceIndex).count, 30)
    }

    /// Дрожание меток ±5 мс расписание не ломает.
    func testScheduleToleratesJitter() throws {
        let t = times(90).enumerated().map { $0.element + ($0.offset.isMultiple(of: 2) ? 0.005 : -0.005) }
        let schedule = try XCTUnwrap(LipSync.schedule(times: t, duration: 3.0))
        XCTAssertEqual(schedule.sourceIndex, Array(0..<90))
    }

    /// Камера проснулась через полсекунды после микрофона: голова клипа —
    /// повтор первого кадра, а `validFrom` честно говорит, где видео настоящее.
    func testSchedulePadsHeadWhenCameraIsLate() throws {
        let t = times(45).map { $0 + 0.5 }
        let schedule = try XCTUnwrap(LipSync.schedule(times: t, duration: 2.0))
        XCTAssertEqual(schedule.sourceIndex.count, 60)
        XCTAssertEqual(Array(schedule.sourceIndex.prefix(15)), Array(repeating: 0, count: 15))
        XCTAssertEqual(schedule.validFrom, 0.5, accuracy: 1e-9)
    }

    /// Видео кончилось раньше звука — хвост повторяет последний кадр.
    func testSchedulePadsTail() throws {
        let schedule = try XCTUnwrap(LipSync.schedule(times: times(45), duration: 2.0))
        XCTAssertEqual(schedule.sourceIndex.last, 44)
        XCTAssertEqual(schedule.validTo, 44.0 / 30 + 1.0 / 30, accuracy: 1e-9)
    }

    func testScheduleIsNilWithoutFrames() {
        XCTAssertNil(LipSync.schedule(times: [], duration: 2.0))
    }

    /// Фактическая частота — по меткам кадров, а не по заявке камеры.
    func testMeasuredFps() {
        XCTAssertEqual(LipSync.measuredFps(times: times(91)), 30, accuracy: 1e-9)
        XCTAssertEqual(LipSync.measuredFps(times: times(46, fps: 15)), 15, accuracy: 1e-9)
        XCTAssertEqual(LipSync.measuredFps(times: [0.5]), 0)
    }

    // MARK: - Журнал захвата

    /// `capture.json` переживает перезапуск приложения: обработчик читает его
    /// после старта, если дубль не успели закодировать.
    func testCaptureLogRoundTrips() throws {
        let log = LipCaptureLog(
            frameWidth: 1280, frameHeight: 720, camera: "FaceTime HD Camera",
            frames: [.init(t: 0, host: 100.0, luma: 90), .init(t: 1.0 / 30, host: 100.0 + 1.0 / 30, luma: 91)],
            faces: [.init(host: 100.0, box: [400, 100, 300, 300], count: 1),
                    .init(host: 100.07, box: nil, count: 0)],
            droppedFrames: 2, failed: false,
            effects: .init(centerStage: false, portrait: true, studioLight: false,
                           backgroundReplacement: false, reactions: false))
        let data = try JSONEncoder().encode(log)
        XCTAssertEqual(try JSONDecoder().decode(LipCaptureLog.self, from: data), log)
    }
}
