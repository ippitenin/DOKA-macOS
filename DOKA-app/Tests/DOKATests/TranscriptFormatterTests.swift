import XCTest
@testable import DOKA

/// Форматы экспорта строятся локально из сегментов, без запросов к API.
/// Ошибка здесь портит субтитры так, что видно только в плеере.
final class TranscriptFormatterTests: XCTestCase {

    private func segment(_ text: String, _ start: Double, _ end: Double,
                         speaker: String? = nil) -> TranscriptSegment {
        TranscriptSegment(speaker: speaker, start: start, end: end, text: text)
    }

    private func result(_ segments: [TranscriptSegment], fullText: String = "") -> TranscriptResult {
        TranscriptResult(fullText: fullText, language: "ru", duration: 120,
                         segments: segments, rawSegments: segments, words: [], llmOutput: nil)
    }

    // MARK: - Чистый текст

    func testPlainTextPrefersFullText() {
        let r = result([segment("из сегмента", 0, 1)], fullText: "  полный текст  ")
        XCTAssertEqual(TranscriptFormatter.plainText(r), "полный текст")
    }

    func testPlainTextFallsBackToSegments() {
        let r = result([segment("первый", 0, 1), segment("второй", 1, 2)])
        XCTAssertEqual(TranscriptFormatter.plainText(r), "первый второй")
    }

    // MARK: - Тайм-коды

    func testTimestampsUseMinuteSecondFormat() {
        let r = result([segment("начало", 0, 5), segment("позже", 83, 90)])
        XCTAssertEqual(TranscriptFormatter.textWithTimestamps(r), "[0:00] начало\n[1:23] позже")
    }

    /// Часы появляются только когда они есть — иначе «0:01:23» шумит.
    func testTimestampsIncludeHoursOnlyWhenNeeded() {
        let r = result([segment("час", 3723, 3730)])
        XCTAssertEqual(TranscriptFormatter.textWithTimestamps(r), "[1:02:03] час")
    }

    /// Спикеры в этот формат намеренно не подмешиваются: для них отдельный формат,
    /// иначе два варианта экспорта неразличимы.
    func testTimestampsOmitSpeakers() {
        let r = result([segment("реплика", 0, 2, speaker: "speaker_0")])
        XCTAssertEqual(TranscriptFormatter.textWithTimestamps(r), "[0:00] реплика")
    }

    func testTimestampsWithSpeakersKeepUnlabeledSegmentsClean() {
        let r = result([segment("без спикера", 0, 2)])
        XCTAssertEqual(TranscriptFormatter.textWithTimestampsAndSpeakers(r), "[0:00] без спикера")
    }

    // MARK: - SRT

    func testSRTNumbersFromOneAndUsesCommaForMilliseconds() {
        let r = result([segment("первый", 0, 1.5), segment("второй", 1.5, 3.25)])
        let expected = """
        1
        00:00:00,000 --> 00:00:01,500
        первый

        2
        00:00:01,500 --> 00:00:03,250
        второй

        """
        XCTAssertEqual(TranscriptFormatter.srt(r), expected)
    }

    func testSRTHandlesHours() {
        let r = result([segment("поздний", 3661.123, 3662)])
        XCTAssertTrue(TranscriptFormatter.srt(r).contains("01:01:01,123 --> 01:01:02,000"))
    }

    // MARK: - VTT

    func testVTTStartsWithHeaderAndUsesDotForMilliseconds() {
        let r = result([segment("реплика", 2.5, 4)])
        let vtt = TranscriptFormatter.vtt(r)
        XCTAssertTrue(vtt.hasPrefix("WEBVTT\n\n"))
        XCTAssertTrue(vtt.contains("00:00:02.500 --> 00:00:04.000"))
    }

    func testVTTWithoutSegmentsStillHasHeader() {
        let r = result([], fullText: "только текст")
        XCTAssertEqual(TranscriptFormatter.vtt(r), "WEBVTT\n\nтолько текст\n")
    }

    // MARK: - Устойчивость к мусорным тайм-кодам

    /// NaN и отрицательные значения не должны давать «-1:-1» или крашить формат.
    func testInvalidTimestampsCollapseToZero() {
        let r = result([segment("битый", .nan, -5)])
        XCTAssertTrue(TranscriptFormatter.srt(r).contains("00:00:00,000 --> 00:00:00,000"))
        XCTAssertEqual(TranscriptFormatter.textWithTimestamps(r), "[0:00] битый")
    }

    // MARK: - Группировка по спикерам

    func testBySpeakerMergesConsecutiveSegmentsOfSameSpeaker() {
        let r = result([
            segment("первая фраза", 0, 2, speaker: "speaker_0"),
            segment("вторая фраза", 2, 4, speaker: "speaker_0"),
            segment("ответ", 4, 6, speaker: "speaker_1")
        ])
        let lines = TranscriptFormatter.bySpeaker(r).split(separator: "\n")
        XCTAssertEqual(lines.count, 2, "подряд идущие реплики одного спикера должны склеиваться")
        XCTAssertTrue(lines[0].contains("первая фраза вторая фраза"))
        XCTAssertTrue(lines[1].contains("ответ"))
    }

    /// Спикер, вернувшийся после чужой реплики, начинает новую строку.
    func testBySpeakerStartsNewLineWhenSpeakerReturns() {
        let r = result([
            segment("раз", 0, 1, speaker: "speaker_0"),
            segment("два", 1, 2, speaker: "speaker_1"),
            segment("три", 2, 3, speaker: "speaker_0")
        ])
        XCTAssertEqual(TranscriptFormatter.bySpeaker(r).split(separator: "\n").count, 3)
    }

    func testBySpeakerFallsBackToPlainTextWithoutDiarization() {
        let r = result([segment("без диаризации", 0, 2)], fullText: "без диаризации")
        XCTAssertEqual(TranscriptFormatter.bySpeaker(r), "без диаризации")
    }

    // MARK: - Имена спикеров из правок

    private func renamed(_ segments: [TranscriptSegment], _ names: [String: String]) -> TranscriptResult {
        var edits = TranscriptEdits()
        for (id, name) in names { edits.rename(id, to: name) }
        return result(segments).withEdits(edits, detail: .server)
    }

    func testSubtitlesAndTimestampsUseCustomName() {
        let r = renamed([segment("реплика", 0, 2, speaker: "speaker_0")], ["speaker_0": "Анна"])
        XCTAssertTrue(TranscriptFormatter.srt(r).contains("Анна: реплика"))
        XCTAssertTrue(TranscriptFormatter.vtt(r).contains("Анна: реплика"))
        XCTAssertEqual(TranscriptFormatter.textWithTimestampsAndSpeakers(r), "[0:00] Анна: реплика")
        XCTAssertEqual(TranscriptFormatter.bySpeaker(r), "Анна: реплика")
    }

    /// Двое с одним именем подряд — одна строка «по спикерам».
    func testBySpeakerGroupsBySameName() {
        let r = renamed([
            segment("раз", 0, 1, speaker: "speaker_0"),
            segment("два", 1, 2, speaker: "speaker_1"),
            segment("три", 2, 3, speaker: "speaker_2")
        ], ["speaker_0": "Анна", "speaker_1": "Анна"])
        let lines = TranscriptFormatter.bySpeaker(r).split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0], "Анна: раз два")
    }

    func testLLMTranscriptUsesNamesAndTimestamps() {
        let r = renamed([segment("начнём", 0, 2, speaker: "speaker_0")], ["speaker_0": "Анна"])
        XCTAssertEqual(TranscriptFormatter.llmTranscript(r), "[0:00] Анна: начнём")
        let plain = result([segment("без спикеров", 83, 90)])
        XCTAssertEqual(TranscriptFormatter.llmTranscript(plain), "[1:23] без спикеров")
    }

    // MARK: - Пустой результат

    func testEmptySegmentsDegradeToPlainText() {
        let r = result([], fullText: "текст без сегментов")
        XCTAssertEqual(TranscriptFormatter.textWithTimestamps(r), "текст без сегментов")
        XCTAssertEqual(TranscriptFormatter.srt(r), "текст без сегментов")
    }
}
