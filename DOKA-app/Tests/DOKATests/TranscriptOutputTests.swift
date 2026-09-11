import XCTest
@testable import DOKA

/// Словарь для файлов — линза над выводом: исходник (rawSegments/words) обязан
/// остаться нетронутым, иначе выключение тумблера не вернёт расшифровку.
final class TranscriptOutputTests: XCTestCase {

    private let rules = [ReplacementRule(from: "дока", to: "DOKA")]

    /// Один длинный сегмент со словами — сплиттер нарежет его на «Мелко».
    private func sample() -> TranscriptResult {
        let sentences = [
            "Дока распознала первую часть записи.",
            "Документ лежит в папке дока.",
            "Потом мы открыли дока ещё раз.",
            "Всё работает как надо."
        ]
        var words: [TranscriptWord] = []
        var t = 0.0
        for sentence in sentences {
            for token in sentence.split(separator: " ") {
                words.append(TranscriptWord(text: String(token), start: t, end: t + 0.9))
                t += 1.0
            }
            t += 2.0
        }
        let text = sentences.joined(separator: " ")
        let raw = [TranscriptSegment(speaker: "speaker_0", start: 0, end: t, text: text)]
        return TranscriptResult(fullText: text, language: "ru", duration: t,
                                segments: raw, rawSegments: raw, words: words,
                                llmOutput: "## Итог\nдока")
    }

    func testReplacesDisplayedTextAndFullText() {
        let out = TranscriptOutput.applyingDictionary(sample(), rules: rules)
        XCTAssertTrue(out.fullText.contains("DOKA распознала"))
        XCTAssertTrue(out.fullText.contains("Документ"), "слово целиком не должно задеваться")
        XCTAssertFalse(out.fullText.contains("DOKAмент"))
    }

    func testSourceDataStaysUntouched() {
        let original = sample()
        let out = TranscriptOutput.applyingDictionary(original, rules: rules)
        XCTAssertEqual(out.rawSegments, original.rawSegments)
        XCTAssertEqual(out.words, original.words)
        XCTAssertEqual(out.llmOutput, original.llmOutput, "анализ — серверный текст, словарь его не трогает")
    }

    func testNoActiveRulesReturnsResultAsIs() {
        let original = sample()
        XCTAssertEqual(TranscriptOutput.applyingDictionary(original, rules: []), original)
        let disabled = [ReplacementRule(from: "дока", to: "DOKA", enabled: false)]
        XCTAssertEqual(TranscriptOutput.applyingDictionary(original, rules: disabled), original)
    }

    /// Словарь применяется ПОСЛЕ перенарезки — к каждому подсегменту.
    func testAppliesToEverySegmentAfterResplit() {
        let fine = sample().withDetail(.fine)
        XCTAssertGreaterThan(fine.segments.count, 1, "фикстура должна нарезаться")
        let out = TranscriptOutput.applyingDictionary(fine, rules: rules)
        XCTAssertEqual(out.segments.map(\.text),
                       fine.segments.map { ReplacementEngine.apply($0.text, rules: rules) })
        XCTAssertTrue(out.segments.contains { $0.text.contains("DOKA") })
    }

    func testSpeakerAndTimingsArePreserved() {
        let fine = sample().withDetail(.fine)
        let out = TranscriptOutput.applyingDictionary(fine, rules: rules)
        XCTAssertEqual(out.segments.map(\.speaker), fine.segments.map(\.speaker))
        XCTAssertEqual(out.segments.map(\.start), fine.segments.map(\.start))
        XCTAssertEqual(out.segments.map(\.end), fine.segments.map(\.end))
    }

    func testIdempotentForBoundedRules() {
        let once = TranscriptOutput.applyingDictionary(sample(), rules: rules)
        XCTAssertEqual(TranscriptOutput.applyingDictionary(once, rules: rules), once)
    }
}
