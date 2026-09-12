import XCTest
@testable import DOKA

/// Модели библиотеки: `FailureKind.classify` и `RecordSummary.make`.
///
/// Зачем: от `classify` напрямую зависит `RetryPlanner.canRepoll` — то есть
/// решение «забрать результат с сервера бесплатно или отправить файл заново
/// и заплатить». Ошибка в одной ветке молча тарифицирует пользователя
/// повторно либо зацикливает «Повторить» на безнадёжной записи.
/// `RecordSummary` — то, что видно в строке списка без чтения тела с диска;
/// разъехавшись с телом, она врёт про число слов и спикеров.
final class FailureKindTests: XCTestCase {

    private typealias FileError = FileTranscriptionClient.FileTranscriptionError
    private typealias ClientError = TranscriptionClient.ClientError

    // MARK: - Ошибки файловой транскрибации

    func testInvalidKeyIsAuth() {
        XCTAssertEqual(FailureKind.classify(FileError.invalidKey), .auth)
    }

    func testNoFundsKeepsItsOwnKind() {
        XCTAssertEqual(FailureKind.classify(FileError.noFunds), .noFunds)
    }

    /// Все три транзиентные ошибки обязаны схлопываться в `.network`: именно
    /// по этому виду `RetryPlanner` разрешает бесплатный повторный опрос.
    func testTransientErrorsAreNetwork() {
        XCTAssertEqual(FailureKind.classify(FileError.rateLimited), .network)
        XCTAssertEqual(FailureKind.classify(FileError.server(503)), .network)
        XCTAssertEqual(FailureKind.classify(FileError.network(URLError(.timedOut))), .network)
    }

    /// 404 и `status=error` — детерминированные: повторный опрос вернул бы
    /// то же самое, поэтому у них СВОИ виды, а не `.network`.
    func testDeterministicServerOutcomesAreNotNetwork() {
        XCTAssertEqual(FailureKind.classify(FileError.jobNotFound), .jobNotFound)
        XCTAssertEqual(FailureKind.classify(FileError.jobFailed("boom")), .jobFailed)
    }

    func testUnparseableResponsesAreOther() {
        XCTAssertEqual(FailureKind.classify(FileError.badResponse), .other)
        XCTAssertEqual(FailureKind.classify(FileError.emptyText), .other)
        XCTAssertEqual(FailureKind.classify(FileError.readFailed), .other)
    }

    // MARK: - Ошибки клиента диктовки

    /// «Не настроен» и «нет ключа» — это `.auth`: ключ мог появиться, и
    /// повторный опрос имеет смысл.
    func testClientConfigurationErrorsAreAuth() {
        XCTAssertEqual(FailureKind.classify(ClientError.notConfigured), .auth)
        XCTAssertEqual(FailureKind.classify(ClientError.noAPIKey), .auth)
    }

    /// У `ClientError` ветка `default`: остальные его случаи — `.other`.
    /// Отдельно проверяем `invalidKey`, потому что у ОДНОИМЁННОГО случая
    /// файлового клиента вид другой (`.auth`) — эти два enum'а легко спутать.
    func testOtherClientErrorsFallThroughToOther() {
        XCTAssertEqual(FailureKind.classify(ClientError.invalidKey), .other)
        XCTAssertEqual(FailureKind.classify(ClientError.noFunds), .other)
        XCTAssertEqual(FailureKind.classify(ClientError.rateLimited), .other)
        XCTAssertEqual(FailureKind.classify(ClientError.server(500)), .other)
        XCTAssertEqual(FailureKind.classify(ClientError.badResponse), .other)
        XCTAssertEqual(FailureKind.classify(ClientError.emptyText), .other)
        XCTAssertEqual(FailureKind.classify(ClientError.network(URLError(.notConnectedToInternet))), .other)
    }

    // MARK: - Локальный путь и всё остальное

    func testDecoderErrorsAreLocal() {
        XCTAssertEqual(FailureKind.classify(AudioFileDecoder.DecoderError.noAudioTrack), .local)
        XCTAssertEqual(FailureKind.classify(AudioFileDecoder.DecoderError.readFailed), .local)
    }

    /// Чужая ошибка (в т.ч. голый URLError не из нашего клиента) — `.other`.
    /// Проверка нужна: «сеть» здесь НЕ распознаётся, и это осознанно —
    /// повторный опрос по такой записи всё равно некуда адресовать.
    func testUnknownErrorsAreOther() {
        XCTAssertEqual(FailureKind.classify(URLError(.timedOut)), .other)
        XCTAssertEqual(FailureKind.classify(CancellationError()), .other)
        XCTAssertEqual(FailureKind.classify(NSError(domain: "x", code: 1)), .other)
    }

    // MARK: - Декод

    /// Запись из будущей версии не должна ронять декод всей записи.
    func testUnknownRawValueDecodesAsOther() throws {
        let decoded = try JSONDecoder().decode(FailureKind.self, from: Data(#""quantumFailure""#.utf8))
        XCTAssertEqual(decoded, .other)
    }

    func testKnownRawValuesRoundTrip() throws {
        for kind in [FailureKind.network, .jobNotFound, .jobFailed, .interrupted,
                     .expired, .auth, .noFunds, .local, .other] {
            let data = try JSONEncoder().encode(kind)
            XCTAssertEqual(try JSONDecoder().decode(FailureKind.self, from: data), kind,
                           "не пережил round-trip: \(kind.rawValue)")
        }
    }
}

/// Сводка записи: число слов, спикеров, анализов и превью для строки списка.
final class RecordSummaryTests: XCTestCase {

    private func segment(_ text: String, speaker: String?, start: Double, end: Double) -> TranscriptSegment {
        TranscriptSegment(speaker: speaker, start: start, end: end, text: text)
    }

    private func body(segments: [TranscriptSegment], fullText: String? = nil,
                      analyses: [StoredAnalysis] = []) -> TranscriptBody {
        let text = fullText ?? segments.map(\.text).joined(separator: " ")
        let stored = StoredTranscript(fullText: text, language: "ru", duration: 10,
                                      rawSegments: segments, words: [], llmOutput: nil)
        return TranscriptBody(transcript: stored, analyses: analyses)
    }

    private func analysis(_ title: String) -> StoredAnalysis {
        StoredAnalysis(title: title, templateID: "builtin.summary", source: .nexara, markdown: "# \(title)")
    }

    func testCountsWordsOfTheWholeTranscript() {
        let summary = RecordSummary.make(from: body(segments: [
            segment("Привет мир", speaker: "speaker_0", start: 0, end: 1),
            segment("как дела", speaker: "speaker_1", start: 1, end: 2),
        ]))
        XCTAssertEqual(summary.wordCount, 4)
    }

    /// Спикеры считаются по РАЗНЫМ идентификаторам, а не по числу реплик.
    func testCountsDistinctSpeakersNotSegments() {
        let summary = RecordSummary.make(from: body(segments: [
            segment("раз", speaker: "speaker_0", start: 0, end: 1),
            segment("два", speaker: "speaker_1", start: 1, end: 2),
            segment("три", speaker: "speaker_0", start: 2, end: 3),
        ]))
        XCTAssertEqual(summary.speakerCount, 2)
    }

    /// Записи без диаризации: спикеров ноль, а не «один безымянный».
    func testNoDiarizationMeansZeroSpeakers() {
        let summary = RecordSummary.make(from: body(segments: [
            segment("раз", speaker: nil, start: 0, end: 1),
            segment("два", speaker: "", start: 1, end: 2),
        ]))
        XCTAssertEqual(summary.speakerCount, 0)
    }

    func testCountsAnalyses() {
        let summary = RecordSummary.make(from: body(
            segments: [segment("текст", speaker: nil, start: 0, end: 1)],
            analyses: [analysis("Резюме"), analysis("Протокол")]))
        XCTAssertEqual(summary.analysisCount, 2)
    }

    /// Превью схлопывает любые пробелы и переводы строк: строка списка
    /// однострочная, и «дыра» из \n\n в ней выглядела бы как обрыв текста.
    func testPreviewCollapsesWhitespace() {
        let summary = RecordSummary.make(from: body(
            segments: [segment("раз", speaker: nil, start: 0, end: 1)],
            fullText: "первая   строка\n\nвторая\tстрока"))
        XCTAssertEqual(summary.preview, "первая строка вторая строка")
    }

    func testPreviewIsCappedAtPreviewLength() {
        let long = String(repeating: "а", count: 500)
        let summary = RecordSummary.make(from: body(
            segments: [segment(long, speaker: nil, start: 0, end: 1)], fullText: long))
        XCTAssertEqual(summary.preview.count, RecordSummary.previewLength)
    }

    func testEmptyTranscriptGivesZeroes() {
        let summary = RecordSummary.make(from: body(segments: [], fullText: ""))
        XCTAssertEqual(summary.wordCount, 0)
        XCTAssertEqual(summary.speakerCount, 0)
        XCTAssertEqual(summary.analysisCount, 0)
        XCTAssertEqual(summary.preview, "")
    }

    /// Переданный `serverResult` — только оптимизация: он обязан давать
    /// ровно то же, что и пересчёт из тела. Разъехавшись, сводка начнёт
    /// врать после каждой правки.
    func testPassingServerResultMatchesRecomputing() {
        let source = body(segments: [
            segment("Привет мир", speaker: "speaker_0", start: 0, end: 1),
            segment("как дела", speaker: "speaker_1", start: 1, end: 2),
        ], analyses: [analysis("Резюме")])
        let recomputed = RecordSummary.make(from: source)
        let passed = RecordSummary.make(from: source, serverResult: source.makeResult(detail: .server))
        XCTAssertEqual(recomputed, passed)
    }
}
