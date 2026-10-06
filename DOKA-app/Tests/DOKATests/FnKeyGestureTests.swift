import XCTest
@testable import DOKA

/// Клавиша Fn как хоткей: удержание, старт-стоп и сочетания Fn+клавиша,
/// которые диктовку запускать не должны.
final class FnKeyGestureTests: XCTestCase {
    private let delay = FnKeyGesture.holdStartDelay

    // MARK: - Удержание

    func testHoldStartsAfterDelayAndStopsOnRelease() {
        var g = FnKeyGesture()
        XCTAssertEqual(g.fnDown(at: 10, mode: .hold), .scheduleStart(after: delay))
        XCTAssertEqual(g.startDelayElapsed(at: 10 + delay), .start)
        XCTAssertEqual(g.fnUp(at: 14), .stop)
        XCTAssertFalse(g.isDown)
    }

    func testHoldShortTapDoesNothing() {
        var g = FnKeyGesture()
        _ = g.fnDown(at: 10, mode: .hold)
        XCTAssertEqual(g.fnUp(at: 10.1), .none)
        XCTAssertEqual(g.startDelayElapsed(at: 10 + delay), .none, "таймер после отпускания не стартует запись")
    }

    func testHoldComboBeforeStartNeverRecords() {
        var g = FnKeyGesture()
        _ = g.fnDown(at: 10, mode: .hold)
        XCTAssertEqual(g.otherKey(at: 10.05), .none)   // Fn+→ (End)
        XCTAssertEqual(g.startDelayElapsed(at: 10 + delay), .none)
        XCTAssertEqual(g.fnUp(at: 10.4), .none)
    }

    func testHoldComboRightAfterStartCancels() {
        var g = FnKeyGesture()
        _ = g.fnDown(at: 10, mode: .hold)
        _ = g.startDelayElapsed(at: 10.2)
        XCTAssertEqual(g.otherKey(at: 10.6), .cancel)
        XCTAssertEqual(g.fnUp(at: 11), .none, "отменённую запись отпускание не отправляет")
    }

    func testHoldStrayKeyLaterKeepsRecording() {
        var g = FnKeyGesture()
        _ = g.fnDown(at: 10, mode: .hold)
        _ = g.startDelayElapsed(at: 10.2)
        XCTAssertEqual(g.otherKey(at: 10.2 + FnKeyGesture.comboCancelWindow + 0.1), .none)
        XCTAssertEqual(g.fnUp(at: 15), .stop)
    }

    func testRepeatedFnDownIgnored() {
        var g = FnKeyGesture()
        _ = g.fnDown(at: 10, mode: .hold)
        XCTAssertEqual(g.fnDown(at: 10.1, mode: .hold), .none)
    }

    // MARK: - Старт-стоп

    func testToggleOnShortTap() {
        var g = FnKeyGesture()
        XCTAssertEqual(g.fnDown(at: 10, mode: .toggle), .none)
        XCTAssertEqual(g.fnUp(at: 10.2), .toggle)
        XCTAssertEqual(g.fnDown(at: 13, mode: .toggle), .none)
        XCTAssertEqual(g.fnUp(at: 13.1), .toggle)
    }

    func testToggleIgnoresLongPressAndCombos() {
        var g = FnKeyGesture()
        _ = g.fnDown(at: 10, mode: .toggle)
        XCTAssertEqual(g.fnUp(at: 10 + FnKeyGesture.tapMaxDuration + 0.1), .none)
        _ = g.fnDown(at: 20, mode: .toggle)
        XCTAssertEqual(g.otherKey(at: 20.1), .none)
        XCTAssertEqual(g.fnUp(at: 20.2), .none)
        XCTAssertEqual(g.startDelayElapsed(at: 30), .none, "в старт-стопе таймера нет")
    }

    // MARK: - Выключено и смена режима

    func testOffDoesNothing() {
        var g = FnKeyGesture()
        XCTAssertEqual(g.fnDown(at: 10, mode: .off), .none)
        XCTAssertEqual(g.startDelayElapsed(at: 10.3), .none)
        XCTAssertEqual(g.fnUp(at: 10.4), .none)
    }

    func testModeIsTakenAtPress() {
        var g = FnKeyGesture()
        _ = g.fnDown(at: 10, mode: .hold)
        _ = g.startDelayElapsed(at: 10.2)
        // Настройку выключили посреди удержания: начатая запись всё равно
        // получает стоп (HotkeyManager пропускает события, пока isDown).
        XCTAssertEqual(g.fnUp(at: 12), .stop)
    }

    func testOtherKeyWithoutFnIgnored() {
        var g = FnKeyGesture()
        XCTAssertEqual(g.otherKey(at: 5), .none)
        XCTAssertEqual(g.fnUp(at: 6), .none)
    }
}
