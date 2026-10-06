import XCTest
@testable import DOKA

/// «Угадать имена»: вход модели с метками S1…Sn и разбор её ответа. Лишнее
/// предложение хуже пропущенного — всё сомнительное должно отбрасываться.
final class SpeakerNameSuggesterTests: XCTestCase {
    private func segment(_ speaker: String, _ start: Double, _ text: String) -> TranscriptSegment {
        TranscriptSegment(speaker: speaker, start: start, end: start + 4, text: text)
    }

    private func result(edits: TranscriptEdits = TranscriptEdits()) -> TranscriptResult {
        let segments = [
            segment("speaker_0", 0, "Всем привет, меня зовут Аня, я веду встречу."),
            segment("speaker_1", 5, "Привет. Паша, расскажешь про релиз?"),
            // Разметка разрезала Пашу посреди фразы: speaker_3 — его продолжение.
            segment("speaker_2", 10, "Да, сборка готова, осталось дождаться"),
            segment("speaker_3", 15, "финальных текстов, и можно выпускать."),
            segment("speaker_1", 20, "Отлично."),
        ]
        let base = TranscriptResult(fullText: "", language: "ru", duration: 30, segments: segments,
                                    rawSegments: segments, words: [], llmOutput: nil)
        return base.withEdits(edits, detail: .server)
    }

    private func prepared(edits: TranscriptEdits = TranscriptEdits()) throws -> SpeakerNameSuggester.Prepared {
        let r = result(edits: edits)
        return try XCTUnwrap(SpeakerNameSuggester.prepare(result: r, roster: r.speakerRoster))
    }

    // MARK: - Вход

    func testInputUsesShortTagsInRosterOrder() throws {
        let p = try prepared()
        XCTAssertEqual(p.speakers.map(\.tag), ["S1", "S2", "S3", "S4"])
        XCTAssertEqual(p.speakers.map(\.id), ["speaker_0", "speaker_1", "speaker_2", "speaker_3"])
        XCTAssertEqual(p.lines.first?.rendered, "[0:00] S1: Всем привет, меня зовут Аня, я веду встречу.")
        let prompt = SpeakerNameSuggester.messages(for: p).map(\.content).joined()
        XCTAssertTrue(prompt.contains("[0:05] S2: Привет. Паша, расскажешь про релиз?"))
        XCTAssertFalse(prompt.contains("speaker_"), "id диаризации модели не показываются")
    }

    func testUserNamedSpeakerIsMarkedInPrompt() throws {
        var edits = TranscriptEdits()
        edits.rename("speaker_0", to: "Анна")
        let p = try prepared(edits: edits)
        XCTAssertTrue(p.speakers[0].hasCustomName)
        let prompt = SpeakerNameSuggester.messages(for: p).map(\.content).joined()
        XCTAssertTrue(prompt.contains("S1 — 1 реплика, имя уже задано пользователем: «Анна»"))
        XCTAssertTrue(prompt.contains("S2 — 2 реплики"))
    }

    func testMergedSpeakersShareOneTag() throws {
        var edits = TranscriptEdits()
        edits.merge("speaker_3", into: "speaker_2")
        let p = try prepared(edits: edits)
        XCTAssertEqual(p.speakers.map(\.id), ["speaker_0", "speaker_1", "speaker_2"])
    }

    func testNoSpeakersNothingToSuggest() {
        let segments = [TranscriptSegment(speaker: nil, start: 0, end: 3, text: "Монолог без разметки.")]
        let r = TranscriptResult(fullText: "", language: "ru", duration: 3, segments: segments,
                                 rawSegments: segments, words: [], llmOutput: nil)
        XCTAssertNil(SpeakerNameSuggester.prepare(result: r, roster: r.speakerRoster))
    }

    func testFittingLineCountStopsBeforeBudget() {
        XCTAssertEqual(SpeakerNameSuggester.fittingLineCount(tokenCounts: [10, 10, 10], budget: 100), 3)
        XCTAssertEqual(SpeakerNameSuggester.fittingLineCount(tokenCounts: [10, 10, 10], budget: 22), 2)
        XCTAssertEqual(SpeakerNameSuggester.fittingLineCount(tokenCounts: [50], budget: 10), 0)
    }

    // MARK: - Разбор

    func testNamesFromRulesAndMergeFromCut() throws {
        let p = try prepared()
        let answer = """
        ```json
        {"names":[{"name":"Аня","time":"0:00"},{"name":"Паша","time":"0:05"}],"merge":[["S4","S3"]]}
        ```
        """
        let s = SpeakerNameSuggester.parse(answer, prepared: p)
        XCTAssertEqual(s.names.map(\.speakerID), ["speaker_0", "speaker_2"])
        XCTAssertEqual(s.names.map(\.name), ["Аня", "Паша"])
        XCTAssertEqual(s.names.first?.time, 0)
        XCTAssertEqual(s.names.first?.quote, "Всем привет, меня зовут Аня, я веду встречу.")
        // «Паша, расскажешь…?» сказал S2 — имя того, кто ответил следом.
        XCTAssertEqual(s.names.last?.time, 5)
        // У S3 и S4 по одной реплике: цель — появившийся раньше (S3). Слияния
        // модели не спрашиваем — признак разреза ищет код.
        XCTAssertEqual(s.merges.map { [$0.sourceID, $0.targetID] }, [["speaker_3", "speaker_2"]])
        XCTAssertEqual(s.merges.first?.time, 15)
        XCTAssertEqual(s.merges.first?.quote, "…сборка готова, осталось дождаться / финальных текстов, и можно…")
    }

    func testDropsDoubtfulEntries() throws {
        var edits = TranscriptEdits()
        edits.rename("speaker_0", to: "Анна")
        let p = try prepared(edits: edits)
        let answer = """
        Вот ответ: {"names":[
          {"name":"Аня"}, {"name":"Игорь"}, {"name":"Неизвестно"}, {"name":"Спикер 2"},
          {"name":"Паша"}, {"name":"паша"}, {"name":"Агент 007"}, {"name":""},
          {"name":"\(String(repeating: "я", count: 200))"}, {"time":"0:05"}
        ],"merge":[["S1","S2"]]} Готово.
        """
        let s = SpeakerNameSuggester.parse(answer, prepared: p)
        // «Аня» — у S1 уже имя от пользователя; «Игоря» в тексте нет;
        // заглушки, повтор и мусор отброшены.
        XCTAssertEqual(s.names.map(\.name), ["Паша"])
        XCTAssertEqual(s.names.map(\.speakerID), ["speaker_2"])
        // Слияние от модели («S1+S2») игнорируется — только разрез фразы.
        XCTAssertEqual(s.merges.map { [$0.sourceID, $0.targetID] }, [["speaker_3", "speaker_2"]])
    }

    // MARK: - Дубликаты

    private func prepared(_ speakers: [(String, Int, Bool)], _ turns: [(String, String)]) -> SpeakerNameSuggester.Prepared {
        let list = speakers.enumerated().map { index, item in
            SpeakerNameSuggester.Speaker(id: item.0, tag: "S\(index + 1)", label: item.2 ? "Игорь" : "Спикер",
                                         hasCustomName: item.2, segmentCount: item.1)
        }
        return SpeakerNameSuggester.Prepared(speakers: list, lines: lines(turns), duration: 60)
    }

    func testCutGoesToSpeakerWithMoreReplicas() {
        let p = prepared([("a", 1, false), ("b", 5, false)],
                         [("S1", "Мы решили, что релиз будет"), ("S2", "в понедельник, после тестов.")])
        let merges = SpeakerNameSuggester.continuationMerges(prepared: p, names: [])
        XCTAssertEqual(merges.map { [$0.sourceID, $0.targetID] }, [["a", "b"]])
    }

    func testFinishedSentencesAreNotCuts() {
        let p = prepared([("a", 1, false), ("b", 1, false)],
                         [("S1", "Мы решили, что релиз в пятницу."), ("S2", "да, согласен."),
                          ("S1", "Хорошо, тогда так"), ("S2", "Вопросов нет.")])
        XCTAssertTrue(SpeakerNameSuggester.continuationMerges(prepared: p, names: []).isEmpty)
    }

    func testDifferentNamesAreDifferentPeople() {
        let p = prepared([("a", 2, true), ("b", 1, false)],
                         [("S1", "Осталось дождаться"), ("S2", "финальных текстов.")])
        let named = [SpeakerNameSuggester.NameSuggestion(speakerID: "b", name: "Анна", quote: nil, time: nil)]
        XCTAssertTrue(SpeakerNameSuggester.continuationMerges(prepared: p, names: named).isEmpty)
        let same = [SpeakerNameSuggester.NameSuggestion(speakerID: "b", name: "игорь", quote: nil, time: nil)]
        XCTAssertEqual(SpeakerNameSuggester.continuationMerges(prepared: p, names: same).count, 1)
    }

    func testEachSpeakerInOnePairOnly() {
        let p = prepared([("a", 3, false), ("b", 1, false), ("c", 1, false)],
                         [("S1", "Значит, делаем"), ("S2", "так, как договорились"), ("S3", "вчера на встрече."),
                          ("S1", "И ещё одно"), ("S2", "дело.")])
        let merges = SpeakerNameSuggester.continuationMerges(prepared: p, names: [])
        // a–b разрезаны дважды — эта пара сильнее, c с уже занятым b не склеиваем.
        XCTAssertEqual(merges.map { [$0.sourceID, $0.targetID] }, [["b", "a"]])
    }

    // MARK: - Правила принадлежности

    private func lines(_ turns: [(String, String)]) -> [TranscriptLLMInput.Line] {
        turns.enumerated().map { index, turn in
            TranscriptLLMInput.Line(start: Double(index * 5), end: Double(index * 5 + 4), speaker: turn.0,
                                    text: turn.1, rendered: "[\(index * 5)] \(turn.0): \(turn.1)")
        }
    }

    func testIntroductionBelongsToSpeaker() {
        let l = lines([("S1", "Добрый день. Меня зовут Анна, я веду встречу."), ("S2", "Привет.")])
        let a = SpeakerNameSuggester.attribute(name: "Анна", lines: l)
        XCTAssertEqual(a?.tag, "S1")
        XCTAssertEqual(a?.score, SpeakerNameSuggester.introductionScore)
        XCTAssertEqual(SpeakerNameSuggester.attribute(name: "Игорь", lines: lines([("S1", "Я Игорь."), ("S2", "Ок.")]))?.tag, "S1")
    }

    func testFalseIntroductionsDoNotCount() {
        XCTAssertNil(SpeakerNameSuggester.attribute(name: "Марина", lines: lines([("S1", "Вчера я Марину спросила про отчёт.")])))
        XCTAssertNil(SpeakerNameSuggester.attribute(name: "Марина", lines: lines([("S1", "Это Марина сделала макеты.")])))
        XCTAssertNil(SpeakerNameSuggester.attribute(name: "Анна", lines: lines([("S1", "Её зовут Анной.")])))
    }

    func testAddressAtEndGoesToNextSpeaker() {
        let l = lines([("S1", "Сборка готова. Игорь, расскажешь про тесты?"), ("S2", "Да, всё зелёное.")])
        XCTAssertEqual(SpeakerNameSuggester.attribute(name: "Игорь", lines: l)?.tag, "S2")
        let question = lines([("S1", "Паша, ты как?"), ("S2", "Нормально.")])
        XCTAssertEqual(SpeakerNameSuggester.attribute(name: "Паша", lines: question)?.tag, "S2")
    }

    func testAddressAtStartGoesToPreviousSpeaker() {
        let l = lines([("S1", "Как дела со сборкой?"), ("S2", "Да, Анна. Сборка готова к среде.")])
        XCTAssertEqual(SpeakerNameSuggester.attribute(name: "Анна", lines: l)?.tag, "S1")
        let thanks = lines([("S1", "Отчёт пришлю завтра."), ("S2", "Спасибо, Игорь.")])
        XCTAssertEqual(SpeakerNameSuggester.attribute(name: "Игорь", lines: thanks)?.tag, "S1")
    }

    func testMentionGivesNoVote() {
        let l = lines([("S1", "А Марина в курсе?"), ("S2", "Да, Марина пришлёт отчёт в пятницу.")])
        XCTAssertNil(SpeakerNameSuggester.attribute(name: "Марина", lines: l))
    }

    func testTiedVotesAreNotGuessed() {
        // Одно имя по обращениям указывает на двух разных спикеров поровну.
        let l = lines([("S1", "Игорь, начнёшь?"), ("S2", "Давай. Игорь, а ты потом?"), ("S3", "Хорошо.")])
        XCTAssertNil(SpeakerNameSuggester.attribute(name: "Игорь", lines: l))
    }

    func testSameNameToleratesCaseEndings() {
        XCTAssertTrue(SpeakerNameSuggester.sameName("Игорю", "Игорь"))
        XCTAssertTrue(SpeakerNameSuggester.sameName("анну", "Анна"))
        XCTAssertTrue(SpeakerNameSuggester.sameName("Алёна", "Алена"))
        XCTAssertFalse(SpeakerNameSuggester.sameName("Аня", "Анна"))
        XCTAssertFalse(SpeakerNameSuggester.sameName("Иван", "Ивановский"))
    }

    func testGarbageAnswerGivesNoNames() throws {
        let p = try prepared()
        for garbage in ["Имён не нашлось.", #"{"names": "нет"}"#, #"{"names":[{"name":"Аня""#] {
            let s = SpeakerNameSuggester.parse(garbage, prepared: p)
            XCTAssertTrue(s.names.isEmpty, garbage)
            XCTAssertEqual(s.merges.count, 1, "разрез фразы находится и без ответа модели")
        }
    }

    func testOneBrokenNameDoesNotLoseOthers() throws {
        let p = try prepared()
        let answer = #"{"names":[{"name":true},{"name":"Паша"}],"merge":[]}"#
        XCTAssertEqual(SpeakerNameSuggester.parse(answer, prepared: p).names.map(\.name), ["Паша"])
    }

    func testTimeParsing() {
        XCTAssertEqual(SpeakerNameSuggester.parseTime("1:05", limit: nil), 65)
        XCTAssertEqual(SpeakerNameSuggester.parseTime("[1:02:03]", limit: nil), 3723)
        XCTAssertNil(SpeakerNameSuggester.parseTime("1:75", limit: nil))
        XCTAssertNil(SpeakerNameSuggester.parseTime("около минуты", limit: nil))
        XCTAssertNil(SpeakerNameSuggester.parseTime("9:00", limit: 30), "за пределами записи")
    }

    func testFirstJSONObjectRespectsStrings() {
        XCTAssertEqual(SpeakerNameSuggester.firstJSONObject(in: #"а {"q":"}{"} б"#), #"{"q":"}{"}"#)
        XCTAssertEqual(SpeakerNameSuggester.firstJSONObject(in: #"{"a":{"b":1}} {"c":2}"#), #"{"a":{"b":1}}"#)
        XCTAssertNil(SpeakerNameSuggester.firstJSONObject(in: "{не закрыт"))
    }
}
