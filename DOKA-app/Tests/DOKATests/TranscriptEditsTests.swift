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

    // MARK: - Материализация без правок

    /// Речь предложениями по 5 слов, слово в секунду. У слов уникальный текст
    /// («с3.1»), по нему видно, какие исходные слова попали в сегмент.
    private func sentenceWords(sentences: Int, from start: Double = 0) -> [TranscriptWord] {
        var words: [TranscriptWord] = []
        for s in 0..<sentences {
            for k in 0..<5 {
                let t = start + Double(s * 5 + k)
                let text = k == 0 ? "С\(s).\(k)" : (k == 4 ? "с\(s).\(k)." : "с\(s).\(k)")
                words.append(word(text, t, t + 0.9))
            }
        }
        return words
    }

    /// Монолог на 120 с одним сегментом — как у Parakeet.
    private func longTurn() -> TranscriptResult {
        result([segment("Серверный текст монолога.", 0, 120, speaker: "speaker_0")],
               words: sentenceWords(sentences: 24))
    }

    /// Два длинных сегмента разных спикеров со словами.
    private func longDialogue() -> TranscriptResult {
        result([segment("Первая реплика сервера.", 0, 60, speaker: "speaker_0"),
                segment("Вторая реплика сервера.", 60, 120, speaker: "speaker_1")],
               words: sentenceWords(sentences: 24))
    }

    /// Без правок — ровно прежняя нарезка на каждом уровне (регресс-гарантия).
    func testEmptyEditsMatchSplitterOnEveryLevel() {
        for r in [longTurn(), longDialogue(), dialogue()] {
            for detail in TimestampDetail.allCases {
                let edited = r.withEdits(TranscriptEdits(), detail: detail)
                let expected = detail.config.map {
                    TranscriptSegmentSplitter.split(segments: r.rawSegments, words: r.words, config: $0)
                } ?? r.rawSegments
                XCTAssertEqual(edited.segments, expected, "уровень \(detail)")
                XCTAssertEqual(edited.segmentTargets.count, edited.segments.count)
                XCTAssertTrue(edited.canEditSegments)
            }
        }
    }

    /// Адреса на любом уровне — в координатах исходных слов и без дыр.
    func testTargetsPartitionOriginalWords() {
        let r = longTurn()
        XCTAssertEqual(r.withDetail(.server).segmentTargets.map(\.anchor), [.words(0..<120)])
        let fine = r.withDetail(.fine).segmentTargets.map(\.anchor)
        XCTAssertGreaterThan(fine.count, 1)
        var next = 0
        for anchor in fine {
            guard case .words(let range) = anchor else { return XCTFail("ожидался диапазон слов") }
            XCTAssertEqual(range.lowerBound, next)
            next = range.upperBound
        }
        XCTAssertEqual(next, 120)
        // Без слов — адрес исходного сегмента.
        XCTAssertEqual(dialogue().withDetail(.medium).segmentTargets.map(\.anchor),
                       [.segment(0), .segment(1), .segment(2), .segment(3)])
    }

    // MARK: - Переназначение

    /// Фрагмент длинной реплики другому спикеру: «как сервер» честно режет
    /// реплику на A/B/A, на «Крупно» кусок B виден; возврат — исходник.
    func testReassignFragmentSplitsTurn() {
        let r = longTurn()
        let fine = r.withDetail(.fine)
        let target = fine.segmentTargets[3]
        XCTAssertEqual(target.anchor, .words(30..<40))
        var edits = TranscriptEdits()
        edits.setSpeaker("speaker_1", at: target)

        let server = r.withEdits(edits, detail: .server)
        XCTAssertEqual(server.segments.map(\.speaker), ["speaker_0", "speaker_1", "speaker_0"])
        XCTAssertEqual(server.segments[1].start, 30)
        XCTAssertEqual(server.segments[1].text, fine.segments[3].text)
        XCTAssertTrue(server.segmentTargets[1].isSpeakerOverridden)
        XCTAssertFalse(server.segmentTargets[0].isSpeakerOverridden)
        XCTAssertTrue(r.withEdits(edits, detail: .coarse).segments.contains { $0.speaker == "speaker_1" })

        edits.revertSpeaker(at: target)
        XCTAssertTrue(edits.isEmpty)
        XCTAssertEqual(r.withEdits(edits, detail: .server).segments, r.rawSegments)
    }

    /// Вырезание интервалов: переназначения делятся, на исходного спикера не хранятся.
    func testOverrideCuttingSplitsIntervals() {
        func target(_ range: Range<Int>) -> EditTarget {
            EditTarget(rawIndex: 0, anchor: .words(range), originalSpeaker: "A", isSpeakerOverridden: false)
        }
        var edits = TranscriptEdits()
        edits.setSpeaker("B", at: target(0..<10))
        edits.setSpeaker("C", at: target(3..<5))
        XCTAssertEqual(edits.speakerOverrides, [
            SpeakerOverride(anchor: .words(0..<3), speaker: "B"),
            SpeakerOverride(anchor: .words(3..<5), speaker: "C"),
            SpeakerOverride(anchor: .words(5..<10), speaker: "B")
        ])
        edits.revertSpeaker(at: target(3..<5))
        XCTAssertEqual(edits.speakerOverrides, [
            SpeakerOverride(anchor: .words(0..<3), speaker: "B"),
            SpeakerOverride(anchor: .words(5..<10), speaker: "B")
        ])
        edits.setSpeaker("A", at: target(0..<3))
        XCTAssertEqual(edits.speakerOverrides, [SpeakerOverride(anchor: .words(5..<10), speaker: "B")])
    }

    /// Бессловный результат (Nexara с анализом ИИ) — переназначение по сегменту.
    func testReassignWordlessSegment() {
        let r = dialogue()
        let target = r.withDetail(.server).segmentTargets[1]
        var edits = TranscriptEdits()
        edits.setSpeaker("speaker_0", at: target)
        for detail in TimestampDetail.allCases {
            XCTAssertEqual(speakers(r.withEdits(edits, detail: detail)),
                           ["speaker_0", "speaker_0", "speaker_2", "speaker_0"])
        }
        edits.revertSpeaker(at: target)
        XCTAssertEqual(r.withEdits(edits, detail: .server).segments, r.rawSegments)
    }

    /// Переназначение на влитого следует за слиянием; после «Отделить» —
    /// снова он сам.
    func testOverrideFollowsMerge() {
        let r = longDialogue()
        let target = r.withDetail(.fine).segmentTargets[0]
        var edits = TranscriptEdits()
        edits.setSpeaker("speaker_2", at: target)
        edits.merge("speaker_2", into: "speaker_1")
        XCTAssertEqual(r.withEdits(edits, detail: .server).segments.first?.speaker, "speaker_1")
        edits.unmerge("speaker_2")
        XCTAssertEqual(r.withEdits(edits, detail: .server).segments.first?.speaker, "speaker_2")
    }

    /// Влили переназначенного обратно в исходного — кусок склеивается с
    /// соседями, и сегмент снова один, с текстом сервера.
    func testOverrideMergedIntoOriginalCollapses() {
        let r = longTurn()
        var edits = TranscriptEdits()
        edits.setSpeaker("speaker_1", at: r.withDetail(.fine).segmentTargets[2])
        edits.merge("speaker_1", into: "speaker_0")
        XCTAssertEqual(r.withEdits(edits, detail: .server).segments, r.rawSegments)
    }

    /// Идемпотентность с правками: перенарезка всегда от исходников.
    func testWithDetailIsIdempotentWithEdits() {
        let r = longDialogue()
        var edits = TranscriptEdits()
        edits.setSpeaker("speaker_1", at: r.withDetail(.fine).segmentTargets[1])
        edits.rename("speaker_1", to: "Анна")
        for detail in TimestampDetail.allCases {
            let once = r.withEdits(edits, detail: detail)
            XCTAssertEqual(once.withDetail(detail), once)
        }
        XCTAssertEqual(r.withEdits(edits, detail: .fine).withDetail(.server).segments,
                       r.withEdits(edits, detail: .server).segments)
    }

    func testNextSpeakerID() {
        XCTAssertEqual(SpeakerName.nextID(existing: ["speaker_0", "speaker_1"]), "speaker_2")
        XCTAssertEqual(SpeakerName.nextID(existing: ["Клиент", "Агент"]), "speaker_0")
        // Ключ слияния учитывается: иначе новый спикер получил бы id влитого.
        var edits = TranscriptEdits()
        edits.merge("speaker_2", into: "speaker_0")
        let raw = [segment("а", 0, 1, speaker: "speaker_0"), segment("б", 1, 2, speaker: "speaker_1"),
                   segment("в", 2, 3, speaker: "speaker_2")]
        let known = edits.knownSpeakerIDs(rawSegments: Array(raw.prefix(2)))
        XCTAssertEqual(SpeakerName.nextID(existing: known), "speaker_3")
    }

    /// «Новый спикер» в записи с ролями не делит цвет с ролями.
    func testNewSpeakerInRolesRecordHasOwnColor() {
        let r = result([segment("а", 0, 1, speaker: "Клиент"), segment("б", 1, 2, speaker: "Агент")])
        var edits = TranscriptEdits()
        let newID = SpeakerName.nextID(existing: edits.knownSpeakerIDs(rawSegments: r.rawSegments))
        edits.setSpeaker(newID, at: r.withDetail(.server).segmentTargets[1])
        let roster = r.withEdits(edits, detail: .server).speakerRoster
        XCTAssertEqual(roster.map(\.id), ["Клиент", newID])
        XCTAssertEqual(Set(r.withEdits(edits, detail: .server).speakerColorIndices.values).count, 3)
    }

    /// Пересекающиеся и битые переназначения при чтении отбрасываются поштучно.
    func testOverlappingOverridesAreDroppedOnDecode() throws {
        let json = #"""
        {"speakerOverrides":[{"anchor":{"w":[0,10]},"speaker":"B"},{"anchor":{"w":[5,8]},"speaker":"C"},
         {"anchor":{"w":[9,3]},"speaker":"D"},{"anchor":{"s":2},"speaker":"E"},{"speaker":"F"}]}
        """#
        let edits = try JSONDecoder().decode(TranscriptEdits.self, from: Data(json.utf8))
        XCTAssertEqual(edits.speakerOverrides, [SpeakerOverride(anchor: .words(0..<10), speaker: "B"),
                                                SpeakerOverride(anchor: .segment(2), speaker: "E")])
        let roundTrip = try JSONDecoder().decode(TranscriptEdits.self, from: JSONEncoder().encode(edits))
        XCTAssertEqual(roundTrip, edits)
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

    /// «Новый спикер» получает свободный id, реплика — его имя по умолчанию.
    func testReassignToNewSpeaker() {
        let (store, document, id) = makeDocument()
        guard let target = document.output(detail: .server)?.segmentTargets.first else {
            return XCTFail("нет адресов сегментов")
        }
        document.reassignSegment(at: target, to: nil)
        let output = document.output(detail: .server)
        XCTAssertEqual(output?.segments.first?.speaker, "speaker_2")
        XCTAssertEqual(output?.segmentTargets.first?.isSpeakerOverridden, true)
        // Единственная реплика speaker_0 ушла новому спикеру — в сводке двое.
        XCTAssertEqual(output?.speakerRoster.map(\.id), ["speaker_2", "speaker_1"])
        XCTAssertEqual(store.record(id)?.summary?.speakerCount, 2)
        document.revertSegmentSpeaker(at: target)
        XCTAssertEqual(document.output(detail: .server)?.segments.first?.speaker, "speaker_0")
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
