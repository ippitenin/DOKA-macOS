import XCTest
@testable import DOKA

/// Сшивка расшифровки с локальной диаризацией. Ошибка здесь тихо приписывает
/// реплику не тому человеку — в готовом тексте это не видно, пока не сверишь
/// с записью.
final class SpeakerAssignmentTests: XCTestCase {

    private func span(_ speaker: String, _ start: Double, _ end: Double) -> SpeakerSpan {
        SpeakerSpan(speaker: speaker, start: start, end: end)
    }

    private func word(_ text: String, _ start: Double, _ end: Double) -> TranscriptWord {
        TranscriptWord(text: text, start: start, end: end)
    }

    private func segment(_ text: String, _ start: Double, _ end: Double,
                         speaker: String? = nil) -> TranscriptSegment {
        TranscriptSegment(speaker: speaker, start: start, end: end, text: text)
    }

    // MARK: - Деградация

    func testEmptySpansLeaveSegmentsUntouched() {
        let segments = [segment("речь", 0, 10)]
        XCTAssertEqual(SpeakerAssignment.apply(spans: [], words: [word("речь", 0, 1)], segments: segments),
                       segments)
    }

    func testEmptySegmentsReturnEmpty() {
        XCTAssertTrue(SpeakerAssignment.apply(spans: [span("speaker_0", 0, 5)],
                                              words: [word("речь", 0, 1)],
                                              segments: []).isEmpty)
    }

    // MARK: - Сегмент целиком у одного говорящего

    /// Текст сервера/движка сохраняется как есть: пересборка из слов потеряла бы
    /// пунктуацию, а спикер тут и так один.
    func testSegmentInsideOneSpeakerKeepsOriginalText() {
        let result = SpeakerAssignment.apply(
            spans: [span("speaker_0", 0, 10)],
            words: [word("Привет,", 0, 1), word("как", 1, 2), word("дела?", 2, 3)],
            segments: [segment("Привет, как дела?", 0, 3)]
        )
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].speaker, "speaker_0")
        XCTAssertEqual(result[0].text, "Привет, как дела?")
        XCTAssertEqual(result[0].start, 0)
        XCTAssertEqual(result[0].end, 3)
    }

    func testConsecutiveWordsOfSameSpeakerAreNotFragmented() {
        let words = (0..<10).map { word("слово\($0)", Double($0), Double($0) + 0.9) }
        let result = SpeakerAssignment.apply(spans: [span("speaker_1", 0, 10)],
                                             words: words,
                                             segments: [segment("речь", 0, 10)])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].speaker, "speaker_1")
    }

    // MARK: - Смена говорящего внутри сегмента

    func testSegmentIsSplitWhereSpeakerChanges() {
        let result = SpeakerAssignment.apply(
            spans: [span("speaker_0", 0, 2), span("speaker_1", 2, 4)],
            words: [word("раз", 0, 0.9), word("два", 1, 1.9),
                    word("три", 2, 2.9), word("четыре", 3, 3.9)],
            segments: [segment("раз два три четыре", 0, 4)]
        )
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].speaker, "speaker_0")
        XCTAssertEqual(result[0].text, "раз два")
        XCTAssertEqual(result[1].speaker, "speaker_1")
        XCTAssertEqual(result[1].text, "три четыре")
        XCTAssertEqual(result[1].end, 3.9, accuracy: 0.001, "конец реплики — конец последнего слова")
    }

    /// Говорящий, вернувшийся после чужой реплики, начинает новый подсегмент.
    func testSpeakerReturningProducesThirdSubsegment() {
        let result = SpeakerAssignment.apply(
            spans: [span("speaker_0", 0, 1), span("speaker_1", 1, 2), span("speaker_0", 2, 3)],
            words: [word("раз", 0, 0.5), word("два", 1.2, 1.6), word("три", 2.2, 2.6)],
            segments: [segment("раз два три", 0, 3)]
        )
        XCTAssertEqual(result.map(\.speaker), ["speaker_0", "speaker_1", "speaker_0"])
    }

    /// Пунктуация отдельным токеном приклеивается без пробела — общая склейка
    /// с нарезкой по детализации.
    func testPunctuationTokenIsGluedToPreviousWord() {
        let result = SpeakerAssignment.apply(
            spans: [span("speaker_0", 0, 1), span("speaker_1", 1, 3)],
            words: [word("да", 0, 0.5), word("нет", 1.2, 1.6), word(",", 1.6, 1.7), word("не", 1.8, 2)],
            segments: [segment("да нет, не", 0, 3)]
        )
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[1].text, "нет, не")
    }

    // MARK: - Слова вне интервалов

    /// Слово в паузе между репликами достаётся ближайшей: без этого реплика
    /// рвалась бы надвое пустым спикером.
    func testWordInGapGoesToNearestSpan() {
        let result = SpeakerAssignment.apply(
            spans: [span("speaker_0", 0, 1), span("speaker_1", 5, 6)],
            words: [word("почти", 1.1, 1.3)],
            segments: [segment("почти", 0, 6)]
        )
        XCTAssertEqual(result[0].speaker, "speaker_0")
    }

    func testWordBeforeAllSpansGoesToFirstSpan() {
        let result = SpeakerAssignment.apply(
            spans: [span("speaker_0", 10, 20)],
            words: [word("рано", 0, 1)],
            segments: [segment("рано", 0, 20)]
        )
        XCTAssertEqual(result[0].speaker, "speaker_0")
    }

    // MARK: - Ветка без слов

    func testSegmentWithoutWordsTakesSpeakerWithLargestOverlap() {
        let result = SpeakerAssignment.apply(
            spans: [span("speaker_0", 0, 3), span("speaker_1", 3, 10)],
            words: [],
            segments: [segment("реплика", 2, 10)]
        )
        XCTAssertEqual(result[0].speaker, "speaker_1", "перекрытие 7 с против 1 с")
        XCTAssertEqual(result[0].text, "реплика")
    }

    /// Сегмент, не пересекающийся ни с одной репликой, остаётся без спикера —
    /// выдумывать его не на чем.
    func testSegmentWithoutOverlapKeepsNoSpeaker() {
        let result = SpeakerAssignment.apply(
            spans: [span("speaker_0", 100, 110)],
            words: [],
            segments: [segment("тишина", 0, 10)]
        )
        XCTAssertNil(result[0].speaker)
    }

    // MARK: - Совместимость с остальным конвейером

    /// Метки должны быть в формате Nexara — иначе `SpeakerName` покажет сырой id.
    func testProducedSpeakersAreDisplayable() {
        let result = SpeakerAssignment.apply(
            spans: [span("speaker_0", 0, 5)],
            words: [word("раз", 0, 1)],
            segments: [segment("раз", 0, 5)]
        )
        XCTAssertEqual(SpeakerName.index(of: result[0].speaker ?? ""), 0)
    }

    /// Результат должен становиться `rawSegments`, из которых работает
    /// перенарезка детализации, — спикеры при ней не теряются.
    func testResultSurvivesDetailReslicing() {
        let words = (0..<120).map { word("слово\($0)", Double($0), Double($0) + 0.9) }
        let assigned = SpeakerAssignment.apply(
            spans: [span("speaker_0", 0, 60), span("speaker_1", 60, 120)],
            words: words,
            segments: [segment("речь", 0, 120)]
        )
        let result = TranscriptResult(fullText: "речь", language: "ru", duration: 120,
                                      segments: assigned, rawSegments: assigned,
                                      words: words, llmOutput: nil)
        let fine = result.withDetail(.fine)
        XCTAssertTrue(fine.hasSpeakers)
        XCTAssertTrue(fine.segments.allSatisfy { $0.speaker != nil })
        XCTAssertEqual(Set(fine.segments.compactMap(\.speaker)), ["speaker_0", "speaker_1"])
    }

    // MARK: - Островки (дрожание разметки)

    /// Слова подряд по 0,4 с вплотную; `pauses[i]` — пауза перед i-м словом.
    /// Интервалы диаризатора — ровно по словам, со спикерами из `speakers`.
    private func scene(_ texts: [String], _ speakers: [String],
                       pauses: [Int: Double] = [:]) -> (words: [TranscriptWord], spans: [SpeakerSpan]) {
        var time = 0.0
        var words: [TranscriptWord] = []
        for (index, text) in texts.enumerated() {
            time += pauses[index] ?? 0
            words.append(word(text, time, time + 0.4))
            time += 0.4
        }
        let spans = zip(words, speakers).map { span($1, $0.start, $0.end) }
        return (words, spans)
    }

    private func applyToOneSegment(_ scene: (words: [TranscriptWord], spans: [SpeakerSpan]),
                                   text: String) -> [TranscriptSegment] {
        SpeakerAssignment.apply(spans: scene.spans, words: scene.words,
                                segments: [segment(text, 0, scene.words.last!.end)])
    }

    /// Слово посреди фразы, отданное другому человеку, возвращается соседу —
    /// и сегмент сохраняет исходный текст целиком.
    func testMidPhraseIslandGoesToNeighbour() {
        let text = "Американская, стайсик, и мне нравится"
        let result = applyToOneSegment(scene(text.components(separatedBy: " "),
                                             ["A", "B", "A", "A", "A"]), text: text)
        XCTAssertEqual(result.map(\.speaker), ["A"])
        XCTAssertEqual(result[0].text, text)
    }

    /// Короткий ответ между предложениями — настоящая реплика.
    func testShortReplyBetweenSentencesSurvives() {
        let result = applyToOneSegment(scene(["бьётся.", "Логично.", "Идём", "дальше."],
                                             ["A", "B", "A", "A"]),
                                       text: "бьётся. Логично. Идём дальше.")
        XCTAssertEqual(result.map(\.speaker), ["A", "B", "A"])
        XCTAssertEqual(result.map(\.text), ["бьётся.", "Логично.", "Идём дальше."])
    }

    /// Граница только с одной стороны — не реплика, а дрожание.
    func testIslandWithBoundaryOnOneSideIsMerged() {
        let result = applyToOneSegment(scene(["бьётся.", "Логично", "идём", "дальше."],
                                             ["A", "B", "A", "A"]),
                                       text: "бьётся. Логично идём дальше.")
        XCTAssertEqual(result.map(\.speaker), ["A"])
    }

    /// Паузы с обеих сторон — граница даже без знаков препинания (у сетевых
    /// сервисов слова бывают без пунктуации); паузы короче порога — нет.
    func testPausesOnBothSidesKeepIsland() {
        let long = SpeakerAssignment.islandPause + 0.1
        let kept = applyToOneSegment(scene(["так", "да", "вот", "и"], ["A", "B", "A", "A"],
                                           pauses: [1: long, 2: long]),
                                     text: "так да вот и")
        XCTAssertEqual(kept.map(\.speaker), ["A", "B", "A"])

        let short = SpeakerAssignment.islandPause - 0.1
        let merged = applyToOneSegment(scene(["так", "да", "вот", "и"], ["A", "B", "A", "A"],
                                             pauses: [1: short, 2: short]),
                                       text: "так да вот и")
        XCTAssertEqual(merged.map(\.speaker), ["A"])
    }

    /// Три слова подряд — уже не островок, даже посреди фразы.
    func testThreeWordRunIsNotAnIsland() {
        let result = applyToOneSegment(scene(["раз", "два", "три", "четыре", "пять"],
                                             ["A", "B", "B", "B", "A"]),
                                       text: "раз два три четыре пять")
        XCTAssertEqual(result.map(\.speaker), ["A", "B", "A"])
    }

    /// Островок — только между речью ОДНОГО и того же человека; на краю
    /// записи и между двумя разными соседями слова остаются как есть.
    func testRunsAtEdgesOrBetweenDifferentSpeakersStay() {
        let edge = applyToOneSegment(scene(["да", "так", "вот", "и"], ["B", "A", "A", "A"]),
                                     text: "да так вот и")
        XCTAssertEqual(edge.map(\.speaker), ["B", "A"])
        let between = applyToOneSegment(scene(["раз", "два", "три", "четыре"], ["A", "B", "C", "C"]),
                                        text: "раз два три четыре")
        XCTAssertEqual(between.map(\.speaker), ["A", "B", "C"])
    }

    /// Островок на стыке двух сегментов (у Whisper они короткие) виден только
    /// по всей записи: изнутри второго сегмента у слова нет соседа слева.
    func testIslandAcrossSegmentBoundaryIsMerged() {
        let s = scene(["Американская,", "стайсик,", "и", "мне", "нравится"], ["A", "B", "A", "A", "A"])
        let result = SpeakerAssignment.apply(
            spans: s.spans, words: s.words,
            segments: [segment("Американская,", 0, s.words[0].end),
                       segment("стайсик, и мне нравится", s.words[1].start, s.words[4].end)])
        XCTAssertEqual(result.map(\.speaker), ["A", "A"])
        XCTAssertEqual(result[1].text, "стайсик, и мне нравится")
    }
}
