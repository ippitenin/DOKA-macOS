import XCTest
@testable import DOKA

final class RightModifierGestureTests: XCTestCase {
    private let delay = RightModifierGesture.holdStartDelay

    func testHoldStartsAfterDelayAndStopsOnRelease() {
        var g = RightModifierGesture()
        XCTAssertEqual(g.keyDown(.option, at: 0, kind: .hold), [.scheduleStart(.option, after: delay)])
        XCTAssertEqual(g.startDelayElapsed(.option, at: delay), [.start(.option)])
        XCTAssertEqual(g.keyUp(.option, at: 3), [.stop(.option)])
        XCTAssertFalse(g.isDown(.option))
    }

    func testQuickReleaseBeforeDelayDoesNothing() {
        var g = RightModifierGesture()
        _ = g.keyDown(.option, at: 0, kind: .hold)
        XCTAssertEqual(g.keyUp(.option, at: 0.1), [])
        XCTAssertEqual(g.startDelayElapsed(.option, at: delay), [], "таймер после отпускания не стартует запись")
    }

    func testComboBeforeStartNeverStarts() {
        var g = RightModifierGesture()
        _ = g.keyDown(.option, at: 0, kind: .hold)
        XCTAssertEqual(g.otherKey(at: 0.05), [])   // ⌥+буква («—»)
        XCTAssertEqual(g.startDelayElapsed(.option, at: delay), [])
        XCTAssertEqual(g.keyUp(.option, at: 0.4), [])
    }

    func testComboSoonAfterStartCancels() {
        var g = RightModifierGesture()
        _ = g.keyDown(.command, at: 0, kind: .hold)
        _ = g.startDelayElapsed(.command, at: delay)
        XCTAssertEqual(g.otherKey(at: delay + 0.5), [.cancel(.command)])
        XCTAssertEqual(g.keyUp(.command, at: 2), [], "отменённая запись не останавливается второй раз")
    }

    func testLateOtherKeyKeepsRecording() {
        var g = RightModifierGesture()
        _ = g.keyDown(.option, at: 0, kind: .hold)
        _ = g.startDelayElapsed(.option, at: delay)
        XCTAssertEqual(g.otherKey(at: delay + RightModifierGesture.comboCancelWindow + 0.1), [])
        XCTAssertEqual(g.keyUp(.option, at: 5), [.stop(.option)])
    }

    func testOtherModifiersDoNotBreakHold() {
        var g = RightModifierGesture()
        _ = g.keyDown(.option, at: 0, kind: .hold)
        g.otherModifierChanged()   // ⌃⇧ команды фиксации
        XCTAssertEqual(g.startDelayElapsed(.option, at: delay), [.start(.option)])
    }

    func testShortTapFires() {
        var g = RightModifierGesture()
        XCTAssertEqual(g.keyDown(.option, at: 0, kind: .tap), [])
        XCTAssertEqual(g.keyUp(.option, at: 0.2), [.fire(.option)])
    }

    func testLongTapDoesNotFire() {
        var g = RightModifierGesture()
        _ = g.keyDown(.option, at: 0, kind: .tap)
        XCTAssertEqual(g.keyUp(.option, at: RightModifierGesture.tapMaxDuration + 0.1), [])
    }

    func testTapWithComboDoesNotFire() {
        var g = RightModifierGesture()
        _ = g.keyDown(.command, at: 0, kind: .tap)
        XCTAssertEqual(g.otherKey(at: 0.1), [])   // ⌘+C
        XCTAssertEqual(g.keyUp(.command, at: 0.2), [])
        _ = g.keyDown(.command, at: 1, kind: .tap)
        g.otherModifierChanged()                  // ⌘⇧…
        XCTAssertEqual(g.keyUp(.command, at: 1.2), [])
    }

    func testTwoAssignedKeysDoNotCancelEachOther() {
        // Правый ⌥ — PTT, правый ⌘ — фиксация: нажатие ⌘ не сочетание для ⌥.
        var g = RightModifierGesture()
        _ = g.keyDown(.option, at: 0, kind: .hold)
        _ = g.startDelayElapsed(.option, at: delay)
        XCTAssertEqual(g.keyDown(.command, at: 0.5, kind: .tap), [])
        XCTAssertEqual(g.keyUp(.command, at: 0.6), [.fire(.command)])
        XCTAssertEqual(g.keyUp(.option, at: 2), [.stop(.option)])
    }

    func testRepeatedDownIsIgnored() {
        var g = RightModifierGesture()
        _ = g.keyDown(.option, at: 0, kind: .hold)
        XCTAssertEqual(g.keyDown(.option, at: 0.1, kind: .hold), [])
    }
}
