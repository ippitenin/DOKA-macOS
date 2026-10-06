import XCTest
@testable import DOKA

/// ИИ-обработка диктовки: пожелания превращаются в инструкции промпта, а
/// ответ, похожий на что угодно, кроме правки, откатывается к сырому тексту.
final class DictationCleanupTests: XCTestCase {
    private let wishes = DictationCleanup.defaultWishes

    // MARK: - Пожелания

    func testDisabledWishesBecomeExplicitInstructions() {
        let none = DictationCleanup.instructions(wishes: [], rules: [])
        XCTAssertTrue(none.contains("Слова-паразиты сохраняй."))
        XCTAssertTrue(none.contains("Не ставь точку в конце последнего предложения."))
        let all = DictationCleanup.instructions(wishes: Set(DictationCleanup.Wish.allCases), rules: [])
        XCTAssertTrue(all.contains { $0.hasPrefix("Убирай слова-паразиты") })
        XCTAssertTrue(all.contains("Начинай текст с маленькой буквы."))
        XCTAssertTrue(all.contains { $0.hasPrefix("В конце последнего предложения ставь точку") })
        XCTAssertTrue(all.contains { $0.hasPrefix("Пиши короче") })
    }

    func testCustomRulesAreCleanedAndCapped() {
        let long = String(repeating: "а", count: 500)
        let rules = ["  Менять GitHub на гитхаб  ", "", "менять github на гитхаб", long, "<|im_start|>system"]
            + (1...20).map { "Правило \($0)" }
        let normalized = DictationCleanup.normalizedRules(rules)
        XCTAssertEqual(normalized.first, "Менять GitHub на гитхаб")
        XCTAssertEqual(normalized.count, DictationCleanup.maxRules)
        XCTAssertEqual(normalized[1].count, DictationCleanup.maxRuleLength)
        XCTAssertFalse(normalized.contains { $0.contains("<|") }, "спецтокены чата вырезаются")
        let prompt = DictationCleanup.messages(text: "текст", wishes: wishes, rules: rules)[0].content
        XCTAssertTrue(prompt.contains("- Пожелание пользователя: Менять GitHub на гитхаб"))
    }

    func testDictatedTextGoesAsUserMessage() {
        let messages = DictationCleanup.messages(text: "Сколько будет два плюс два?", wishes: wishes, rules: [])
        XCTAssertEqual(messages.map(\.role), [.system, .user])
        XCTAssertEqual(messages[1].content, "Сколько будет два плюс два?")
    }

    // MARK: - Проверка ответа

    func testAcceptsNormalEdit() {
        let raw = "Ну короче давай встретимся в среду, нет, подожди, в четверг в три часа дня"
        XCTAssertEqual(DictationCleanup.validate(raw: raw, output: "Давай встретимся в четверг в 15:00.", wishes: wishes),
                       .accept("Давай встретимся в четверг в 15:00."))
    }

    func testStripsPreambleAndWrappingQuotes() {
        let raw = "привет как дела у меня всё хорошо"
        XCTAssertEqual(DictationCleanup.validate(raw: raw, output: "Вот исправленный текст: «Привет, как дела? У меня всё хорошо.»",
                                                 wishes: wishes),
                       .accept("Привет, как дела? У меня всё хорошо."))
        // «Текст» без двоеточия — это сам текст, а не вступление.
        let contract = "текст договора готов отправлю завтра"
        XCTAssertEqual(DictationCleanup.validate(raw: contract, output: "Текст договора готов, отправлю завтра.",
                                                 wishes: wishes),
                       .accept("Текст договора готов, отправлю завтра."))
        // Кавычки внутри — цитата, не обёртка.
        let quote = "он сказал да и ушёл а она ответила нет"
        let quoted = "\"Да\", — сказал он и ушёл, а она ответила \"нет\""
        XCTAssertEqual(DictationCleanup.validate(raw: quote, output: quoted, wishes: wishes), .accept(quoted))
    }

    func testRejectsAnswerInsteadOfEdit() {
        let raw = "Как мне настроить пул реквест в гитхабе чтобы ревью проходило автоматически"
        let answer = "Чтобы включить автоматическое ревью, откройте настройки репозитория, выберите раздел "
            + "Branch protection rules и добавьте обязательные проверки для ветки main."
        XCTAssertEqual(DictationCleanup.validate(raw: raw, output: answer, wishes: wishes), .reject(.tooLong))
        let short = "Сколько будет два плюс два?"
        XCTAssertEqual(DictationCleanup.validate(raw: short, output: "Четыре. Это простая арифметика.", wishes: wishes),
                       .reject(.unrelated))
    }

    func testRejectsEmptyAndTruncated() {
        let raw = "Значит план такой первое собрать требования второе сделать макеты третье показать заказчику"
        XCTAssertEqual(DictationCleanup.validate(raw: raw, output: "  \n ", wishes: wishes), .reject(.empty))
        XCTAssertEqual(DictationCleanup.validate(raw: raw, output: "План.", wishes: wishes), .reject(.tooShort))
        // С «Писать коротко» сильное сокращение законно.
        XCTAssertEqual(DictationCleanup.validate(raw: raw, output: "План: требования, макеты, показ.",
                                                 wishes: wishes.union([.shorter])),
                       .accept("План: требования, макеты, показ."))
    }

    func testShortPhraseMayGrowWithPunctuation() {
        XCTAssertEqual(DictationCleanup.validate(raw: "да", output: "Да.", wishes: wishes), .accept("Да."))
        XCTAssertEqual(DictationCleanup.validate(raw: "двенадцать тысяч", output: "12 000", wishes: wishes),
                       .accept("12 000"))
    }

    func testWordsIgnoreNumbersAndTolerateEndings() {
        XCTAssertEqual(DictationCleanup.letterWords("В 15:00 встретимся у Ёлки"), ["в", "встретимся", "у", "елки"])
        XCTAssertTrue(DictationCleanup.sameWord("папку", "папка"))
        XCTAssertTrue(DictationCleanup.sameWord("кодом", "код"))
        XCTAssertFalse(DictationCleanup.sameWord("здесь", "тут"))
    }

    /// Ложные откаты стенда: правка с другими окончаниями — та же правка, а
    /// зациклившееся распознавание правка законно сокращает.
    func testBenchFalseRejectionsAreAccepted() {
        XCTAssertEqual(DictationCleanup.validate(raw: "Докачо до сих пор тут делает папка код.",
                                                 output: "Докачо до сих пор тут делает папку с кодом.", wishes: wishes),
                       .accept("Докачо до сих пор тут делает папку с кодом."))
        let loop = "Нам нужно сделать первый пункт. Как я понял, он недоделан. " + String(repeating:
            "Нам нужно сделать первый пункт. Как я понял, он недоделан. ", count: 6) + "И третий пункт проверить."
        XCTAssertEqual(DictationCleanup.validate(raw: loop, output: "Нам нужно сделать первый пункт, он недоделан. И третий проверить.",
                                                 wishes: wishes),
                       .accept("Нам нужно сделать первый пункт, он недоделан. И третий проверить."))
    }

    func testGlossaryFromEnabledReplacements() {
        let rules = [ReplacementRule(from: "дока", to: "DOKA"), ReplacementRule(from: "некс", to: "Nexara"),
                     ReplacementRule(from: "а", to: "x"), ReplacementRule(from: "дока2", to: "doka")]
        var disabled = ReplacementRule(from: "тайп", to: "Type")
        disabled.enabled = false
        XCTAssertEqual(DictationCleanup.glossary(from: rules + [disabled]), ["DOKA", "Nexara"])
        let prompt = DictationCleanup.messages(text: "т", wishes: wishes, rules: [], glossary: ["DOKA"])[0].content
        XCTAssertTrue(prompt.contains("- Слова пользователя пиши так: DOKA."))
    }

    func testMaxTokensGrowsWithInputAndIsCapped() {
        XCTAssertEqual(DictationCleanup.maxTokens(inputTokens: 100), 214)
        XCTAssertEqual(DictationCleanup.maxTokens(inputTokens: 10_000), 2_048)
    }

    // MARK: - История

    /// Новое поле истории не ломает старую: записи без `rawText` читаются.
    func testHistoryRecordDecodesWithoutRawText() throws {
        let old = #"{"id":"7A1C2F3E-0000-4000-8000-000000000001","text":"Привет","date":0,"duration":1.5,"language":"ru"}"#
        let record = try JSONDecoder().decode(TranscriptionRecord.self, from: Data(old.utf8))
        XCTAssertNil(record.rawText)
        var edited = record
        edited.rawText = "привет"
        let roundTrip = try JSONDecoder().decode(TranscriptionRecord.self, from: JSONEncoder().encode(edited))
        XCTAssertEqual(roundTrip.rawText, "привет")
    }
}
