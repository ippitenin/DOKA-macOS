import XCTest
@testable import DOKA

/// Whisper на почти тишине выдаёт дежурные фразы субтитров YouTube. Замер:
/// 1 с тишины → «Продолжение следует...» при language=ru, «You» в автоопределении;
/// в тихом режиме короткая пустая запись с шорохом прошла гейт и вставила «Thank you.».
/// Отсекаем только ЦЕЛИКОМ такой результат — часть настоящей фразы не трогаем.
final class HallucinationFilterTests: XCTestCase {

    func testSubtitleArtifactsAreDroppedInAnyMode() {
        for text in ["Продолжение следует...", "продолжение следует",
                     "Субтитры сделал DimaTorzok", "Субтитры создавал DimaTorzok",
                     "Редактор субтитров А.Синецкая Корректор А.Егорова",
                     "Спасибо за просмотр!", "Thanks for watching!", "Thank you for watching."] {
            XCTAssertTrue(HallucinationFilter.isHallucination(text, quiet: false), text)
            XCTAssertTrue(HallucinationFilter.isHallucination(text, quiet: true), text)
        }
    }

    /// «Спасибо» вслух днём — нормальная диктовка; в тихом режиме это почти
    /// всегда шорох, принятый Whisper за конец видео.
    func testShortCourtesiesAreDroppedOnlyInQuietMode() {
        for text in ["Thank you.", "thank you", "Спасибо.", "СПАСИБО!", "You", "Спасибо за внимание."] {
            XCTAssertTrue(HallucinationFilter.isHallucination(text, quiet: true), text)
            XCTAssertFalse(HallucinationFilter.isHallucination(text, quiet: false), text)
        }
    }

    /// Whisper повторяет дежурную фразу на длинной тишине: «Спасибо. Спасибо. Спасибо.»
    func testRepeatedArtifactIsDropped() {
        XCTAssertTrue(HallucinationFilter.isHallucination("Спасибо. Спасибо. Спасибо.", quiet: true))
        XCTAssertTrue(HallucinationFilter.isHallucination("Продолжение следует... Продолжение следует...",
                                                          quiet: false))
    }

    func testRealDictationIsKept() {
        for text in ["Спасибо большое, всё получилось с первого раза.",
                     "Thank you for the update, see you tomorrow.",
                     "Тихий режим работает, открывай пиар.",
                     "Продолжение следует завтра утром, не забудь.",
                     "You are right."] {
            XCTAssertFalse(HallucinationFilter.isHallucination(text, quiet: true), text)
            XCTAssertFalse(HallucinationFilter.isHallucination(text, quiet: false), text)
        }
    }

    func testEmptyTextIsNotAHallucination() {
        // Пустой ответ ловит движок (`emptyText`) — фильтр его не трогает.
        XCTAssertFalse(HallucinationFilter.isHallucination("", quiet: true))
        XCTAssertFalse(HallucinationFilter.isHallucination(" ... ", quiet: true))
    }

    /// whisper-1 у Nexara при language=ru выдал «you» целиком на записи с 0,4 с
    /// речи в обычном режиме. При явно выбранном неанглийском языке английская
    /// дежурная фраза целиком — тишина; при «Авто» и английском — диктовка.
    func testEnglishCourtesyIsDroppedWhenLanguageIsNotEnglish() {
        for text in ["you", "Thank you.", "Thanks!", "Bye."] {
            XCTAssertTrue(HallucinationFilter.isHallucination(text, quiet: false, language: "ru"), text)
            XCTAssertFalse(HallucinationFilter.isHallucination(text, quiet: false, language: "auto"), text)
            XCTAssertFalse(HallucinationFilter.isHallucination(text, quiet: false, language: "en"), text)
            XCTAssertFalse(HallucinationFilter.isHallucination(text, quiet: false), text)
        }
        // «Спасибо» днём — по-прежнему диктовка и при русском языке.
        XCTAssertFalse(HallucinationFilter.isHallucination("Спасибо.", quiet: false, language: "ru"))
    }

    // MARK: - Хвост в конце настоящей диктовки

    /// Концы реальных диктовок владельца 4–8.10.2026: дежурная фраза на тишине
    /// перед остановкой записи приклеилась к тексту.
    func testTrailingArtifactsFromRealDictationsAreTrimmed() {
        let cases: [(String, String)] = [
            ("Ну я на всякий, мало ли что вдруг. Thank you.",
             "Ну я на всякий, мало ли что вдруг."),
            ("через pull request заливай на git. Ну, можешь сразу сливать. Thank you.",
             "через pull request заливай на git. Ну, можешь сразу сливать."),
            ("Поэтому мне кажется, это в данном случае не нужно. Thank you.",
             "Поэтому мне кажется, это в данном случае не нужно."),
            ("Я с ним это обсужу и потом тебе все передам. Thank you.",
             "Я с ним это обсужу и потом тебе все передам."),
            ("Вот может нам примерно так же попробовать сделать? you",
             "Вот может нам примерно так же попробовать сделать?"),
            ("Вчера, кстати, провел встречу с Андреем Сейчас тебе все приложу Продолжение следует...",
             "Вчера, кстати, провел встречу с Андреем Сейчас тебе все приложу"),
        ]
        for (text, expected) in cases {
            XCTAssertEqual(HallucinationFilter.trimmingTrailingArtifacts(text), expected, text)
        }
    }

    func testRepeatedAndMixedTailsAreTrimmed() {
        XCTAssertEqual(HallucinationFilter.trimmingTrailingArtifacts("Всё готово. Thank you. Thank you."),
                       "Всё готово.")
        XCTAssertEqual(HallucinationFilter.trimmingTrailingArtifacts("Всё готово. Продолжение следует... Thank you."),
                       "Всё готово.")
        XCTAssertEqual(HallucinationFilter.trimmingTrailingArtifacts("Всё готово. Субтитры сделал DimaTorzok"),
                       "Всё готово.")
        // Висячая запятая перед хвостом уходит вместе с ним.
        XCTAssertEqual(HallucinationFilter.trimmingTrailingArtifacts("Ладно, созвонимся, thank you"),
                       "Ладно, созвонимся")
    }

    /// Хвост срезается, только если перед английской фразой русское слово.
    func testRealTextIsNotTrimmed() {
        for text in ["Его система распознает как thank you, в общем, хз.",
                     "I love you",
                     "Скажи ему: I love you",
                     "Thank you for the update, see you tomorrow.",
                     "Продолжение следует завтра утром, не забудь.",
                     "Спасибо большое, всё получилось с первого раза. Спасибо."] {
            XCTAssertEqual(HallucinationFilter.trimmingTrailingArtifacts(text), text, text)
        }
    }

    /// Текст из одной дежурной фразы — забота `isHallucination` (у повтора из
    /// меню фильтр целиком не работает, и пустую строку вставлять нельзя).
    func testWholeArtifactIsLeftAsIs() {
        for text in ["Thank you.", "you", "Продолжение следует...", "Thank you. Thank you.", ""] {
            XCTAssertEqual(HallucinationFilter.trimmingTrailingArtifacts(text), text, text)
        }
    }

    /// Осознанная цена: «thank you» в конце русской фразы срезается, даже если
    /// его сказали — отличить его от галлюцинации на тишине по тексту нельзя.
    func testRussianPhraseEndingWithSpokenThankYouIsTrimmed() {
        XCTAssertEqual(HallucinationFilter.trimmingTrailingArtifacts("Окей, thank you."), "Окей")
    }
}
