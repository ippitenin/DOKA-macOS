import XCTest
@testable import DOKA

/// Тихий режим: шёпот должен проходить гейт тишины, тишина комнаты — нет,
/// а статистика скорости речи — не портиться шёпотом. Уровни взяты из
/// замера реальных записей (см. комментарий `SpeechMeter.quietThresholdDb`).
final class SpeechMeterTests: XCTestCase {

    /// Детерминированный шум с заданным RMS (дБFS): равномерное распределение
    /// на [-a, a] имеет RMS a/√3.
    private func noise(db: Float, seconds: Double, sampleRate: Double = 48_000) -> [Float] {
        let amplitude = pow(10, db / 20) * sqrt(3)
        var state: UInt32 = 12_345
        return (0..<Int(seconds * sampleRate)).map { _ in
            state = state &* 1_664_525 &+ 1_013_904_223
            return (Float(state) / Float(UInt32.max) * 2 - 1) * amplitude
        }
    }

    private func dictation(quiet: Bool, speech: TimeInterval, quietSpeech: TimeInterval) -> RecordedDictation {
        RecordedDictation(url: URL(fileURLWithPath: "/tmp/x.wav"), duration: 3, speechDuration: speech,
                          microphone: nil, quiet: quiet, quietSpeechDuration: quietSpeech)
    }

    func testThresholdsAreStable() {
        XCTAssertEqual(SpeechMeter.standardThresholdDb, -40)
        XCTAssertEqual(SpeechMeter.quietThresholdDb, -48)
        XCTAssertEqual(SpeechMeter.quietDisplayGain, 4)
    }

    /// Обычный порог −40 дБFS — то же, что 0.2 на старой кривой (db+50)/50,
    /// по которой считает `AudioRecorder` (на ней калиброван дашборд).
    func testStandardThresholdMatchesRecorderCurve() {
        XCTAssertEqual((SpeechMeter.standardThresholdDb + 50) / 50,
                       AudioRecorder.speechLevelThreshold, accuracy: 1e-6)
    }

    /// Шёпот (−45 дБFS) обычный гейт не слышит, тихий — слышит.
    func testWhisperCountsOnlyInQuietMode() {
        let m = SpeechMeter.measure(samples: noise(db: -45, seconds: 2), sampleRate: 48_000)
        XCTAssertLessThan(m.standard, DictationGate.minSpeechDuration)
        XCTAssertEqual(m.quiet, 2, accuracy: 0.05)

        let normal = dictation(quiet: false, speech: m.standard, quietSpeech: m.quiet)
        let quiet = dictation(quiet: true, speech: m.standard, quietSpeech: m.quiet)
        XCTAssertEqual(DictationGate.decide(duration: 2, speechDuration: normal.gateSpeechDuration,
                                            speechGateEnabled: true), .noSpeech)
        XCTAssertEqual(DictationGate.decide(duration: 2, speechDuration: quiet.gateSpeechDuration,
                                            speechGateEnabled: true), .transcribe)
    }

    /// Тишина комнаты (−55 дБFS) не проходит гейт и в тихом режиме.
    func testRoomSilenceIsDroppedInQuietMode() {
        let m = SpeechMeter.measure(samples: noise(db: -55, seconds: 3), sampleRate: 48_000)
        XCTAssertEqual(m.standard, 0)
        XCTAssertEqual(m.quiet, 0)
        let quiet = dictation(quiet: true, speech: m.standard, quietSpeech: m.quiet)
        XCTAssertEqual(DictationGate.decide(duration: 3, speechDuration: quiet.gateSpeechDuration,
                                            speechGateEnabled: true), .noSpeech)
    }

    /// Обычный голос (−30 дБFS) слышен в обоих режимах.
    func testVoiceCountsInBothModes() {
        let m = SpeechMeter.measure(samples: noise(db: -30, seconds: 1), sampleRate: 48_000)
        XCTAssertEqual(m.standard, 1, accuracy: 0.05)
        XCTAssertEqual(m.quiet, 1, accuracy: 0.05)
    }

    /// Время выше тихого порога — лишь доля шёпота: в «Скорость речи» такая
    /// запись не идёт (nil → StatsStore получает 0 и агрегаты скорости не трогает).
    func testQuietDictationIsExcludedFromSpeechStats() {
        let quiet = dictation(quiet: true, speech: 0.1, quietSpeech: 1.4)
        XCTAssertEqual(quiet.gateSpeechDuration, 1.4)
        XCTAssertNil(quiet.statsSpeechDuration)

        let normal = dictation(quiet: false, speech: 1.2, quietSpeech: 1.6)
        XCTAssertEqual(normal.gateSpeechDuration, 1.2)
        XCTAssertEqual(normal.statsSpeechDuration, 1.2)
    }
}
