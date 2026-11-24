import XCTest
@testable import DOKA

final class DictationControlsTests: XCTestCase {
    func testHoldReleaseFinishes() {
        var controls = DictationControls()
        XCTAssertEqual(controls.pushToTalkDown(), .startHeld)
        controls.didStart(held: true)
        XCTAssertEqual(controls.pushToTalkDown(), .none)
        XCTAssertEqual(controls.pushToTalkUp(), .finish)
        controls.didEnd()
        XCTAssertNil(controls.mode)
    }

    func testLockIgnoresReleaseThenPTTFinishes() {
        var controls = DictationControls()
        XCTAssertEqual(controls.pushToTalkDown(), .startHeld)
        controls.didStart(held: true)
        XCTAssertEqual(controls.lockOrPause(), .lock)
        XCTAssertEqual(controls.mode, .handsFree)
        XCTAssertEqual(controls.pushToTalkUp(), .none)
        XCTAssertEqual(controls.pushToTalkDown(), .finish)
        controls.didEnd()
        XCTAssertEqual(controls.pushToTalkUp(), .none)
    }

    func testSameCommandPausesAndResumesWithoutFinishing() {
        var controls = DictationControls()
        controls.didStart(held: false)
        XCTAssertEqual(controls.lockOrPause(), .pause)
        XCTAssertEqual(controls.mode, .paused)
        XCTAssertEqual(controls.lockOrPause(), .resume)
        XCTAssertEqual(controls.mode, .handsFree)
        XCTAssertEqual(controls.toggle(), .finish)
    }

    func testLockThenPauseWhileStillHoldingPTT() {
        var controls = DictationControls()
        _ = controls.pushToTalkDown()
        controls.didStart(held: true)
        XCTAssertEqual(controls.lockOrPause(), .lock)
        XCTAssertEqual(controls.lockOrPause(), .pause)
        XCTAssertEqual(controls.pushToTalkUp(), .none)
        XCTAssertEqual(controls.lockOrPause(), .resume)
    }

    func testFinishPausedWithEitherMainCommand() {
        var controls = DictationControls()
        controls.didStart(held: false)
        _ = controls.lockOrPause()
        XCTAssertEqual(controls.toggle(), .finish)
        XCTAssertEqual(controls.pushToTalkDown(), .finish)
    }

    func testIdleExtraCommandDoesNotStartRecording() {
        var controls = DictationControls()
        XCTAssertEqual(controls.lockOrPause(), .none)
        XCTAssertNil(controls.mode)
    }

    func testLateReleaseFromCancelledHoldDoesNotStopNewToggleRecording() {
        var controls = DictationControls()
        _ = controls.pushToTalkDown()
        controls.didStart(held: true)
        controls.didEnd()
        controls.didStart(held: false)
        XCTAssertEqual(controls.pushToTalkDown(), .none)
        XCTAssertEqual(controls.pushToTalkUp(), .none)
        XCTAssertEqual(controls.mode, .handsFree)
    }

    func testNewSessionDoesNotInheritLockOrPause() {
        var controls = DictationControls()
        _ = controls.pushToTalkDown()
        controls.didStart(held: true)
        _ = controls.lockOrPause()
        _ = controls.lockOrPause()
        controls.didEnd()
        _ = controls.pushToTalkUp()
        XCTAssertEqual(controls.pushToTalkDown(), .startHeld)
        controls.didStart(held: true)
        XCTAssertEqual(controls.mode, .held)
        XCTAssertEqual(controls.pushToTalkUp(), .finish)
    }

    func testUnmatchedKeyUpDoesNotStopHeldSession() {
        var controls = DictationControls()
        controls.didStart(held: true)
        XCTAssertEqual(controls.pushToTalkUp(), .none)
    }

    func testPausedSessionRemainsBusyButNotRecording() {
        let state = DictationController.State.paused(elapsed: 4)
        XCTAssertTrue(state.hasRecording)
        XCTAssertTrue(state.isBusy)
        XCTAssertTrue(state.isPaused)
        XCTAssertFalse(state.isRecording)
    }

    // Замок — только у зафиксированного удержания: в старт/стоп держать нечего.
    func testToggleStartIsNotLocked() {
        var controls = DictationControls()
        XCTAssertEqual(controls.toggle(), .startHandsFree)
        controls.didStart(held: false)
        XCTAssertFalse(controls.isLocked)
        _ = controls.lockOrPause()
        XCTAssertFalse(controls.isLocked, "пауза старт/стопа — не фиксация")
    }

    func testHeldIsLockedOnlyAfterCommandAndSurvivesPause() {
        var controls = DictationControls()
        _ = controls.pushToTalkDown()
        controls.didStart(held: true)
        XCTAssertFalse(controls.isLocked)
        XCTAssertEqual(controls.lockOrPause(), .lock)
        XCTAssertTrue(controls.isLocked)
        XCTAssertEqual(controls.lockOrPause(), .pause)
        XCTAssertTrue(controls.isLocked)
        XCTAssertEqual(controls.lockOrPause(), .resume)
        XCTAssertTrue(controls.isLocked)
        controls.didEnd()
        XCTAssertFalse(controls.isLocked)
        controls.didStart(held: false)
        XCTAssertFalse(controls.isLocked, "новая диктовка не наследует замок")
    }
}
