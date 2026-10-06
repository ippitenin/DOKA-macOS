import XCTest
@testable import DOKA

/// Решение по фразе тренировки до фиксации.
///
/// Зачем: фраза, сказанная вслух, записанная беззвучной парой, учит модель
/// губ не тому режиму; случайное нажатие — пустой дубль. А `speechOnset`
/// пары — это момент подсказки «Говорите»: от него обработка считает,
/// покрыло ли видео фразу (`lateCamera`), и съехавший ноль сломал бы это.
final class LipTrainingCheckTests: XCTestCase {

    func testEachOutcome() {
        XCTAssertEqual(LipTrainingCheck.decide(duration: 0.6, speechSeconds: 0), .tooShort)
        XCTAssertEqual(LipTrainingCheck.decide(duration: 3.2, speechSeconds: 1.4), .voiced)
        XCTAssertEqual(LipTrainingCheck.decide(duration: 3.2, speechSeconds: 0.05), .keep)
        // Короткое нажатие с голосом — всё равно «слишком коротко».
        XCTAssertEqual(LipTrainingCheck.decide(duration: 0.5, speechSeconds: 0.5), .tooShort)
    }

    /// Граница по замеру: беззвучная фраза с щелчками губ и сигналом старта
    /// (до 0,51 + 0,13 с) проходит, самая тихая фраза вслух (1,02 с) — нет.
    func testVoicedThresholdMatchesCalibration() {
        XCTAssertEqual(LipTrainingCheck.decide(duration: 4, speechSeconds: 0.64), .keep)
        XCTAssertEqual(LipTrainingCheck.decide(duration: 4, speechSeconds: LipTrainingCheck.maxVoicedSeconds), .keep)
        XCTAssertEqual(LipTrainingCheck.decide(duration: 4, speechSeconds: 1.02), .voiced)
        XCTAssertEqual(LipTrainingCheck.decide(duration: LipTrainingCheck.minDuration, speechSeconds: 0), .keep)
    }

    /// Подсказка на шкале WAV — с поправкой на задержку входа, не раньше нуля.
    func testOnsetOnWavTimeline() throws {
        let timing = RecordingTiming(hostStart: 100.0, inputLatency: 0.05, speechOnset: nil, maxClockDrift: 0)
        XCTAssertEqual(try XCTUnwrap(LipTrainingCheck.onset(cueHost: 100.85, timing: timing)), 0.9, accuracy: 1e-9)
        XCTAssertEqual(LipTrainingCheck.onset(cueHost: 99.0, timing: timing), 0)
        XCTAssertNil(LipTrainingCheck.onset(cueHost: nil, timing: timing))
        XCTAssertNil(LipTrainingCheck.onset(cueHost: 100.5, timing: nil))
    }

    /// Автостоп — по лимиту фразы WISLIP.
    func testAutoStopLimit() {
        XCTAssertEqual(LipTrainingCheck.maxDuration, 13)
    }
}
