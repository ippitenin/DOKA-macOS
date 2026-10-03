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
}
