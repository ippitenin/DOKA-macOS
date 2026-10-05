import XCTest
@testable import DOKA

/// Сборка слов из токенов Parakeet. FluidAudio отдаёт токены уже
/// декодированными — начало слова помечено пробелом, а не «▁»; прежняя
/// проверка только «▁» склеивала весь файл в одно слово.
@MainActor
final class ParakeetWordsTests: XCTestCase {

    private func words(_ tokens: [(String, Double, Double)]) -> [TranscriptWord] {
        ParakeetLocalEngine.words(from: tokens.map { (token: $0.0, start: $0.1, end: $0.2) })
    }

    /// Живые токены FluidAudio (0.15.5 и 0.17.5): пробел в начале — новое слово.
    func testSpacePrefixedTokensStartWords() {
        let result = words([(" При", 0.0, 0.2), ("вет", 0.2, 0.4), (",", 0.4, 0.45),
                            (" это", 0.6, 0.8), (" про", 0.9, 1.0), ("вер", 1.0, 1.1), ("ка", 1.1, 1.3),
                            (".", 1.3, 1.35)])
        XCTAssertEqual(result.map(\.text), ["Привет,", "это", "проверка."])
        XCTAssertEqual(result[0].start, 0.0)
        XCTAssertEqual(result[0].end, 0.45)
        XCTAssertEqual(result[2].start, 0.9)
        XCTAssertEqual(result[2].end, 1.35)
    }

    /// Метка sentencepiece «▁» по-прежнему работает.
    func testSentencePieceMarkerStartsWords() {
        let result = words([("▁Hello", 0, 0.3), (",", 0.3, 0.35), ("▁wor", 0.4, 0.6), ("ld", 0.6, 0.8)])
        XCTAssertEqual(result.map(\.text), ["Hello,", "world"])
    }

    /// Первый токен без метки (пунктуация или кусок слова в начале) не теряется.
    func testLeadingTokenWithoutMarker() {
        let result = words([("—", 0, 0.1), (" Да", 0.2, 0.4)])
        XCTAssertEqual(result.map(\.text), ["—", "Да"])
        XCTAssertTrue(words([]).isEmpty)
    }
}
