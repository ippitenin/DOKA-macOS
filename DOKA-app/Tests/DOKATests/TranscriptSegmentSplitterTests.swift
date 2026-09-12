import XCTest
@testable import DOKA

/// Нарезка длинных сегментов по границам предложений. Работает локально,
/// поэтому смена детализации на готовом результате обязана быть идемпотентной
/// и никогда не терять слова.
final class TranscriptSegmentSplitterTests: XCTestCase {

    private func word(_ text: String, _ start: Double, _ end: Double) -> TranscriptWord {
        TranscriptWord(text: text, start: start, end: end)
    }

    private func segment(_ text: String, _ start: Double, _ end: Double,
                         speaker: String? = nil) -> TranscriptSegment {
        TranscriptSegment(speaker: speaker, start: start, end: end, text: text)
    }

    /// Длинная речь без пунктуации: слова идут по секунде каждое.
    private func longWords(count: Int, from: Double = 0) -> [TranscriptWord] {
        (0..<count).map { word("слово\($0)", from + Double($0), from + Double($0) + 0.9) }
    }

    // MARK: - Деградация

    func testEmptyWordsReturnSegmentsUnchanged() {
        let segments = [segment("длинный сегмент", 0, 300)]
        XCTAssertEqual(TranscriptSegmentSplitter.split(segments: segments, words: []), segments)
    }

    func testEmptySegmentsReturnEmpty() {
        XCTAssertTrue(TranscriptSegmentSplitter.split(segments: [], words: longWords(count: 5)).isEmpty)
    }

    /// Короткий сегмент проходит насквозь с серверным текстом — его не
    /// пересобирают из слов, чтобы не терять пунктуацию сервера.
    func testShortSegmentPassesThroughUntouched() {
        let segments = [segment("Короткая фраза.", 0, 5)]
        let words = [word("Короткая", 0, 1), word("фраза.", 1, 2)]
        let result = TranscriptSegmentSplitter.split(segments: segments, words: words, config: .medium)
        XCTAssertEqual(result, segments)
    }

    // MARK: - Нарезка

    func testLongSegmentIsSplitIntoSeveral() {
        // 120 секунд речи по слову в секунду — заведомо длиннее порога fine и medium.
        let words = longWords(count: 120)
        let segments = [segment("речь", 0, 120)]
        let result = TranscriptSegmentSplitter.split(segments: segments, words: words, config: .fine)
        XCTAssertGreaterThan(result.count, 1, "сегмент длиннее порога обязан быть нарезан")
    }

    func testFinerDetailProducesMoreSegments() {
        let words = longWords(count: 120)
        let segments = [segment("речь", 0, 120)]
        let coarse = TranscriptSegmentSplitter.split(segments: segments, words: words, config: .coarse)
        let fine = TranscriptSegmentSplitter.split(segments: segments, words: words, config: .fine)
        XCTAssertGreaterThan(fine.count, coarse.count)
    }

    /// Нарезка не имеет права терять слова — иначе из расшифровки молча
    /// исчезают куски текста.
    func testSplitKeepsEveryWord() {
        let words = longWords(count: 90)
        let segments = [segment("речь", 0, 90)]
        let result = TranscriptSegmentSplitter.split(segments: segments, words: words, config: .fine)
        let joined = result.map(\.text).joined(separator: " ")
        for w in words {
            XCTAssertTrue(joined.contains(w.text), "потеряно слово \(w.text)")
        }
    }

    func testSubsegmentsInheritSpeaker() {
        let words = longWords(count: 120)
        let segments = [segment("речь", 0, 120, speaker: "speaker_1")]
        let result = TranscriptSegmentSplitter.split(segments: segments, words: words, config: .fine)
        XCTAssertTrue(result.allSatisfy { $0.speaker == "speaker_1" })
    }

    func testSubsegmentsAreChronological() {
        let words = longWords(count: 120)
        let result = TranscriptSegmentSplitter.split(segments: [segment("речь", 0, 120)],
                                                     words: words, config: .fine)
        for (a, b) in zip(result, result.dropFirst()) {
            XCTAssertLessThanOrEqual(a.start, b.start)
            XCTAssertLessThanOrEqual(a.end, b.end)
        }
    }

    // MARK: - Границы предложений

    func testSentenceEndsOnTerminatorFollowedByCapital() {
        XCTAssertTrue(TranscriptSegmentSplitter.isSentenceBoundary(
            after: word("конец.", 0, 1), next: word("Начало", 1.1, 2)))
    }

    /// «т.д.» не должно резаться: следующее слово со строчной и без паузы.
    func testAbbreviationIsNotSentenceBoundary() {
        XCTAssertFalse(TranscriptSegmentSplitter.isSentenceBoundary(
            after: word("т.д.", 0, 1), next: word("далее", 1.1, 2)))
    }

    /// Пауза подтверждает конец предложения даже перед строчной буквой.
    func testPauseConfirmsSentenceBoundary() {
        XCTAssertTrue(TranscriptSegmentSplitter.isSentenceBoundary(
            after: word("конец.", 0, 1), next: word("далее", 2.0, 3)))
    }

    func testWordWithoutTerminatorIsNeverBoundary() {
        XCTAssertFalse(TranscriptSegmentSplitter.isSentenceBoundary(
            after: word("слово", 0, 1), next: word("Другое", 5, 6)))
    }

    func testLastWordIsAlwaysBoundary() {
        XCTAssertTrue(TranscriptSegmentSplitter.isSentenceBoundary(after: word("конец.", 0, 1), next: nil))
    }

    /// Замыкающая кавычка не должна прятать точку от анализатора.
    func testTrailingQuoteDoesNotHideTerminator() {
        XCTAssertTrue(TranscriptSegmentSplitter.isSentenceBoundary(
            after: word("«цитата».", 0, 1), next: word("Дальше", 1.1, 2)))
    }

    // MARK: - Раздача слов сегментам

    func testWordsAreAssignedByMidpoint() {
        let segments = [segment("первый", 0, 10), segment("второй", 10, 20)]
        let words = [word("рано", 1, 2), word("поздно", 15, 16)]
        let buckets = TranscriptSegmentSplitter.assignWords(words, to: segments)
        XCTAssertEqual(buckets[0].map(\.text), ["рано"])
        XCTAssertEqual(buckets[1].map(\.text), ["поздно"])
    }

    /// Слово, вышедшее за последний сегмент, достаётся последнему, а не теряется.
    func testWordBeyondLastSegmentGoesToLastBucket() {
        let segments = [segment("единственный", 0, 10)]
        let buckets = TranscriptSegmentSplitter.assignWords([word("хвост", 30, 31)], to: segments)
        XCTAssertEqual(buckets[0].map(\.text), ["хвост"])
    }

    // MARK: - Нарезка с происхождением

    /// `split` идёт через `splitWithSources` — и обязан давать то же, что раньше.
    func testSplitWithSourcesMatchesSplit() {
        let fixtures: [([TranscriptSegment], [TranscriptWord])] = [
            ([segment("речь", 0, 120, speaker: "speaker_1")], longWords(count: 120)),
            ([segment("Короткая фраза.", 0, 5), segment("длинная", 5, 125)],
             [word("Короткая", 0, 1), word("фраза.", 1, 2)] + longWords(count: 120, from: 5)),
            ([segment("без слов", 0, 300)], [])
        ]
        for (segments, words) in fixtures {
            let buckets = TranscriptSegmentSplitter.assignWords(words, to: segments)
            for config in [TranscriptSegmentSplitter.Config.coarse, .medium, .fine] {
                let parts = TranscriptSegmentSplitter.splitWithSources(segments: segments, buckets: buckets,
                                                                       config: config)
                XCTAssertEqual(parts.map(\.segment),
                               TranscriptSegmentSplitter.split(segments: segments, words: words, config: config))
            }
            let server = TranscriptSegmentSplitter.splitWithSources(segments: segments, buckets: buckets, config: nil)
            XCTAssertEqual(server.map(\.segment), segments)
        }
    }

    /// NaN в границах сегмента (локальный движок) — как прежняя реализация.
    func testNaNBoundsSplitLikeBefore() {
        let segments = [segment("речь", .nan, 120)]
        let result = TranscriptSegmentSplitter.split(segments: segments, words: longWords(count: 120), config: .fine)
        XCTAssertGreaterThan(result.count, 1)
    }

    /// Диапазоны частей одного куска подряд покрывают все его слова.
    func testSplitPartsCoverBucketContiguously() {
        let words = longWords(count: 120)
        let segments = [segment("речь", 0, 120)]
        let parts = TranscriptSegmentSplitter.splitWithSources(
            segments: segments, buckets: TranscriptSegmentSplitter.assignWords(words, to: segments), config: .fine)
        XCTAssertGreaterThan(parts.count, 1)
        XCTAssertEqual(parts.first?.words.lowerBound, 0)
        XCTAssertEqual(parts.last?.words.upperBound, words.count)
        for (a, b) in zip(parts, parts.dropFirst()) {
            XCTAssertEqual(a.words.upperBound, b.words.lowerBound)
        }
    }

    func testWordRangesMatchBuckets() {
        let segments = [segment("а", 0, 10), segment("б", 10, 20), segment("в", 20, 30)]
        let words = [word("рано", 1, 2), word("поздно", 15, 16), word("хвост", 40, 41)]
        let ranges = TranscriptSegmentSplitter.assignWordRanges(words, to: segments)
        XCTAssertEqual(ranges, [0..<1, 1..<2, 2..<3])
        XCTAssertEqual(ranges.map { words[$0].map(\.text) },
                       TranscriptSegmentSplitter.assignWords(words, to: segments).map { $0.map(\.text) })
        XCTAssertEqual(TranscriptSegmentSplitter.assignWordRanges([], to: segments), [0..<0, 0..<0, 0..<0])
    }

    // MARK: - Идемпотентность через TranscriptResult

    /// Смена детализации всегда считается от rawSegments, поэтому повторное
    /// применение того же уровня обязано давать тот же результат.
    func testWithDetailIsIdempotent() {
        let words = longWords(count: 120)
        let raw = [segment("речь", 0, 120)]
        let result = TranscriptResult(fullText: "речь", language: "ru", duration: 120,
                                      segments: raw, rawSegments: raw, words: words, llmOutput: nil)
        let once = result.withDetail(.fine)
        let twice = once.withDetail(.fine)
        XCTAssertEqual(once.segments, twice.segments)
    }

    /// Возврат к «как отдаёт сервер» восстанавливает исходные сегменты.
    func testServerDetailRestoresRawSegments() {
        let words = longWords(count: 120)
        let raw = [segment("речь", 0, 120)]
        let result = TranscriptResult(fullText: "речь", language: "ru", duration: 120,
                                      segments: raw, rawSegments: raw, words: words, llmOutput: nil)
        XCTAssertEqual(result.withDetail(.fine).withDetail(.server).segments, raw)
    }

    func testDetailLevelsMapToExpectedConfigs() {
        XCTAssertNil(TimestampDetail.server.config)
        XCTAssertEqual(TimestampDetail.coarse.config, .coarse)
        XCTAssertEqual(TimestampDetail.medium.config, .medium)
        XCTAssertEqual(TimestampDetail.fine.config, .fine)
    }
}
