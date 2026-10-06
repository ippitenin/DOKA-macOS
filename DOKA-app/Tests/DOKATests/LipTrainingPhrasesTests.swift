import XCTest
@testable import DOKA

/// Фразы окна «Тренировка»: что годится для проговаривания губами.
///
/// Зачем: фраза с цифрами или латиницей даёт пару с неоднозначной подписью
/// («5» или «пять» — губы одни), слишком длинная не уложится в дубль, а
/// повтор одной фразы под разной пунктуацией тратит время сеанса впустую.
/// Готовый список проверяется целиком — та же планка, что у истории.
final class LipTrainingPhrasesTests: XCTestCase {

    func testSuitablePhrase() {
        XCTAssertTrue(LipTrainingPhrases.isSuitable("Купи хлеба по дороге."))
        XCTAssertTrue(LipTrainingPhrases.isSuitable("Слушай, а давай сделаем это по-другому?"))
        XCTAssertTrue(LipTrainingPhrases.isSuitable("Ещё раз — «аккуратнее»!"))
    }

    func testUnsuitablePhrases() {
        XCTAssertFalse(LipTrainingPhrases.isSuitable("Привет, мир."), "два слова")
        XCTAssertFalse(LipTrainingPhrases.isSuitable("Встреча в 10 утра сегодня."), "цифры")
        XCTAssertFalse(LipTrainingPhrases.isSuitable("Обнови Xcode до последней версии."), "латиница")
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
    }

    /// История: годные предложения, повторы (в том числе с другой «ё» и
    /// регистром) — один раз, в порядке первого появления.
    func testHistorySentences() {
        let texts = [
            "Слушай, посмотри главную страницу. Ну да. В 5 утра встаю рано. Сделай фон темнее, пожалуйста!",
            "СЛУШАЙ, посмотри главную страницу! Обнови Figma до свежей версии.\nЕщё раз проверь сборку приложения",
            "Еще раз проверь сборку приложения.",
        ]
        XCTAssertEqual(LipTrainingPhrases.fromHistory(texts), [
            "Слушай, посмотри главную страницу.",
            "Сделай фон темнее, пожалуйста!",
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
        [unknown]
        Неизвестный раздел пропускается.
        """
        XCTAssertEqual(LipTrainingPhrases.parseBuiltin(contents), [
            LipTrainingPhrase(text: "Обнови документацию после изменений.", origin: .work),
            LipTrainingPhrase(text: "Купи хлеба по дороге.", origin: .everyday),
        ])
    }

    /// Готовый список из бандла: широкий охват (по паре сотен рабочих и
    /// бытовых фраз), каждая годится, повторов нет.
    func testBuiltinListIsValid() {
        let phrases = LipTrainingPhrases.builtin()
        let work = phrases.filter { $0.origin == .work }
        let everyday = phrases.filter { $0.origin == .everyday }
        XCTAssertGreaterThanOrEqual(work.count, 200)
        XCTAssertGreaterThanOrEqual(everyday.count, 200)
        XCTAssertEqual(work.count + everyday.count, phrases.count, "в списке только два раздела")
        for phrase in phrases {
            XCTAssertTrue(LipTrainingPhrases.isSuitable(phrase.text), phrase.text)
        }
        let keys = phrases.map { LipTrainingPhrases.normalize($0.text) }
        XCTAssertEqual(Set(keys).count, keys.count, "повторы в списке")
    }
}
