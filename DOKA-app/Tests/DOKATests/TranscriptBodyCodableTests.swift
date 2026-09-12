import XCTest
@testable import DOKA

/// Устойчивость декодеров тела записи.
///
/// Зачем: `transcript.json` — данные пользователя, которые переживают
/// обновления приложения. Декодер, падающий на незнакомом или повреждённом
/// поле, не показывает ошибку — вызывающий оборачивает его в `try?`, и
/// расшифровка просто исчезает. Здесь закреплено ровно то, что должно
/// переживать порчу: битый анализ и битые правки не стоят расшифровки,
/// а отсутствующие поля берут дефолты.
final class TranscriptBodyCodableTests: XCTestCase {

    private func makeBody(analyses: [StoredAnalysis] = [],
                          edits: TranscriptEdits? = nil) -> TranscriptBody {
        let segments = [TranscriptSegment(speaker: "speaker_0", start: 0, end: 2, text: "Привет мир")]
        let stored = StoredTranscript(fullText: "Привет мир", language: "ru", duration: 2,
                                      rawSegments: segments,
                                      words: [TranscriptWord(text: "Привет", start: 0, end: 1),
                                              TranscriptWord(text: "мир", start: 1, end: 2)],
                                      llmOutput: nil)
        return TranscriptBody(transcript: stored, analyses: analyses, edits: edits)
    }

    private func analysis(_ markdown: String = "# Отчёт") -> StoredAnalysis {
        StoredAnalysis(title: "Резюме", templateID: "builtin.summary",
                       source: .local(modelID: "qwen3.5-4b-q4km"), markdown: markdown)
    }

    private func decodeBody(_ json: String) throws -> TranscriptBody {
        try JSONDecoder().decode(TranscriptBody.self, from: Data(json.utf8))
    }

    // MARK: - Round-trip

    func testRoundTripPreservesEverything() throws {
        var edits = TranscriptEdits()
        edits.rename("speaker_0", to: "Анна")
        let body = makeBody(analyses: [analysis()], edits: edits)
        let data = try JSONEncoder().encode(body)
        XCTAssertEqual(try JSONDecoder().decode(TranscriptBody.self, from: data), body)
    }

    // MARK: - Отсутствующие поля

    /// Тело без `schema` — из версии, где поля ещё не было: читается как
    /// текущая схема, а не падает.
    func testMissingSchemaDefaultsToCurrent() throws {
        let encoded = try JSONEncoder().encode(makeBody())
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "schema")
        let data = try JSONSerialization.data(withJSONObject: object)
        let body = try JSONDecoder().decode(TranscriptBody.self, from: data)
        XCTAssertEqual(body.schema, TranscriptBody.currentSchema)
        XCTAssertEqual(body.transcript.fullText, "Привет мир")
    }

    func testMissingAnalysesAndEditsAreEmpty() throws {
        let encoded = try JSONEncoder().encode(makeBody())
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "analyses")
        object.removeValue(forKey: "edits")
        let body = try JSONDecoder().decode(
            TranscriptBody.self, from: try JSONSerialization.data(withJSONObject: object))
        XCTAssertTrue(body.analyses.isEmpty)
        XCTAssertNil(body.edits)
    }

    // MARK: - Порча

    /// Битые анализы не стоят расшифровки: тело читается, анализы пустые.
    func testCorruptAnalysesDoNotCostTheTranscript() throws {
        let encoded = try JSONEncoder().encode(makeBody(analyses: [analysis()]))
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["analyses"] = "это не массив"
        let body = try JSONDecoder().decode(
            TranscriptBody.self, from: try JSONSerialization.data(withJSONObject: object))
        XCTAssertTrue(body.analyses.isEmpty)
        XCTAssertEqual(body.transcript.fullText, "Привет мир", "расшифровка обязана уцелеть")
    }

    /// То же для правок.
    func testCorruptEditsDoNotCostTheTranscript() throws {
        var edits = TranscriptEdits()
        edits.rename("speaker_0", to: "Анна")
        let encoded = try JSONEncoder().encode(makeBody(edits: edits))
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["edits"] = 42
        let body = try JSONDecoder().decode(
            TranscriptBody.self, from: try JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(body.edits)
        XCTAssertEqual(body.transcript.fullText, "Привет мир")
    }

    /// А вот сама расшифровка обязательна: тело без неё бессмысленно, и
    /// молча подставлять пустую нельзя — вызывающий должен увидеть отказ.
    func testMissingTranscriptIsAnError() {
        XCTAssertThrowsError(try decodeBody(#"{"schema":1,"analyses":[]}"#))
    }

    // MARK: - StoredAnalysis

    /// Обязателен только текст: анализ из будущей версии с незнакомым
    /// `source` читается как Nexara, без даты — как `distantPast`.
    func testAnalysisNeedsOnlyMarkdown() throws {
        let decoded = try JSONDecoder().decode(
            StoredAnalysis.self, from: Data(##"{"markdown":"# Итоги"}"##.utf8))
        XCTAssertEqual(decoded.markdown, "# Итоги")
        XCTAssertEqual(decoded.title, "")
        XCTAssertEqual(decoded.createdAt, .distantPast)
        XCTAssertEqual(decoded.source, .nexara)
        XCTAssertFalse(decoded.truncated)
        XCTAssertNil(decoded.templateID)
    }

    func testAnalysisWithoutMarkdownIsAnError() {
        XCTAssertThrowsError(try JSONDecoder().decode(
            StoredAnalysis.self, from: Data(#"{"title":"Резюме"}"#.utf8)))
    }

    /// Источник анализа виден даже после смены текущей модели — по нему
    /// понятно, чем именно сделан отчёт.
    func testAnalysisSourceRoundTrips() throws {
        for source in [StoredAnalysis.Source.nexara, .local(modelID: "qwen3.5-4b-q4km")] {
            let value = StoredAnalysis(title: "t", templateID: nil, source: source, markdown: "m")
            let data = try JSONEncoder().encode(value)
            XCTAssertEqual(try JSONDecoder().decode(StoredAnalysis.self, from: data).source, source)
        }
    }

    // MARK: - makeResult как единственная точка

    /// `llmOutput` результата берётся из АНАЛИЗОВ, а не из машинного тела:
    /// удалённый анализ не должен всплыть обратно.
    func testLLMOutputComesFromAnalysesNotFromStoredTranscript() {
        let stored = StoredTranscript(fullText: "текст", language: "ru", duration: 1,
                                      rawSegments: [], words: [], llmOutput: "СТАРЫЙ анализ v1")
        let withoutAnalyses = TranscriptBody(transcript: stored)
        XCTAssertNil(withoutAnalyses.makeResult(detail: .server).llmOutput,
                     "анализ из машинного тела не должен всплывать")

        let withNexara = TranscriptBody(transcript: stored, analyses: [
            StoredAnalysis(title: "t", templateID: nil, source: .nexara, markdown: "новый"),
        ])
        XCTAssertEqual(withNexara.makeResult(detail: .server).llmOutput, "новый")
    }

    /// Локальный анализ в `llmOutput` не подставляется: карточка «Анализ»
    /// показывает его отдельным списком, а не как часть расшифровки.
    func testLocalAnalysisIsNotTreatedAsNexaraOutput() {
        let stored = StoredTranscript(fullText: "текст", language: "ru", duration: 1,
                                      rawSegments: [], words: [], llmOutput: nil)
        let body = TranscriptBody(transcript: stored, analyses: [analysis("локальный отчёт")])
        XCTAssertNil(body.makeResult(detail: .server).llmOutput)
    }
}
