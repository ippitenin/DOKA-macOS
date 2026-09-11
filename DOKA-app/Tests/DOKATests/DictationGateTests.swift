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
}
