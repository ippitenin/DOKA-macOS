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

    // MARK: - Формы слова

    /// Одно правило вместо пяти: падежи бренда сводятся к латинскому названию.
    func testWordFormsCollapseToLatinReplacement() {
        let rules = [rule("телеграм", "Telegram")]
        XCTAssertEqual(ReplacementEngine.apply("в телеграме, телеграма нет, с телеграмом и телеграм.", rules: rules),
                       "в Telegram, Telegram нет, с Telegram и Telegram.")
        XCTAssertEqual(ReplacementEngine.apply("Телеграм-канал и ТЕЛЕГРАМЕ", rules: rules),
                       "Telegram-канал и Telegram")
    }

    /// Основа без конечной гласной, «ь» или «й»: «фигма» → «фигм», «эксель» → «эксел».
    func testStemDropsFinalVowelSoftSignOrShortI() {
        XCTAssertEqual(ReplacementEngine.apply("в фигме и с фигмой", rules: [rule("фигма", "Figma")]),
                       "в Figma и с Figma")
        XCTAssertEqual(ReplacementEngine.apply("в экселе, экселем", rules: [rule("эксель", "Excel")]),
                       "в Excel, Excel")
        XCTAssertEqual(ReplacementEngine.apply("после деплоя", rules: [rule("деплой", "deploy")]), "после deploy")
    }

    /// После основы — только падежное окончание и граница слова: другие слова
    /// с тем же началом и слова с приставкой не трогаются.
    func testFormsKeepWordBoundaries() {
        let rules = [rule("телеграм", "Telegram"), rule("гугл", "Google")]
        XCTAssertEqual(ReplacementEngine.apply("пришла телеграмма, телеграмный адрес", rules: rules),
                       "пришла телеграмма, телеграмный адрес")
        XCTAssertEqual(ReplacementEngine.apply("погугли и гуглить, гугли сам, я гуглю", rules: rules),
                       "погугли и гуглить, гугли сам, я гуглю", "глагол «гуглить» — не Google")
    }

    /// Короткие шаблоны (основа < 4 букв) ловят только точное слово: «МД»
    /// не должно съесть «мда», «апи» — «апу».
    func testShortStemMatchesExactWordOnly() {
        let rules = [rule("МД", "MD"), rule("апи", "API"), rule("дока", "DOKA")]
        XCTAssertEqual(ReplacementEngine.apply("Мда, файл МД, апи и апу, доки", rules: rules),
                       "Мда, файл MD, API и апу, доки")
    }

    /// В кириллическую замену окончание не переносится — правило ловит
    /// только точное слово, как раньше.
    func testCyrillicReplacementMatchesExactWordOnly() {
        let rules = [rule("клиент", "заказчик")]
        XCTAssertEqual(ReplacementEngine.apply("клиент и клиенту", rules: rules), "заказчик и клиенту")
    }

    func testWordFormsCanBeTurnedOff() {
        var exact = rule("телеграм", "Telegram")
        exact.matchWordForms = false
        XCTAssertEqual(ReplacementEngine.apply("телеграм и телеграме", rules: [exact]), "Telegram и телеграме")
    }

    /// Формы — у последнего слова многословного шаблона.
    func testFormsOfMultiwordPatternUseLastWord() {
        XCTAssertEqual(ReplacementEngine.apply("в гугл клауде", rules: [rule("гугл клауд", "Google Cloud")]),
                       "в Google Cloud")
    }

    /// Подъём заглавной и повторный проход работают и с формой.
    func testFormsWithCapitalizationAreIdempotent() {
        let rules = [rule("ютуб", "youtube")]
        let once = ReplacementEngine.apply("Ютубе смотрел. А на ютубе нет.", rules: rules)
        XCTAssertEqual(once, "Youtube смотрел. А на youtube нет.")
        XCTAssertEqual(ReplacementEngine.apply(once, rules: rules), once)
    }

    func testFormsStemRules() {
        XCTAssertEqual(ReplacementEngine.formsStem(of: rule("телеграм", "Telegram")), "телеграм")
        XCTAssertEqual(ReplacementEngine.formsStem(of: rule("фигма", "Figma")), "фигм")
        XCTAssertNil(ReplacementEngine.formsStem(of: rule("апи", "API")), "основа короче 4")
        XCTAssertNil(ReplacementEngine.formsStem(of: rule("Stories", "сторис")), "латинский шаблон")
        XCTAssertNil(ReplacementEngine.formsStem(of: rule("телеграм ", "Telegram")), "кончается пробелом")
        XCTAssertNil(ReplacementEngine.formsStem(of: rule("клиент", "заказчик")), "кириллическая замена")
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
        XCTAssertTrue(rules[0].matchWordForms, "формы слова — по умолчанию и у старых правил")
    }

    func testRoundTripKeepsMatchInsideWords() throws {
        var original = rule("ё", "е")
        original.matchInsideWords = true
        let data = try JSONEncoder().encode([original])
        let decoded = try JSONDecoder().decode([ReplacementRule].self, from: data)
        XCTAssertEqual(decoded, [original])
    }
}
