import XCTest
@testable import DOKA

/// Активный сегмент под позицией плеера.
final class SegmentTimelineTests: XCTestCase {
    private let starts: [Double] = [0.5, 4, 9.25, 15]

    func testEmpty() {
        XCTAssertNil(SegmentTimeline.activeIndex(starts: [], time: 3))
    }

    func testBeforeFirstSegment() {
        XCTAssertNil(SegmentTimeline.activeIndex(starts: starts, time: 0))
        XCTAssertNil(SegmentTimeline.activeIndex(starts: starts, time: 0.49))
    }

    func testExactlyOnStart() {
        XCTAssertEqual(SegmentTimeline.activeIndex(starts: starts, time: 0.5), 0)
        XCTAssertEqual(SegmentTimeline.activeIndex(starts: starts, time: 4), 1)
        XCTAssertEqual(SegmentTimeline.activeIndex(starts: starts, time: 15), 3)
    }

    func testBetweenStarts() {
        XCTAssertEqual(SegmentTimeline.activeIndex(starts: starts, time: 3.99), 0)
        XCTAssertEqual(SegmentTimeline.activeIndex(starts: starts, time: 10), 2)
    }

    func testAfterLastSegment() {
        XCTAssertEqual(SegmentTimeline.activeIndex(starts: starts, time: 3_600), 3)
    }

    func testSingleSegment() {
        XCTAssertEqual(SegmentTimeline.activeIndex(starts: [0], time: 42), 0)
    }

    /// Совпадающие начала (сегменты одного момента): берётся последний.
    func testDuplicateStarts() {
        XCTAssertEqual(SegmentTimeline.activeIndex(starts: [0, 2, 2, 5], time: 2), 2)
    }

    func testNonFiniteTime() {
        XCTAssertNil(SegmentTimeline.activeIndex(starts: starts, time: .nan))
        XCTAssertNil(SegmentTimeline.activeIndex(starts: starts, time: .infinity))
    }
}
