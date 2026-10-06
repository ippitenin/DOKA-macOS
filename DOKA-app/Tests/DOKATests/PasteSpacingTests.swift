import XCTest
@testable import DOKA

/// Пробел между диктовками подряд: ставится только когда картина однозначна.
final class PasteSpacingTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
    private let app: pid_t = 4242

    private func previous(_ text: String, ago: TimeInterval = 5, pid: pid_t? = 4242) -> PasteSpacing.Previous {
        PasteSpacing.Previous(text: text, date: now.addingTimeInterval(-ago), targetPID: pid)
    }

    private func prefix(after text: String, next: String, ago: TimeInterval = 5,
                        previousPID: pid_t? = 4242, targetPID: pid_t? = 4242) -> String {
        PasteSpacing.prefix(previous: previous(text, ago: ago, pid: previousPID), next: next,
                            targetPID: targetPID, now: now)
    }

    func testGluedWordsGetSpace() {
        XCTAssertEqual(prefix(after: "Не курить", next: "Потому что вредно."), " ")
        XCTAssertEqual(prefix(after: "Готово.", next: "Дальше"), " ")
        XCTAssertEqual(prefix(after: "сумма", next: "300 рублей"), " ")
        XCTAssertEqual(prefix(after: "Москва —", next: "столица"), " ", "тире отбивается пробелами")
        XCTAssertEqual(prefix(after: "он сказал \"да\"", next: "и ушёл"), " ", "прямая кавычка в конце — закрывающая")
    }

    func testNoSpaceAfterWhitespaceOrOpening() {
        for ending in ["слово ", "строка\n", "(", "[", "{", "«", "‹", "“", "‘", "кто-", "и/"] {
            XCTAssertEqual(prefix(after: ending, next: "Дальше"), "", "после «\(ending)»")
        }
    }

    func testOnlyWordLikeStartsGetSpace() {
        XCTAssertEqual(prefix(after: "текст", next: "(пояснение)"), " ")
        XCTAssertEqual(prefix(after: "текст", next: "«цитата»"), " ")
        for start in ["/remind", "@анна", "#тег", ", и ещё", ". Дальше", "!", "—", "-"] {
            XCTAssertEqual(prefix(after: "текст", next: start), "", "перед «\(start)»")
        }
    }

    func testTimeWindow() {
        XCTAssertEqual(prefix(after: "текст", next: "Дальше", ago: PasteSpacing.window), " ")
        XCTAssertEqual(prefix(after: "текст", next: "Дальше", ago: PasteSpacing.window + 1), "")
        XCTAssertEqual(prefix(after: "текст", next: "Дальше", ago: -1), "", "часы ушли назад — не угадываем")
    }

    func testOtherOrUnknownApplication() {
        XCTAssertEqual(prefix(after: "текст", next: "Дальше", targetPID: 7), "")
        XCTAssertEqual(prefix(after: "текст", next: "Дальше", targetPID: nil), "")
        XCTAssertEqual(prefix(after: "текст", next: "Дальше", previousPID: nil), "")
    }

    func testEmptyInputs() {
        XCTAssertEqual(PasteSpacing.prefix(previous: nil, next: "Дальше", targetPID: app, now: now), "")
        XCTAssertEqual(prefix(after: "", next: "Дальше"), "")
        XCTAssertEqual(prefix(after: "текст", next: ""), "")
    }
}
