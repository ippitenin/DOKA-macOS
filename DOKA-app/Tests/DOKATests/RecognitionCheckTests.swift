import XCTest
@testable import DOKA

/// Подстраховка сетевого распознавания. Тексты — настоящие ответы Nexara и
/// Parakeet по дублям владельца (стенд 17.10.2026).
final class RecognitionCheckTests: XCTestCase {

    private let russianHistory = [
        "Слушай, у нас появилась вот такая вот идея с Витей.",
        "Все, шаг 1-2 сделаны. Включай третий.",
        "Так, а что написать-то по рилсам, которые мы сейчас выложим?",
        "Смотри, мне, кстати, не нравится первая фраза в твоей воронке.",
        "Мёржи пулреквесты сам, сливай их в деф-ветку.",
        "Копию на рабочий стол закинь.",
    ]
    private var russian: RecognitionCheck.Usual { RecognitionCheck.usual(fromRecentTexts: russianHistory)! }

    // MARK: - Привычный язык

    func testUsualLanguageFromRecentDictations() {
        XCTAssertEqual(russian, .init(language: "ru", script: .cyrillic))
    }

    func testUsualLanguageSurvivesPhraseMistakenForKazakh() {
        // Эту русскую фразу NLLanguageRecognizer уверенно зовёт казахской, и в
        // склейке с шестью обычными весь текст становился «kk».
        let kazakhLooking = "Смотри, базово окей, несколько правок. Правка номер один. Ты на светлом фоне "
            + "используешь сразу два токена зеленого цвета для темного фона и для светлого."
        XCTAssertEqual(RecognitionCheck.usual(fromRecentTexts: [kazakhLooking] + russianHistory),
                       .init(language: "ru", script: .cyrillic))
    }

    func testUsualNeedsEnoughHistory() {
        XCTAssertNil(RecognitionCheck.usual(fromRecentTexts: Array(russianHistory.prefix(4))))
        XCTAssertNil(RecognitionCheck.usual(fromRecentTexts: []))
    }

    func testUsualLooksOnlyAtRecentSample() {
        // Старые английские записи за пределами выборки не влияют.
        let texts = Array(repeating: "Давай перенесём ревью на четверг.", count: 30)
            + Array(repeating: "Let's move the review to Thursday.", count: 50)
        XCTAssertEqual(RecognitionCheck.usual(fromRecentTexts: texts)?.script, .cyrillic)
    }

    // MARK: - Подозрение

    func testEnglishTranslationOfRussianIsSuspicious() {
        XCTAssertEqual(RecognitionCheck.suspicion(text: "Put a copy on the work table.", speechSeconds: 2.5,
                                                  autoLanguage: true, usual: russian),
                       .unusualScript(russian))
    }

    func testRussianWithEnglishWordsIsNotSuspicious() {
        XCTAssertNil(RecognitionCheck.suspicion(text: "Как мне нужно назвать страницу в Figma?", speechSeconds: 2.1,
                                                autoLanguage: true, usual: russian))
    }

    func testRussianWithMoreLatinLettersIsNotSuspicious() {
        // Латинских букв больше (11 против 7), но кириллица в ответе есть —
        // перевод убрал бы её целиком.
        XCTAssertNil(RecognitionCheck.suspicion(text: "Открой Figma и README", speechSeconds: 1.8,
                                                autoLanguage: true, usual: russian))
    }

    func testScriptCheckOnlyInAutoAndWithHistory() {
        let english = "How do I need to name the page?"
        XCTAssertNil(RecognitionCheck.suspicion(text: english, speechSeconds: 2.4, autoLanguage: false, usual: russian))
        XCTAssertNil(RecognitionCheck.suspicion(text: english, speechSeconds: 2.4, autoLanguage: true, usual: nil))
    }

    func testTextWithoutLettersIsNotSuspicious() {
        XCTAssertNil(RecognitionCheck.suspicion(text: "2, 3.", speechSeconds: 1.5, autoLanguage: true, usual: russian))
    }

    func testLostSpeechIsSuspicious() {
        // 15 с речи, а от ответа осталось начало первой фразы.
        XCTAssertEqual(RecognitionCheck.suspicion(text: "Слушай, тут у нас появился вот такой вот",
                                                  speechSeconds: 15.1, autoLanguage: true, usual: russian),
                       .tooFewWords)
    }

    func testWordCheckThresholds() {
        // Самая медленная обычная диктовка владельца — 0,92 слова на секунду речи.
        XCTAssertNil(RecognitionCheck.suspicion(text: "Все, шаг 1-2 сделаны. Включай третий.", speechSeconds: 7.6,
                                                autoLanguage: false, usual: nil))
        // Короткую запись по темпу не судим: пауза перед словом его роняет.
        XCTAssertNil(RecognitionCheck.suspicion(text: "Да.", speechSeconds: 4.9, autoLanguage: false, usual: nil))
        XCTAssertEqual(RecognitionCheck.suspicion(text: "Да.", speechSeconds: 5, autoLanguage: false, usual: nil),
                       .tooFewWords)
    }

    // MARK: - Решение после второго мнения

    func testParakeetHearsRussianRetriesWithUsualLanguage() {
        XCTAssertEqual(RecognitionCheck.verdict(.unusualScript(russian), text: "Put a copy on the work table.",
                                                secondOpinion: "Эээ, закинь копии на рабочий стол."),
                       .retry(language: "ru"))
    }

    func testRealEnglishSpeechIsKept() {
        XCTAssertEqual(RecognitionCheck.verdict(
            .unusualScript(russian),
            text: "Let's move the design review to Thursday at 3 and share the notes with the whole team.",
            secondOpinion: "Let's move the design review to Thursday at three and share the notes with the whole team."),
                       .keep)
    }

    func testWithoutParakeetRetriesInAuto() {
        // Явный язык на настоящей английской речи дал бы русский перевод.
        XCTAssertEqual(RecognitionCheck.verdict(.unusualScript(russian), text: "Put a copy on the work table.",
                                                secondOpinion: nil),
                       .retry(language: nil))
        XCTAssertEqual(RecognitionCheck.verdict(.tooFewWords, text: "Слушай, тут у нас появился вот такой вот",
                                                secondOpinion: nil),
                       .retry(language: nil))
    }

    func testParakeetHearsMuchMoreRetries() {
        XCTAssertEqual(RecognitionCheck.verdict(.tooFewWords, text: "Слушай, тут у нас появился вот такой вот",
                                                secondOpinion: Self.parakeetFull),
                       .retry(language: nil))
    }

    func testParakeetHearsTheSameKeeps() {
        // Короткая фраза на фоне шума: Parakeet слышит то же — повторять незачем.
        XCTAssertEqual(RecognitionCheck.verdict(.tooFewWords, text: "Ролик выложен, давай воронку пересоздадим.",
                                                secondOpinion: "Ролик выложен, давай воронку пересоздадим."),
                       .keep)
    }

    // MARK: - Итоговый текст

    func testRetryWithUsualScriptWins() {
        XCTAssertEqual(RecognitionCheck.resolve(.unusualScript(russian), first: "Put a copy on the work table.",
                                                retry: "Закинь копии на рабочий стол.", secondOpinion: nil),
                       "Закинь копии на рабочий стол.")
    }

    func testRetryInSameForeignScriptKeepsFirst() {
        XCTAssertEqual(RecognitionCheck.resolve(.unusualScript(russian), first: "Thank you very much.",
                                                retry: "Thank you so much.", secondOpinion: nil),
                       "Thank you very much.")
        XCTAssertEqual(RecognitionCheck.resolve(.unusualScript(russian), first: "Thank you very much.",
                                                retry: nil, secondOpinion: nil),
                       "Thank you very much.")
    }

    func testLongerRetryWins() {
        XCTAssertEqual(RecognitionCheck.resolve(.tooFewWords, first: "Слушай, тут у нас появился вот такой вот",
                                                retry: Self.nexaraFull, secondOpinion: Self.parakeetFull),
                       Self.nexaraFull)
    }

    func testShorterRetryLoses() {
        XCTAssertEqual(RecognitionCheck.resolve(.tooFewWords, first: "Давай воронку пересоздадим, чтобы сработало.",
                                                retry: "Давай воронку.", secondOpinion: nil),
                       "Давай воронку пересоздадим, чтобы сработало.")
    }

    func testParakeetTextWhenServiceCutsEveryTime() {
        let cut = "Ролик выложен, давай воронку тогда пересоздадим, чтобы твое правило сработало."
        let local = "Так я не понимаю, в чем проблема. Ты, с одной стороны, говоришь, что нужно сначала выложить "
            + "ролик, а потом включи воронку. Что ч<unk> делать-то? Ролик выложен, давай воронку тогда "
            + "пересоздадим, чтобы твое правило сработало."
        let result = RecognitionCheck.resolve(.tooFewWords, first: cut, retry: cut, secondOpinion: local)
        XCTAssertTrue(result.hasPrefix("Так я не понимаю"), result)
        XCTAssertFalse(result.contains("<unk>"), result)
        XCTAssertFalse(result.contains("  "), result)
    }

    // MARK: - Текст

    func testScriptByMajorityOfLetters() {
        XCTAssertEqual(RecognitionCheck.script(of: "Открой этот файл в Figma"), .cyrillic)
        XCTAssertEqual(RecognitionCheck.script(of: "Открой Figma и README"), .latin)
        XCTAssertEqual(RecognitionCheck.script(of: "Put a copy on the work table."), .latin)
        XCTAssertEqual(RecognitionCheck.script(of: "Ça marche, señor"), .latin)
        XCTAssertEqual(RecognitionCheck.script(of: "2, 3 — 4."), .other)
        XCTAssertEqual(RecognitionCheck.script(of: "東京へ行きます"), .other)
    }

    func testScriptsPresentInText() {
        XCTAssertEqual(RecognitionCheck.scripts(in: "Открой Figma и README"), [.cyrillic, .latin])
        XCTAssertEqual(RecognitionCheck.scripts(in: "Put a copy on the work table."), [.latin])
        XCTAssertEqual(RecognitionCheck.scripts(in: "2, 3 — 4."), [])
    }

    func testWordCount() {
        XCTAssertEqual(RecognitionCheck.wordCount("Все, шаг 1-2 сделаны. Включай третий."), 7)
        XCTAssertEqual(RecognitionCheck.wordCount("  "), 0)
    }

    private static let nexaraFull = "Слушай, тут у нас появился вот такой вот запрос, не у нас точнее, а вот у Вити. "
        + "Вот посмотри, что я сказал, правильно ли я сказал, и в целом, какие есть идеи."
    private static let parakeetFull = "Слушай, тут у нас появился вот такой вот запрос, не у нас точнее, а вот у Витя. "
        + "Вот посмотри, что я сказал, правильно ли я сказал, и в целом, какие есть идеи, что можно вообще "
        + "придумать, сделать и так далее."
}
