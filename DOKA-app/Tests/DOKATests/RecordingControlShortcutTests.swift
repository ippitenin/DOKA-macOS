import KeyboardShortcuts
import XCTest
@testable import DOKA

@MainActor
final class RecordingControlShortcutTests: XCTestCase {
    func testIdleDoesNotRegisterVariant() {
        XCTAssertNil(RecordingControlShortcut.heldVariant(
            command: .init(.space, modifiers: [.control, .shift]),
            pushToTalk: .init(.tab, modifiers: [.option]), active: false))
    }

    func testMissingAssignmentsDoNotRegisterVariant() {
        XCTAssertNil(RecordingControlShortcut.heldVariant(
            command: nil, pushToTalk: .init(.tab, modifiers: [.option]), active: true))
        XCTAssertNil(RecordingControlShortcut.heldVariant(
            command: .init(.space, modifiers: [.control, .shift]), pushToTalk: nil, active: true))
    }

    func testExtraPTTModifiersAreIncluded() {
        XCTAssertEqual(RecordingControlShortcut.heldVariant(
            command: .init(.space, modifiers: [.control, .shift]),
            pushToTalk: .init(.tab, modifiers: [.option]), active: true),
            .init(.space, modifiers: [.control, .option, .shift]))
    }

    func testNoDuplicateRegistrationWhenPTTModifiersAlreadyIncluded() {
        XCTAssertNil(RecordingControlShortcut.heldVariant(
            command: .init(.space, modifiers: [.control, .shift]),
            pushToTalk: .init(.tab, modifiers: [.control]), active: true))
    }

    func testSameMainKeyCannotBePressedWhileHeld() {
        XCTAssertNil(RecordingControlShortcut.heldVariant(
            command: .init(.space, modifiers: [.control, .shift]),
            pushToTalk: .init(.space, modifiers: [.option]), active: true))
    }
}
