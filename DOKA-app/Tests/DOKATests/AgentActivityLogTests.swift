import XCTest
@testable import DOKA

/// Журнал обращений агента: хранит последние 50, считает все с запуска,
/// свёрнутая карточка прячет всё сверх 20, подпись честно говорит о вытеснении.
/// Подпись идёт через `L()` и зависит от языка бандла — проверяются числа,
/// а не перевод.
@MainActor
final class AgentActivityLogTests: XCTestCase {
    func testKeepsLastFiftyAndCountsAll() {
        let log = AgentActivityLog()
        for index in 0..<137 {
            log.add(tool: "tool\(index)", outcome: .done)
        }
        XCTAssertEqual(log.entries.count, AgentActivityLog.limit)
        XCTAssertEqual(log.totalCount, 137)
        // Новые сверху: первая строка — последнее обращение.
        XCTAssertEqual(log.entries.first?.tool, "tool136")
        XCTAssertEqual(log.entries.last?.tool, "tool87")

        log.clear()
        XCTAssertTrue(log.entries.isEmpty)
        XCTAssertEqual(log.totalCount, 0)
    }

    func testHiddenCount() {
        XCTAssertEqual(AgentActivityLog.hiddenCount(stored: 0), 0)
        XCTAssertEqual(AgentActivityLog.hiddenCount(stored: 20), 0)
        XCTAssertEqual(AgentActivityLog.hiddenCount(stored: 21), 1)
        XCTAssertEqual(AgentActivityLog.hiddenCount(stored: 50), 30)
    }

    /// Пока ничего не вытеснено — подпись про лимит; после — «50 из N».
    func testFooterMentionsOverflowOnlyWhenDropped() {
        let kept = AgentActivityLog.footer(stored: 50, total: 50)
        XCTAssertTrue(kept.contains("50"), kept)
        XCTAssertFalse(kept.contains("137"), kept)

        let overflow = AgentActivityLog.footer(stored: 50, total: 137)
        XCTAssertTrue(overflow.contains("50"), overflow)
        XCTAssertTrue(overflow.contains("137"), overflow)
        XCTAssertNotEqual(kept, overflow)

        // Мало обращений — подпись та же, что при полном журнале без вытеснения.
        XCTAssertEqual(AgentActivityLog.footer(stored: 3, total: 3), kept)
    }
}
