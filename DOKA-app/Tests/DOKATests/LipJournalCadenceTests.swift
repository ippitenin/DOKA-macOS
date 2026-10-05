import XCTest
@testable import DOKA

/// Ритм журнала лица: Vision идёт на каждом кадре, а в `capture.json`
/// попадает примерно каждый второй результат.
///
/// Зачем: журнал — договор с WISLIP и вход кропа дубля. Его частота
/// (~15 Гц при 30 к/с) не должна меняться оттого, что Vision стал работать
/// на каждом кадре ради зеркала: иначе поедут абсолютные счётчики вроде
/// `multiFaceFrames`. Номинал кадра — параметр: камера бывает и на 25 к/с.
final class LipJournalCadenceTests: XCTestCase {
    private let take = UUID()

    /// Номера кадров, чей результат Vision попал в журнал. `skip` — кадры,
    /// которые Vision не взял (был занят), `jitter` — сдвиг метки кадра, с.
    private func admitted(fps: Double, count: Int, skip: Set<Int> = [],
                          jitter: (Int) -> Double = { _ in 0 }) -> [Int] {
        var cadence = LipJournalCadence(frameDuration: 1 / fps)
        return (0..<count).filter { i in
            !skip.contains(i) && cadence.admit(host: 1000 + Double(i) / fps + jitter(i), take: take)
        }
    }

    /// 30 к/с — каждый второй кадр, 15 записей в секунду.
    func testThirtyFpsGivesFifteenHz() {
        let entries = admitted(fps: 30, count: 30)
        XCTAssertEqual(entries, Array(stride(from: 0, to: 30, by: 2)))
        XCTAssertEqual(entries.count, 15)
    }

    /// 25 к/с — тоже каждый второй (12,5 Гц), как прежнее правило чётности.
    func testTwentyFiveFpsKeepsEveryOtherFrame() {
        XCTAssertEqual(admitted(fps: 25, count: 25), Array(stride(from: 0, to: 25, by: 2)))
    }

    /// Метки гуляют на ±8 мс (интервал — на ±16 мс из 40): ритм тот же. С
    /// фиксированным порогом 0,05 с запас при 25 к/с был бы всего 10 мс.
    func testTwentyFiveFpsWithJitter() {
        let entries = admitted(fps: 25, count: 250) { i in 0.008 * sin(Double(i * i) * 0.7) }
        XCTAssertEqual(entries, Array(stride(from: 0, to: 250, by: 2)))
    }

    /// Vision был занят на кадре, который пошёл бы в журнал, — запись даёт
    /// следующий кадр, и дальше ритм идёт от него.
    func testSkippedFrameIsReplacedByNext() {
        XCTAssertEqual(admitted(fps: 30, count: 12, skip: [4]), [0, 2, 5, 7, 9, 11])
    }

    /// 10 с при 30 к/с с живым дрожанием меток — 150 записей, не больше и не меньше.
    func testLongRunCountIsExact() {
        let entries = admitted(fps: 30, count: 300) { i in 0.003 * sin(Double(i) * 1.3) }
        XCTAssertLessThanOrEqual(abs(entries.count - 150), 1)
    }

    /// Новый дубль начинает журнал заново: его первый результат проходит,
    /// даже если прошлый дубль писал миг назад.
    func testNewTakeStartsFresh() {
        var cadence = LipJournalCadence(frameDuration: 1.0 / 30)
        let next = UUID()
        XCTAssertTrue(cadence.admit(host: 1000, take: take))
        XCTAssertTrue(cadence.admit(host: 1000.01, take: next))
        XCTAssertFalse(cadence.admit(host: 1000.02, take: next))
        XCTAssertTrue(cadence.admit(host: 1000.07, take: next))
    }
}
