import XCTest
@testable import DOKA

/// Перцентиль по ближайшему рангу — общий у сводок лога губ и кропа дубля.
/// Зачем: три прежние копии считали индекс одной формулой, и кроп дубля
/// (5-й и 95-й процентили пути головы) должен остаться ровно прежним.
final class PercentileTests: XCTestCase {
    func testNearestRankPicksRoundedIndex() {
        let sorted: [Double] = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]
        XCTAssertEqual(Percentile.nearestRank(sorted, 0), 1)
        XCTAssertEqual(Percentile.nearestRank(sorted, 0.5), 6)
        XCTAssertEqual(Percentile.nearestRank(sorted, 0.95), 11)   // 9,5 → 10
        XCTAssertEqual(Percentile.nearestRank(sorted, 0.05), 2)    // 0,5 → 1
        XCTAssertEqual(Percentile.nearestRank(sorted, 1), 11)
    }

    func testEmptyAndSingle() {
        XCTAssertNil(Percentile.nearestRank([Double](), 0.5))
        XCTAssertEqual(Percentile.nearestRank([CGFloat(7)], 0.95), 7)
    }

    func testMillisecondsSummarySortsOnce() {
        let summary = Percentile.millisecondsSummary(seconds: [0.030, 0.010, 0.020])
        XCTAssertEqual(summary?.count, 3)
        XCTAssertEqual(summary?.p50 ?? 0, 20, accuracy: 1e-9)
        XCTAssertEqual(summary?.p95 ?? 0, 30, accuracy: 1e-9)
        XCTAssertNil(Percentile.millisecondsSummary(seconds: []))
    }
}
