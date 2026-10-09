import XCTest
@testable import DOKA

/// «!» по интонации в конце диктовки.
///
/// Зачем: знак меняется молча, и ошибка здесь портит текст пользователя
/// посреди обычной работы. Главное — сторона ошибки: лишний «!» на спокойной
/// фразе хуже пропущенного. Поэтому закреплены правила, когда точку НЕ трогать
/// («...», сокращения, нерусская фраза, порог), и то, что звук без голоса не даёт
/// ответа вовсе. Совпадение вероятностей с моделью стенда проверяется вне
/// приложения: записи владельца в репозиторий не входят.
final class ExclamationDetectorTests: XCTestCase {

    // MARK: - Знак

    private let sure = ExclamationDetector.threshold + 0.05

    func testDotBecomesExclamationAboveThreshold() {
        XCTAssertEqual(ExclamationDetector.apply(to: "Вот это да.", probability: sure), "Вот это да!")
        XCTAssertEqual(ExclamationDetector.apply(to: "Вот это да.", probability: ExclamationDetector.threshold),
                       "Вот это да!")
    }

    func testBelowThresholdOrNoAnswerKeepsDot() {
        XCTAssertEqual(ExclamationDetector.apply(to: "Вот это да.", probability: ExclamationDetector.threshold - 0.01),
                       "Вот это да.")
        XCTAssertEqual(ExclamationDetector.apply(to: "Вот это да.", probability: nil), "Вот это да.")
    }

    /// Меняется только последний знак, пробелы в конце сохраняются.
    func testOnlyFinalDotChanges() {
        XCTAssertEqual(ExclamationDetector.apply(to: "Привет. Вот это да.", probability: sure),
                       "Привет. Вот это да!")
        XCTAssertEqual(ExclamationDetector.apply(to: "Вот это да. ", probability: sure), "Вот это да! ")
    }

    func testOtherEndingsAreUntouched() {
        for text in ["Ну...", "Ну…", "Как дела?", "Ура!", "Без знака", "", ".", "Да ."] {
            XCTAssertEqual(ExclamationDetector.apply(to: text, probability: 0.99), text, text)
        }
    }

    /// Точка после сокращения — не конец фразы.
    func testAbbreviationsAreUntouched() {
        for text in ["Фрукты, овощи и т.д.", "Встретимся в 2026 г.", "Пришли яблоки и др.", "Буква А."] {
            XCTAssertEqual(ExclamationDetector.apply(to: text, probability: 0.99), text, text)
        }
    }

    /// Модель обучена на русской интонации: нерусское последнее предложение не трогаем.
    func testOnlyRussianSentence() {
        XCTAssertEqual(ExclamationDetector.apply(to: "That is great.", probability: 0.99), "That is great.")
        XCTAssertEqual(ExclamationDetector.apply(to: "Привет. That is great.", probability: 0.99),
                       "Привет. That is great.")
        XCTAssertEqual(ExclamationDetector.apply(to: "Открой Telegram.", probability: 0.99), "Открой Telegram!")
    }

    // MARK: - Звук

    /// «Голос»: три гармоники с тоном `f0(t)`, между тишиной по 0,4 с.
    private func voice(seconds: Double, f0: (Double) -> Double) -> [Double] {
        let rate = Double(ExclamationDetector.sampleRate)
        let pad = [Double](repeating: 0, count: Int(0.4 * rate))
        var phase = 0.0
        var speech: [Double] = []
        for i in 0..<Int(seconds * rate) {
            phase += 2 * .pi * f0(Double(i) / rate) / rate
            speech.append(0.2 * sin(phase) + 0.1 * sin(2 * phase) + 0.05 * sin(3 * phase))
        }
        return pad + speech + pad
    }

    func testSilenceGivesNoAnswer() {
        XCTAssertNil(ExclamationDetector.probability(samples: [Double](repeating: 0, count: 32_000)))
    }

    /// Взлёт тона и резкий спад в конце (115 → 175 → 70 Гц) — восклицание;
    /// ровный тон — нет. Ровная фраза не должна дотягивать до порога.
    func testFallingEndScoresAboveFlatTone() throws {
        let flat = try XCTUnwrap(ExclamationDetector.probability(samples: voice(seconds: 1.2) { _ in 120 }))
        let falling = try XCTUnwrap(ExclamationDetector.probability(samples: voice(seconds: 1.2) { t in
            if t < 0.5 { return 115 }
            if t < 0.75 { return 115 + (t - 0.5) / 0.25 * 60 }
            return 175 - (t - 0.75) / 0.45 * 105
        }))
        XCTAssertLessThan(flat, ExclamationDetector.threshold)
        XCTAssertGreaterThan(falling, flat + 0.5)
    }
}
