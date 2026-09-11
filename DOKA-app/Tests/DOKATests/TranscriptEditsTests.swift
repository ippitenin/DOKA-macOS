import XCTest
@testable import DOKA

/// Слой правок поверх неизменного результата распознавания. Ошибка здесь —
/// потерянная правка пользователя или испорченная расшифровка во всех
/// экспортах сразу: правки применяются в одной точке для показа, копирования,
/// экспорта и поиска.
///
/// Ловушка локализации: имена по умолчанию («Спикер N») идут через `L()` и
/// зависят от языка бандла — проверяются заданные имена и номера, не перевод.
final class TranscriptEditsTests: XCTestCase {

    // MARK: - Фикстуры

    private func word(_ text: String, _ start: Double, _ end: Double) -> TranscriptWord {
        TranscriptWord(text: text, start: start, end: end)
    }

    private func segment(_ text: String, _ start: Double, _ end: Double,
                         speaker: String? = nil) -> TranscriptSegment {
        TranscriptSegment(speaker: speaker, start: start, end: end, text: text)
    }

    private func result(_ raw: [TranscriptSegment], words: [TranscriptWord] = [],
                        fullText: String = "текст") -> TranscriptResult {
        TranscriptResult(fullText: fullText, language: "ru", duration: raw.last?.end ?? 0,
                         segments: raw, rawSegments: raw, words: words, llmOutput: nil)
    }

    /// Диалог трёх спикеров, без слов.
    private func dialogue() -> TranscriptResult {
        result([
            segment("Привет.", 0, 2, speaker: "speaker_0"),
            segment("Здравствуйте.", 2, 4, speaker: "speaker_1"),
            segment("Добрый день.", 4, 6, speaker: "speaker_2"),
            segment("Начнём.", 6, 8, speaker: "speaker_0")
        ])
    }

    private func speakers(_ r: TranscriptResult) -> [String?] { r.segments.map(\.speaker) }

    // MARK: - Переименование

    func testRenameGivesLabel() {
        var edits = TranscriptEdits()
        edits.rename("speaker_0", to: "  Анна  ")
        XCTAssertEqual(edits.label(for: "speaker_0"), "Анна")
        XCTAssertEqual(edits.customName(for: "speaker_0"), "Анна")
        XCTAssertNil(edits.customName(for: "speaker_1"))
    }

    /// Пустое и пробельное имя возвращают «Спикер N» — номер, а не перевод.
    func testEmptyNameRestoresDefault() {
        var edits = TranscriptEdits()
        edits.rename("speaker_1", to: "Анна")
        edits.rename("speaker_1", to: "   \n ")
        XCTAssertNil(edits.customName(for: "speaker_1"))
        XCTAssertNotEqual(edits.label(for: "speaker_1"), "Анна")
        XCTAssertTrue(edits.label(for: "speaker_1").contains("2"))
        XCTAssertTrue(edits.isEmpty)
    }

    /// Имя, совпавшее с именем по умолчанию, своим не считается.
    func testDefaultNameIsNotStored() {
        var edits = TranscriptEdits()
        edits.rename("speaker_1", to: SpeakerName.displayName(for: "speaker_1"))
        XCTAssertTrue(edits.isEmpty)
    }

    func testNameWhitespaceCollapsesAndLongNameIsCut() {
        var edits = TranscriptEdits()
        edits.rename("speaker_0", to: "Анна\n  Петровна")
        XCTAssertEqual(edits.label(for: "speaker_0"), "Анна Петровна")
        edits.rename("speaker_0", to: String(repeating: "я", count: TranscriptEdits.maxNameLength + 10))
        XCTAssertEqual(edits.label(for: "speaker_0").count, TranscriptEdits.maxNameLength)
    }

    /// Имя попадает в результат и переживает перенарезку.
    func testRenamedLabelSurvivesDetailChange() {
        var edits = TranscriptEdits()
        edits.rename("speaker_1", to: "Борис")
        let r = dialogue().withEdits(edits, detail: .fine).withDetail(.server)
        XCTAssertEqual(r.speakerLabel("speaker_1"), "Борис")
    }

    // MARK: - Слияние

    func testMergeRewritesSpeakersOnEveryLevel() {
        var edits = TranscriptEdits()
        edits.merge("speaker_1", into: "speaker_0")
        for detail in TimestampDetail.allCases {
            let r = dialogue().withEdits(edits, detail: detail)
            XCTAssertFalse(speakers(r).contains("speaker_1"), "уровень \(detail)")
            XCTAssertEqual(speakers(r), ["speaker_0", "speaker_0", "speaker_2", "speaker_0"])
        }
    }

    func testMergeGluesConsecutiveTurnsBySpeaker() {
        var edits = TranscriptEdits()
        edits.merge("speaker_1", into: "speaker_0")
        let text = TranscriptFormatter.bySpeaker(dialogue().withEdits(edits, detail: .server))
        let lines = text.split(separator: "\n")
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].hasSuffix("Привет. Здравствуйте."))
    }

    func testMergeChainIsTransitive() {
        var edits = TranscriptEdits()
        edits.merge("speaker_0", into: "speaker_1")
        edits.merge("speaker_1", into: "speaker_2")
        XCTAssertEqual(edits.canonical("speaker_0"), "speaker_2")
        let r = dialogue().withEdits(edits, detail: .server)
        XCTAssertEqual(Set(speakers(r).compactMap { $0 }), ["speaker_2"])
    }

    /// Обратное слияние уже слитых — no-op, а не цикл.
    func testReverseMergeDoesNotCreateCycle() {
        var edits = TranscriptEdits()
        edits.merge("speaker_1", into: "speaker_0")
        edits.merge("speaker_0", into: "speaker_1")
        XCTAssertEqual(edits.speakerMerges, ["speaker_1": "speaker_0"])
        XCTAssertEqual(edits.canonical("speaker_0"), "speaker_0")
    }

    /// Цикл в битых данных не вешает `canonical`.
    func testCorruptCycleTerminates() {
        var edits = TranscriptEdits()
        edits.speakerMerges = ["a": "b", "b": "a"]
        XCTAssertTrue(["a", "b"].contains(edits.canonical("a")))
    }

    func testUnmergeRestores() {
        var edits = TranscriptEdits()
        edits.merge("speaker_2", into: "speaker_0")
        XCTAssertEqual(edits.mergedIDs(into: "speaker_0"), ["speaker_2"])
        edits.unmerge("speaker_2")
        XCTAssertEqual(speakers(dialogue().withEdits(edits, detail: .server)), speakers(dialogue()))
        XCTAssertTrue(edits.isEmpty)
    }

    /// Влитые в влитого уходят вместе с ним и возвращаются вместе при «Отделить».
    func testUnmergeKeepsNestedMerges() {
        var edits = TranscriptEdits()
        edits.merge("speaker_2", into: "speaker_1")
        edits.merge("speaker_1", into: "speaker_0")
        XCTAssertEqual(edits.mergedIDs(into: "speaker_0"), ["speaker_1", "speaker_2"])
        edits.unmerge("speaker_1")
        XCTAssertEqual(edits.canonical("speaker_2"), "speaker_1")
    }

    func testMergeInheritsNameWhenTargetHasNone() {
        var edits = TranscriptEdits()
        edits.rename("speaker_1", to: "Анна")
        edits.merge("speaker_1", into: "speaker_0")
        XCTAssertEqual(edits.label(for: "speaker_0"), "Анна")
        // Своё имя у цели побеждает.
        var named = TranscriptEdits()
        named.rename("speaker_0", to: "Борис")
        named.rename("speaker_1", to: "Анна")
        named.merge("speaker_1", into: "speaker_0")
        XCTAssertEqual(named.label(for: "speaker_1"), "Борис")
        XCTAssertEqual(named.ownLabel(for: "speaker_1"), "Анна")
    }

    // MARK: - Цвета и ростер

    func testColorIndicesBySpeakerNumber() {
        let colors = SpeakerName.colorIndices(orderedIDs: ["speaker_3", "speaker_0"])
        XCTAssertEqual(colors, ["speaker_3": 3, "speaker_0": 0])
    }

    /// Роль не делит цвет с `speaker_N` из того же набора.
    func testRoleSkipsIndicesTakenBySpeakerNumbers() {
        let colors = SpeakerName.colorIndices(orderedIDs: ["Клиент", "speaker_0", "Агент", "speaker_1"])
        XCTAssertEqual(colors["speaker_0"], 0)
        XCTAssertEqual(colors["speaker_1"], 1)
        XCTAssertEqual(colors["Клиент"], 2)
        XCTAssertEqual(colors["Агент"], 3)
    }

    /// Только роли — по порядку появления, как раньше (без смешанных наборов
    /// поведение не меняется).
    func testRolesOnlyKeepFirstAppearanceOrder() {
        XCTAssertEqual(SpeakerName.colorIndices(orderedIDs: ["Клиент", "Агент", "Клиент"]),
                       ["Клиент": 0, "Агент": 1])
    }

    func testMergedSpeakerTakesTargetColorAndRenameKeepsIt() {
        var edits = TranscriptEdits()
        let before = dialogue().speakerColorIndices
        edits.merge("speaker_2", into: "speaker_1")
        edits.rename("speaker_1", to: "Анна")
        let r = dialogue().withEdits(edits, detail: .server)
        let roster = r.speakerRoster
        XCTAssertEqual(roster.map(\.id), ["speaker_0", "speaker_1"])
        XCTAssertEqual(roster[1].colorIndex, before["speaker_1"])
        XCTAssertEqual(roster[1].label, "Анна")
        XCTAssertTrue(roster[1].hasCustomName)
        XCTAssertEqual(roster[1].segmentCount, 2)
        XCTAssertEqual(roster[1].merged.map(\.id), ["speaker_2"])
        XCTAssertEqual(roster[0].segmentCount, 2)
    }

    /// Слияние роли не перекрашивает цель: индексы считаются по исходным id.
    func testMergingRoleKeepsTargetColor() {
        let raw = [segment("а", 0, 1, speaker: "Клиент"), segment("б", 1, 2, speaker: "Агент")]
        var edits = TranscriptEdits()
        edits.merge("Клиент", into: "Агент")
        let roster = result(raw).withEdits(edits, detail: .server).speakerRoster
        XCTAssertEqual(roster.map(\.id), ["Агент"])
        XCTAssertEqual(roster[0].colorIndex, 1)
    }

    // MARK: - Хранение

    private func decodeBody(_ json: String) throws -> TranscriptBody {
        try JSONDecoder().decode(TranscriptBody.self, from: Data(json.utf8))
    }

    private let transcriptJSON = """
    {"fullText":"Привет.","language":"ru","duration":2,
     "rawSegments":[{"speaker":"speaker_0","start":0,"end":2,"text":"Привет."}],"words":[]}
    """

    func testBodyWithoutEditsDecodes() throws {
        let body = try decodeBody(#"{"schema":1,"transcript":\#(transcriptJSON)}"#)
        XCTAssertNil(body.edits)
        XCTAssertEqual(body.makeResult(detail: .server).segments.count, 1)
    }

    /// Битые правки не стоят расшифровки.
    func testCorruptEditsBlockKeepsBody() throws {
        let body = try decodeBody(#"{"transcript":\#(transcriptJSON),"edits":"мусор"}"#)
        XCTAssertNil(body.edits)
        XCTAssertEqual(body.transcript.fullText, "Привет.")
    }

    /// Битое поле правок не стоит остальных полей.
    func testEditsDecodeFieldByField() throws {
        let json = #"{"speakerNames":{"speaker_0":"Анна"},"speakerMerges":42,"revision":3}"#
        let edits = try JSONDecoder().decode(TranscriptEdits.self, from: Data(json.utf8))
        XCTAssertEqual(edits.label(for: "speaker_0"), "Анна")
        XCTAssertTrue(edits.speakerMerges.isEmpty)
        XCTAssertEqual(edits.revision, 3)
        let empty = try JSONDecoder().decode(TranscriptEdits.self, from: Data("{}".utf8))
        XCTAssertTrue(empty.isEmpty)
    }

    func testEditsRoundTrip() throws {
        var edits = TranscriptEdits()
        edits.rename("speaker_0", to: "Анна")
        edits.merge("speaker_1", into: "speaker_0")
        edits.revision = 5
        let body = TranscriptBody(transcript: StoredTranscript(dialogue()), edits: edits)
        let decoded = try JSONDecoder().decode(TranscriptBody.self, from: JSONEncoder().encode(body))
        XCTAssertEqual(decoded, body)
        XCTAssertEqual(decoded.makeResult(detail: .medium).speakerLabel("speaker_1"), "Анна")
    }

    /// Сводка строки списка считает спикеров после слияния.
    func testSummaryCountsResolvedSpeakers() {
        var edits = TranscriptEdits()
        edits.merge("speaker_2", into: "speaker_0")
        let body = TranscriptBody(transcript: StoredTranscript(dialogue()), edits: edits)
        XCTAssertEqual(RecordSummary.make(from: body).speakerCount, 2)
    }

    /// Словарь для файлов не теряет правки: имена спикеров доходят до экспорта.
    func testDictionaryOutputKeepsEdits() {
        var edits = TranscriptEdits()
        edits.rename("speaker_0", to: "Анна")
        let out = TranscriptOutput.applyingDictionary(dialogue().withEdits(edits, detail: .server),
                                                      rules: [ReplacementRule(from: "привет", to: "Салют")])
        XCTAssertEqual(out.speakerLabel("speaker_0"), "Анна")
        XCTAssertEqual(out.segments[0].text, "Салют.")
    }

    func testSameContentIgnoresRevision() {
        var a = TranscriptEdits()
        a.rename("speaker_0", to: "Анна")
        var b = a
        b.revision = 9
        XCTAssertTrue(a.hasSameContent(as: b))
        b.rename("speaker_0", to: "Борис")
        XCTAssertFalse(a.hasSameContent(as: b))
    }
}

/// Правки через документ: единая точка сохранения в тело записи.
@MainActor
final class TranscriptDocumentEditsTests: XCTestCase {
    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("doka-edits-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeDocument() -> (TranscriptHistoryStore, TranscriptDocument, UUID) {
        let store = TranscriptHistoryStore(dataFolder: dir)
        let raw = [
            TranscriptSegment(speaker: "speaker_0", start: 0, end: 2, text: "Привет."),
            TranscriptSegment(speaker: "speaker_1", start: 2, end: 4, text: "Здравствуйте.")
        ]
        let id = store.addPending(.init(fileName: "call.mp3", provider: "builtin"))
        store.markDone(id, result: TranscriptResult(fullText: "Привет. Здравствуйте.", language: "ru",
                                                    duration: 4, segments: raw, rawSegments: raw,
                                                    words: [], llmOutput: nil))
        return (store, TranscriptDocument(recordID: id, store: store), id)
    }

    func testRenameIsSavedToBodyAndSummary() {
        let (store, document, id) = makeDocument()
        XCTAssertTrue(document.canEdit)
        document.renameSpeaker("speaker_1", to: "Анна")
        XCTAssertEqual(store.cachedBody(id)?.edits?.label(for: "speaker_1"), "Анна")
        XCTAssertEqual(store.cachedBody(id)?.edits?.revision, 1)
        XCTAssertEqual(document.output(detail: .server)?.speakerLabel("speaker_1"), "Анна")

        document.mergeSpeaker("speaker_1", into: "speaker_0")
        XCTAssertEqual(store.record(id)?.summary?.speakerCount, 1)
        XCTAssertEqual(document.output(detail: .medium)?.speakerRoster.map(\.label), ["Анна"])
    }

    /// Правка без изменений не пишет тело и не двигает счётчик.
    func testNoOpEditDoesNotBumpRevision() {
        let (store, document, id) = makeDocument()
        document.renameSpeaker("speaker_0", to: "")
        XCTAssertNil(store.cachedBody(id)?.edits)
    }

    func testResetKeepsCountingRevisions() {
        let (store, document, id) = makeDocument()
        document.renameSpeaker("speaker_0", to: "Анна")
        document.resetAllEdits()
        let edits = store.cachedBody(id)?.edits
        XCTAssertEqual(edits?.isEmpty, true)
        XCTAssertEqual(edits?.revision, 2)
        XCTAssertTrue(document.edits.isEmpty)
    }

    /// После переноса «Папки данных» библиотека заморожена — правки не принимаются.
    func testFrozenLibraryRejectsEdits() {
        let (store, document, id) = makeDocument()
        store.freeze()
        XCTAssertFalse(document.canEdit)
        document.renameSpeaker("speaker_0", to: "Анна")
        XCTAssertNil(store.cachedBody(id)?.edits)
    }
}
