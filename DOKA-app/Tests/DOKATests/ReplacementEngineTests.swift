import XCTest
@testable import DOKA

/// Словарь автозамен применяется к каждой диктовке перед вставкой, поэтому
/// его ошибки портят текст молча — пользователь видит уже испорченный результат.
final class ReplacementEngineTests: XCTestCase {

    private func rule(_ from: String, _ to: String, enabled: Bool = true) -> ReplacementRule {
        ReplacementRule(from: from, to: to, enabled: enabled)
    }

    func testAppliesSimpleReplacement() {
        let result = ReplacementEngine.apply("привет мир", rules: [rule("мир", "земля")])
        XCTAssertEqual(result, "привет земля")
    }

    func testIsCaseInsensitive() {
        // Не с начала текста: там замена получила бы заглавную (тест ниже).
        let result = ReplacementEngine.apply("а Привет ПРИВЕТ привет", rules: [rule("привет", "hi")])
        XCTAssertEqual(result, "а hi hi hi")
    }

    /// Замена со строчной в начале предложения получает заглавную — иначе
    /// «Stories тоже сделаем» с «Stories» → «сторис» вставлялось бы как
    /// «сторис тоже сделаем». В середине предложения — как в правиле.
    func testCapitalizesReplacementAtSentenceStart() {
        let rules = [rule("Stories", "сторис")]
        XCTAssertEqual(ReplacementEngine.apply("Stories тоже сделаем. Потом Stories выложим.", rules: rules),
                       "Сторис тоже сделаем. Потом сторис выложим.")
    }

    func testSentenceStartAfterEndsNewlineAndQuotes() {
        let rules = [rule("Reels", "рилс")]
        XCTAssertEqual(ReplacementEngine.apply("Ура! Reels вышел", rules: rules), "Ура! Рилс вышел")
        XCTAssertEqual(ReplacementEngine.apply("Что? Reels", rules: rules), "Что? Рилс")
        XCTAssertEqual(ReplacementEngine.apply("Так… Reels", rules: rules), "Так… Рилс")
        XCTAssertEqual(ReplacementEngine.apply("строка\nReels", rules: rules), "строка\nРилс")
        XCTAssertEqual(ReplacementEngine.apply("Готово. «Reels вышел»", rules: rules), "Готово. «Рилс вышел»")
        XCTAssertEqual(ReplacementEngine.apply("Он сказал: «Reels вышел»", rules: rules), "Он сказал: «рилс вышел»",
                       "после двоеточия — не начало предложения")
    }

    /// Whisper пишет «Reels» с заглавной и посреди фразы — там правило
    /// просит строчную, и заглавная не переносится.
    func testMidSentenceKeepsRuleCase() {
        XCTAssertEqual(ReplacementEngine.apply("вышел Reels, и всё", rules: [rule("Reels", "рилс")]),
                       "вышел рилс, и всё")
    }

    /// Замена, которая сама начинается с заглавной или не с буквы, остаётся
    /// как в правиле, а строчное найденное в начале — тоже.
    func testOnlyLowercaseReplacementOfCapitalizedMatchChanges() {
        XCTAssertEqual(ReplacementEngine.apply("Телеграм лежит.", rules: [rule("телеграм", "Telegram")]),
                       "Telegram лежит.")
        XCTAssertEqual(ReplacementEngine.apply("Апи отдаёт ошибку.", rules: [rule("апи", "API")]),
                       "API отдаёт ошибку.")
        XCTAssertEqual(ReplacementEngine.apply("э-э, привет", rules: [rule("э-э, ", "")]), "привет")
        XCTAssertEqual(ReplacementEngine.apply("prompt готов", rules: [rule("prompt", "промпт")]), "промпт готов")
    }

    /// Однобуквенный нормализатор сохраняет регистр где угодно: «Ёлка» → «Елка».
    func testSingleCharacterRuleKeepsCase() {
        let rule = ReplacementRule(from: "ё", to: "е", matchInsideWords: true)
        XCTAssertEqual(ReplacementEngine.apply("Ёлка и ёж, ЁЖ", rules: [rule]), "Елка и еж, ЕЖ")
    }

    /// Словарь на выходном слое файлов применяется на каждом рендере —
    /// повторный проход не должен ничего менять.
    func testCapitalizationIsIdempotent() {
        let rules = [rule("Stories", "сторис"), ReplacementRule(from: "ё", to: "е", matchInsideWords: true)]
        let once = ReplacementEngine.apply("Stories готовы. Ёлка и Stories.", rules: rules)
        XCTAssertEqual(once, "Сторис готовы. Елка и сторис.")
        XCTAssertEqual(ReplacementEngine.apply(once, rules: rules), once)
    }

    func testSkipsDisabledRules() {
        let result = ReplacementEngine.apply("привет", rules: [rule("привет", "hi", enabled: false)])
        XCTAssertEqual(result, "привет")
    }

    func testEmptyFromIsIgnored() {
        // Пустой шаблон при наивной реализации вставляется между каждым символом.
        let result = ReplacementEngine.apply("текст", rules: [rule("", "X")])
        XCTAssertEqual(result, "текст")
    }

    /// Ключевой инвариант: длинные шаблоны применяются первыми, иначе короткое
    /// правило разорвёт совпадение длинного и длинное больше не сработает.
    func testLongerPatternsWinOverShorter() {
        let rules = [rule("нью", "new"), rule("нью-йорк", "New York")]
        XCTAssertEqual(ReplacementEngine.apply("нью-йорк", rules: rules), "New York")
    }

    /// Замена, содержащая собственный шаблон, не должна зацикливаться:
    /// вставленный текст повторно не сканируется.
    func testReplacementContainingPatternDoesNotLoop() {
        let result = ReplacementEngine.apply("кот", rules: [rule("кот", "кот и пёс")])
        XCTAssertEqual(result, "кот и пёс")
    }

    func testMultipleOccurrencesAllReplaced() {
        let result = ReplacementEngine.apply("да да да", rules: [rule("да", "нет")])
        XCTAssertEqual(result, "нет нет нет")
    }

    func testRulesApplySequentially() {
        let rules = [rule("а", "б"), rule("б", "в")]
        // «а» → «б», затем «б» → «в»: обе замены проходят по всей строке.
        XCTAssertEqual(ReplacementEngine.apply("а", rules: rules), "в")
    }

    func testEmptyRulesReturnTextUnchanged() {
        XCTAssertEqual(ReplacementEngine.apply("текст без правил", rules: []), "текст без правил")
    }

    func testEmptyTextStaysEmpty() {
        XCTAssertEqual(ReplacementEngine.apply("", rules: [rule("а", "б")]), "")
    }

    /// Замена на пустую строку — легальный способ вычистить слово-паразит.
    func testReplacingWithEmptyStringDeletesMatch() {
        let result = ReplacementEngine.apply("это, э-э, работает", rules: [rule("э-э, ", "")])
        XCTAssertEqual(result, "это, работает")
    }

    // MARK: - Границы слов

    /// Исходный баг: пример из самого UI («дока» → «DOKA») портил «документ».
    func testDoesNotReplaceInsideWord() {
        XCTAssertEqual(ReplacementEngine.apply("документ", rules: [rule("дока", "DOKA")]), "документ")
    }

    func testReplacesOnlyWholeWordInMixedText() {
        let result = ReplacementEngine.apply("документ дока, привет", rules: [rule("дока", "DOKA")])
        XCTAssertEqual(result, "документ DOKA, привет")
    }

    func testReplacesWordFollowedByPunctuation() {
        XCTAssertEqual(ReplacementEngine.apply("Дока, привет", rules: [rule("дока", "DOKA")]), "DOKA, привет")
    }

    func testBoundariesAtStringEdges() {
        XCTAssertEqual(ReplacementEngine.apply("дока", rules: [rule("дока", "DOKA")]), "DOKA")
        XCTAssertEqual(ReplacementEngine.apply("это дока", rules: [rule("дока", "DOKA")]), "это DOKA")
    }

    func testMultiwordPhrase() {
        let rules = [rule("нью йорк", "Нью-Йорк")]
        XCTAssertEqual(ReplacementEngine.apply("в нью йорк.", rules: rules), "в Нью-Йорк.")
        XCTAssertEqual(ReplacementEngine.apply("в нью йорке", rules: rules), "в нью йорке")
    }

    func testDigitsAreWordCharacters() {
        XCTAssertEqual(ReplacementEngine.apply("2024 и 2", rules: [rule("2", "два")]), "2024 и два")
    }

    /// С границами правило вида «ai» → «OpenAI» больше не пожирает собственный
    /// результат при повторном прогоне (словарь для файлов применяется на
    /// каждом рендере).
    func testIdempotentForBoundedRules() {
        let rules = [rule("ai", "OpenAI")]
        let once = ReplacementEngine.apply("use ai now", rules: rules)
        XCTAssertEqual(once, "use OpenAI now")
        XCTAssertEqual(ReplacementEngine.apply(once, rules: rules), once)
    }

    func testPunctuationEdgedPatternMatchesAnywhere() {
        XCTAssertEqual(ReplacementEngine.apply("ок:)", rules: [rule(":)", "🙂")]), "ок🙂")
    }

    func testEmojiIsBoundary() {
        XCTAssertEqual(ReplacementEngine.apply("дока🙂", rules: [rule("дока", "DOKA")]), "DOKA🙂")
    }

    /// Неудачная проверка границы не должна перепрыгивать следующее
    /// (перекрывающееся) валидное совпадение.
    func testFailedBoundaryDoesNotSkipLaterMatch() {
        XCTAssertEqual(ReplacementEngine.apply("дада да", rules: [rule("да", "нет")]), "дада нет")
    }

    func testMatchInsideWordsOptIn() {
        var inside = rule("ё", "е")
        inside.matchInsideWords = true
        XCTAssertEqual(ReplacementEngine.apply("ёлка", rules: [inside]), "елка")
        XCTAssertEqual(ReplacementEngine.apply("ёлка", rules: [rule("ё", "е")]), "ёлка")
    }

    // MARK: - Совместимость хранения

    /// Словарь, сохранённый прежней версией (без `matchInsideWords`), обязан
    /// читаться: иначе SettingsStore молча обнулит все правила пользователя.
    func testLegacyRuleJSONDecodes() throws {
        let json = #"[{"id":"6F1C2E2B-2E7D-4B8E-9E3C-1A2B3C4D5E6F","from":"дока","to":"DOKA","enabled":true}]"#
        let rules = try JSONDecoder().decode([ReplacementRule].self, from: Data(json.utf8))
        XCTAssertEqual(rules.count, 1)
        XCTAssertEqual(rules[0].from, "дока")
        XCTAssertTrue(rules[0].enabled)
        XCTAssertFalse(rules[0].matchInsideWords)
    }

    func testRoundTripKeepsMatchInsideWords() throws {
        var original = rule("ё", "е")
        original.matchInsideWords = true
        let data = try JSONEncoder().encode([original])
        let decoded = try JSONDecoder().decode([ReplacementRule].self, from: data)
        XCTAssertEqual(decoded, [original])
    }
}
