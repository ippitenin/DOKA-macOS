import XCTest
@testable import DOKA

/// Фразы окна «Тренировка»: что годится для проговаривания губами.
///
/// Зачем: фраза с цифрами даёт пару с неоднозначной подписью («5» или
/// «пять» — губы одни), слишком длинная не уложится в дубль, а повтор одной
/// фразы под разной пунктуацией тратит время сеанса впустую. Английские слова
/// в русской фразе — можно (люди так говорят), а целиком английская фраза
/// или «README.md» — нет. Готовый список проверяется целиком — та же планка,
/// что у истории.
final class LipTrainingPhrasesTests: XCTestCase {

    func testSuitablePhrase() {
        XCTAssertTrue(LipTrainingPhrases.isSuitable("Купи хлеба по дороге."))
        XCTAssertTrue(LipTrainingPhrases.isSuitable("Слушай, а давай сделаем это по-другому?"))
        XCTAssertTrue(LipTrainingPhrases.isSuitable("Ещё раз — «аккуратнее»!"))
        XCTAssertTrue(LipTrainingPhrases.isSuitable("Обнови Xcode до последней версии."))
        XCTAssertTrue(LipTrainingPhrases.isSuitable("Telegram опять не открывается без VPN."))
        XCTAssertTrue(LipTrainingPhrases.isSuitable("Блин, нигде нет HTML-ки?"), "слово с обеими азбуками")
    }

    func testUnsuitablePhrases() {
        XCTAssertFalse(LipTrainingPhrases.isSuitable("Привет, мир."), "два слова")
        XCTAssertFalse(LipTrainingPhrases.isSuitable("Встреча в 10 утра сегодня."), "цифры")
        XCTAssertFalse(LipTrainingPhrases.isSuitable("Open the GitHub page now."), "целиком английская")
        XCTAssertFalse(LipTrainingPhrases.isSuitable("Обнови Xcode и Figma."), "латинских слов не меньше русских")
        XCTAssertFalse(LipTrainingPhrases.isSuitable("Открой README.md в редакторе."), "точка перед буквой")
        XCTAssertFalse(LipTrainingPhrases.isSuitable("Обнови Claude .md и документацию."), "точка перед буквой")
        XCTAssertFalse(LipTrainingPhrases.isSuitable("Обнови iOS 18 на телефоне."), "цифры рядом с латиницей")
        let long = Array(repeating: "слово", count: 13).joined(separator: " ")
        XCTAssertFalse(LipTrainingPhrases.isSuitable(long), "тринадцать слов")
        let wide = Array(repeating: "длиннейшееслово", count: 7).joined(separator: " ")
        XCTAssertGreaterThan(wide.count, LipTrainingPhrases.maxCharacters)
        XCTAssertFalse(LipTrainingPhrases.isSuitable(wide), "длиннее 90 символов")
        XCTAssertFalse(LipTrainingPhrases.isSuitable(""))
        XCTAssertFalse(LipTrainingPhrases.isSuitable("Смотри — ну —"), "тире не слова")
    }

    func testNormalizeIgnoresCaseYoAndPunctuation() {
        XCTAssertEqual(LipTrainingPhrases.normalize("Ещё раз,  ПРОВЕРЬ!"), "еще раз проверь")
        XCTAssertEqual(LipTrainingPhrases.normalize("Как-нибудь потом…"), "как нибудь потом")
    }

    func testSentenceSplitting() {
        XCTAssertEqual(LipTrainingPhrases.sentences("Так. Что?! Ну да… Ладно\nновая строка"),
                       ["Так.", "Что?!", "Ну да…", "Ладно", "новая строка"])
        XCTAssertEqual(LipTrainingPhrases.sentences("  Без точки в конце  "), ["Без точки в конце"])
        // Точка перед буквой — часть слова: обрывков «Claude .» и «md, Readme…» нет.
        let file = "Обнови документацию, Claude .md, Readme и так далее. Готово."
        XCTAssertEqual(LipTrainingPhrases.sentences(file),
                       ["Обнови документацию, Claude .md, Readme и так далее.", "Готово."])
        XCTAssertEqual(LipTrainingPhrases.fromHistory([file]), [])
    }

    /// История: годные предложения, повторы (в том числе с другой «ё» и
    /// регистром) — один раз, в порядке первого появления.
    func testHistorySentences() {
        let texts = [
            "Слушай, посмотри главную страницу. Ну да. В 5 утра встаю рано. Thank you for watching. Сделай фон темнее, пожалуйста!",
            "СЛУШАЙ, посмотри главную страницу! Обнови Figma до свежей версии.\nЕщё раз проверь сборку приложения",
            "Еще раз проверь сборку приложения.",
        ]
        XCTAssertEqual(LipTrainingPhrases.fromHistory(texts), [
            "Слушай, посмотри главную страницу.",
            "Сделай фон темнее, пожалуйста!",
            "Обнови Figma до свежей версии.",
            "Ещё раз проверь сборку приложения",
        ])
    }

    func testParseBuiltin() {
        let contents = """
        # комментарий
        Строка до раздела не считается.
        [work]
        Обнови документацию после изменений.

        # ещё комментарий
        [everyday]
        Купи хлеба по дороге.
        [mixed]
        Открой GitHub и посмотри коммит.
        [unknown]
        Неизвестный раздел пропускается.
        """
        XCTAssertEqual(LipTrainingPhrases.parseBuiltin(contents), [
            LipTrainingPhrase(text: "Обнови документацию после изменений.", origin: .work),
            LipTrainingPhrase(text: "Купи хлеба по дороге.", origin: .everyday),
            LipTrainingPhrase(text: "Открой GitHub и посмотри коммит.", origin: .mixed),
        ])
    }

    /// Готовый список из бандла: широкий охват (по паре сотен рабочих и
    /// бытовых фраз и около сотни с английскими словами), каждая годится,
    /// повторов нет, латиница — только в разделе `[mixed]`.
    func testBuiltinListIsValid() {
        let phrases = LipTrainingPhrases.builtin()
        let work = phrases.filter { $0.origin == .work }
        let everyday = phrases.filter { $0.origin == .everyday }
        let mixed = phrases.filter { $0.origin == .mixed }
        XCTAssertGreaterThanOrEqual(work.count, 200)
        XCTAssertGreaterThanOrEqual(everyday.count, 200)
        XCTAssertGreaterThanOrEqual(mixed.count, 80)
        XCTAssertEqual(work.count + everyday.count + mixed.count, phrases.count, "в списке только три раздела")
        func hasLatin(_ phrase: LipTrainingPhrase) -> Bool {
            phrase.text.unicodeScalars.contains { ("A"..."Z").contains($0) || ("a"..."z").contains($0) }
        }
        XCTAssertEqual((work + everyday).filter(hasLatin).map(\.text), [], "латиница вне [mixed]")
        XCTAssertGreaterThanOrEqual(mixed.filter(hasLatin).count, 40, "в [mixed] есть и латиница, не только заимствования")
        for phrase in phrases {
            XCTAssertTrue(LipTrainingPhrases.isSuitable(phrase.text), phrase.text)
        }
        let keys = phrases.map { LipTrainingPhrases.normalize($0.text) }
        XCTAssertEqual(Set(keys).count, keys.count, "повторы в списке")
    }
}
