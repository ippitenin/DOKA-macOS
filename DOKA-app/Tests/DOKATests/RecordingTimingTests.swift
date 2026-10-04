import XCTest
@testable import DOKA

/// Метки времени записи для синхронизации с камерой (эксперимент «Губы»).
///
/// Зачем: видео губ сшивается с WAV по хост-времени. Если начало речи
/// поймает сигнал старта «Pop» (на тихом пороге он даёт 0,06–0,13 с «речи»),
/// пара будет посчитана «камера не успела», хотя человек ещё молчал. Если
/// пропуск буфера аудиодвижком не заметить, «индекс сэмпла = время» перестаёт
/// быть правдой и губы разъедутся со звуком.
final class RecordingTimingTests: XCTestCase {

    /// Буфер tap: 1024 кадра при 48 кГц.
    private let step = 1024.0 / 48_000

    // MARK: - Начало речи

    /// Короткий всплеск в первые 0,2 с — это сигнал старта, а не речь.
    func testOnsetIgnoresStartCue() {
        var tracker = SpeechOnsetTracker()
        for i in 0..<6 { tracker.feed(isSpeech: true, at: Double(i) * step) }   // 0…0,1 с
        for i in 6..<40 { tracker.feed(isSpeech: false, at: Double(i) * step) }
        XCTAssertNil(tracker.onset)
        for i in 50..<56 { tracker.feed(isSpeech: true, at: Double(i) * step) }
        XCTAssertEqual(tracker.onset ?? -1, 50 * step, accuracy: 1e-9)
    }

    /// Нужны три буфера речи подряд; одиночный щелчок не в счёт.
    func testOnsetNeedsThreeConsecutiveBuffers() {
        var tracker = SpeechOnsetTracker()
        tracker.feed(isSpeech: true, at: 0.50)
        tracker.feed(isSpeech: false, at: 0.50 + step)
        tracker.feed(isSpeech: true, at: 0.60)
        tracker.feed(isSpeech: true, at: 0.60 + step)
        XCTAssertNil(tracker.onset)
        tracker.feed(isSpeech: true, at: 0.60 + 2 * step)
        XCTAssertEqual(tracker.onset ?? -1, 0.60, accuracy: 1e-9)
    }

    /// Начало фиксируется один раз и потом не сдвигается.
    func testOnsetIsStickyOnceFound() {
        var tracker = SpeechOnsetTracker()
        for i in 0..<3 { tracker.feed(isSpeech: true, at: 1.0 + Double(i) * step) }
        for i in 0..<3 { tracker.feed(isSpeech: true, at: 5.0 + Double(i) * step) }
        XCTAssertEqual(tracker.onset ?? -1, 1.0, accuracy: 1e-9)
    }

    func testOnsetIsNilWithoutSpeech() {
        var tracker = SpeechOnsetTracker()
        for i in 0..<100 { tracker.feed(isSpeech: false, at: Double(i) * step) }
        XCTAssertNil(tracker.onset)
    }

    // MARK: - Дрейф хост-часов

    /// Ровный поток буферов: хост-время каждого = старт + накопленный звук.
    func testDriftIsZeroOnSteadyStream() {
        var tracker = HostClockDriftTracker()
        for i in 0..<200 { tracker.feed(host: 1000 + Double(i) * step, elapsed: Double(i) * step) }
        XCTAssertEqual(tracker.hostStart, 1000)
        XCTAssertEqual(tracker.maxDrift, 0, accuracy: 1e-9)
    }

    /// Движок пропустил буфер: хост-время ушло вперёд на 21 мс, а сэмплов
    /// в файле на столько же меньше — дрейф обязан это показать.
    func testDriftCatchesSkippedBuffer() {
        var tracker = HostClockDriftTracker()
        for i in 0..<10 { tracker.feed(host: 1000 + Double(i) * step, elapsed: Double(i) * step) }
        // Буфер №10 потерян: следующий приходит с хост-временем №11.
        for i in 10..<20 { tracker.feed(host: 1000 + Double(i + 1) * step, elapsed: Double(i) * step) }
        XCTAssertEqual(tracker.maxDrift, step, accuracy: 1e-9)
    }
}
