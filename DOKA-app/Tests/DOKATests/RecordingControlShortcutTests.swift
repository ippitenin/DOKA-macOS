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

    func testRightOptionPTTAddsOptionToVariant() {
        XCTAssertEqual(RecordingControlShortcut.heldVariant(
            command: .init(.space, modifiers: [.control, .shift]),
            held: HeldPushToTalk(rightKey: .option), active: true),
            .init(.space, modifiers: [.control, .option, .shift]))
    }

    func testRightCommandPTTAddsCommandToVariant() {
        XCTAssertEqual(RecordingControlShortcut.heldVariant(
            command: .init(.space, modifiers: [.control, .shift]),
            held: HeldPushToTalk(rightKey: .command), active: true),
            .init(.space, modifiers: [.control, .command, .shift]))
    }

    // MARK: - Проверка назначения

    private let ctrlSpace = KeyboardShortcuts.Shortcut(.space, modifiers: [.control])

    func testRightKeyPTTAllowsCommandEvenIfCombinedIsSystem() {
        // ⌃Пробел при PTT на правом ⌥ = ⌃⌥Пробел, системный «источник ввода».
        XCTAssertFalse(RecordingControlShortcut.conflicts(
            command: ctrlSpace, others: [], held: HeldPushToTalk(rightKey: .option),
            takenBySystem: { _ in true }))
    }

    func testShortcutPTTStillRefusesSystemCombined() {
        XCTAssertTrue(RecordingControlShortcut.conflicts(
            command: ctrlSpace, others: [], held: HeldPushToTalk(shortcut: .init(.tab, modifiers: [.option])),
            takenBySystem: { $0 == .init(.space, modifiers: [.control, .option]) }))
    }

    func testSameMainKeyAsShortcutPTTIsRefused() {
        XCTAssertTrue(RecordingControlShortcut.conflicts(
            command: ctrlSpace, others: [], held: HeldPushToTalk(shortcut: .init(.space, modifiers: [.option])),
            takenBySystem: { _ in false }))
    }

    func testDuplicateOfAnotherCommandIsRefused() {
        XCTAssertTrue(RecordingControlShortcut.conflicts(
            command: ctrlSpace, others: [ctrlSpace], held: HeldPushToTalk(rightKey: .command),
            takenBySystem: { _ in false }))
    }

    func testNoPTTAllowsFreeCommand() {
        XCTAssertFalse(RecordingControlShortcut.conflicts(
            command: ctrlSpace, others: [.init(.tab, modifiers: [.option])], held: nil,
            takenBySystem: { _ in false }))
    }
}
