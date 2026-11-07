import XCTest
@testable import DOKA

/// Гейт решает, уйдёт ли запись на платное распознавание: ошибка в одну
/// сторону тратит деньги на тишину, в другую — теряет диктовку.
final class DictationGateTests: XCTestCase {

    func testShortRecordingIsDropped() {
        XCTAssertEqual(DictationGate.decide(duration: 0.3, speechDuration: 0.3, speechGateEnabled: true),
                       .tooShort)
    }

    func testShortRecordingIsDroppedEvenWithGateOff() {
        XCTAssertEqual(DictationGate.decide(duration: 0.39, speechDuration: 0, speechGateEnabled: false),
                       .tooShort)
    }

    func testSilenceIsNotSent() {
        XCTAssertEqual(DictationGate.decide(duration: 2.0, speechDuration: 0.0, speechGateEnabled: true),
                       .noSpeech)
    }

    func testSpeechBelowThresholdIsNotSent() {
        XCTAssertEqual(DictationGate.decide(duration: 2.0, speechDuration: 0.24, speechGateEnabled: true),
                       .noSpeech)
    }

    func testSpeechAtThresholdIsSent() {
        XCTAssertEqual(DictationGate.decide(duration: 2.0, speechDuration: 0.25, speechGateEnabled: true),
                       .transcribe)
    }

    func testGateOffSendsSilence() {
        XCTAssertEqual(DictationGate.decide(duration: 2.0, speechDuration: 0.0, speechGateEnabled: false),
                       .transcribe)
    }

    /// Короткие отсевы — не диктовка, повторять нечего; длинные — возможно,
    /// тихий голос: их можно распознать всё равно.
    func testOnlyLongGatedRecordingsAreRetryable() {
        XCTAssertFalse(DictationGate.isRetryable(duration: 0.9))
        XCTAssertTrue(DictationGate.isRetryable(duration: 1.0))
    }

    // MARK: - Запасной путь (тихий микрофон)

    /// Регрессия 7.11.2026: громкость входа 29 %, короткая фраза набрала по −40
    /// меньше порога, но по −48 речь отчётливо есть.
    func testShortQuietPhrasePassesByFallback() {
        XCTAssertEqual(DictationGate.decide(duration: 2.0, speechDuration: 0.1,
                                            fallbackSpeechDuration: 0.8, speechGateEnabled: true),
                       .transcribe)
    }

    /// Тишина комнаты на −48 — 0,7 % записи: на минуте набирается 0,45 с,
    /// но до доли 5 % ей далеко.
    func testLongSilenceDoesNotPassByFallback() {
        XCTAssertEqual(DictationGate.decide(duration: 60, speechDuration: 0,
                                            fallbackSpeechDuration: 0.45, speechGateEnabled: true),
                       .noSpeech)
    }

    func testFallbackNeedsMinimumSpeech() {
        XCTAssertEqual(DictationGate.decide(duration: 1.0, speechDuration: 0,
                                            fallbackSpeechDuration: 0.2, speechGateEnabled: true),
                       .noSpeech)
    }

    func testFallbackDoesNotBypassTooShort() {
        XCTAssertEqual(DictationGate.decide(duration: 0.3, speechDuration: 0,
                                            fallbackSpeechDuration: 0.3, speechGateEnabled: true),
                       .tooShort)
    }

    // MARK: - Подсказка о тихом входе

    func testLowInputWithoutBoostExplainsCause() {
        XCTAssertEqual(DictationGate.noSpeechMessage(inputVolume: 0.29, boostEnabled: false, quiet: false),
                       .lowInput(percent: 29))
    }

    func testPlainMessageWhenInputIsNotTheCause() {
        XCTAssertEqual(DictationGate.noSpeechMessage(inputVolume: 0.29, boostEnabled: true, quiet: false), .plain)
        XCTAssertEqual(DictationGate.noSpeechMessage(inputVolume: 0.29, boostEnabled: false, quiet: true), .plain)
        XCTAssertEqual(DictationGate.noSpeechMessage(inputVolume: 0.8, boostEnabled: false, quiet: false), .plain)
        XCTAssertEqual(DictationGate.noSpeechMessage(inputVolume: nil, boostEnabled: false, quiet: false), .plain)
    }
}
