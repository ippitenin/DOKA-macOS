import XCTest
@testable import DOKA

/// Покадровая разметка Nemotron → интервалы говорящих. Ошибка здесь сдвигает
/// границы реплик или показывает пользователю сырой номер слота вместо
/// «Спикер N».
final class SpeakerFramesTests: XCTestCase {

    // MARK: - Говорящий кадра

    /// В каждом кадре говорит один — самый уверенный из тех, кто выше порога;
    /// ниже порога (и ровно на пороге) — тишина.
    func testLabelPicksMostConfidentAboveThreshold() {
        let probabilities: [Float] = [
            0.9, 0.1, 0.0,    // уверенно слот 0
            0.6, 0.8, 0.0,    // наложение: слот 1 увереннее
            0.2, 0.3, 0.4,    // все ниже порога — тишина
            0.5, 0.0, 0.0,    // ровно на пороге — тоже тишина
            0.0, 0.0, 0.51,   // слот 2
        ]
        XCTAssertEqual(SpeakerFrames.labels(probabilities: probabilities, numSpeakers: 3),
                       [0, 1, -1, -1, 2])
    }

    func testLabelsOfEmptyInputAreEmpty() {
        XCTAssertEqual(SpeakerFrames.labels(probabilities: [], numSpeakers: 8), [])
        XCTAssertEqual(SpeakerFrames.labels(probabilities: [0.9], numSpeakers: 0), [])
        XCTAssertEqual(SpeakerFrames.spans(labels: []), [])
    }

    // MARK: - Интервалы

    /// Подряд идущие кадры одного слота — один интервал; тишина интервалов не даёт.
    func testRunsBecomeSpansWithFrameTimes() {
        let labels: [Int8] = Array(repeating: 0, count: 30) + Array(repeating: -1, count: 10)
            + Array(repeating: 1, count: 25)
        let spans = SpeakerFrames.spans(labels: labels)
        XCTAssertEqual(spans.count, 2)
        XCTAssertEqual(spans[0].speaker, "speaker_0")
        XCTAssertEqual(spans[0].start, 0, accuracy: 1e-9)
        XCTAssertEqual(spans[0].end, 0.30, accuracy: 1e-9)
        XCTAssertEqual(spans[1].speaker, "speaker_1")
        XCTAssertEqual(spans[1].start, 0.40, accuracy: 1e-9)
        XCTAssertEqual(spans[1].end, 0.65, accuracy: 1e-9)
    }

    /// Отрезок короче 0,2 с — шум разметки: выбрасывается целиком, а его слова
    /// потом достанутся ближайшему соседу (`SpeakerAssignment`).
    func testRunsShorterThanMinimumAreDropped() {
        let labels: [Int8] = Array(repeating: 0, count: 50)
            + Array(repeating: 1, count: SpeakerFrames.minRunFrames - 1)
            + Array(repeating: 0, count: 50)
            + Array(repeating: 2, count: SpeakerFrames.minRunFrames)
        let spans = SpeakerFrames.spans(labels: labels)
        XCTAssertEqual(spans.map(\.speaker), ["speaker_0", "speaker_0", "speaker_1"],
                       "слот 1 короче минимума выпал, слот 2 ровно на минимуме остался")
    }

    // MARK: - Нумерация

    /// Номер — по первому появлению, а не по номеру слота: иначе цвета и
    /// «Спикер N» шли бы не по ходу записи.
    func testSpeakersAreNumberedByFirstAppearance() {
        let labels: [Int8] = Array(repeating: 5, count: 20) + Array(repeating: 2, count: 20)
            + Array(repeating: 5, count: 20)
        XCTAssertEqual(SpeakerFrames.spans(labels: labels).map(\.speaker),
                       ["speaker_0", "speaker_1", "speaker_0"])
    }

    /// Общая перенумерация и для pyannote (`S1`, `S2`): вход в любом порядке,
    /// выход — по времени.
    func testRemapSortsByStartAndKeepsIdentity() {
        let spans = SpeakerFrames.remapByFirstAppearance([
            ("S2", 5, 6), ("S1", 0, 1), ("S2", 2, 3), ("S1", 7, 8),
        ])
        XCTAssertEqual(spans, [
            SpeakerSpan(speaker: "speaker_0", start: 0, end: 1),
            SpeakerSpan(speaker: "speaker_1", start: 2, end: 3),
            SpeakerSpan(speaker: "speaker_1", start: 5, end: 6),
            SpeakerSpan(speaker: "speaker_0", start: 7, end: 8),
        ])
    }
}
