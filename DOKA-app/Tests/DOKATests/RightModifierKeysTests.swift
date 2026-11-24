import AppKit
import KeyboardShortcuts
import XCTest
@testable import DOKA

@MainActor
final class RightModifierKeysTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "RightModifierKeysTests"

    override func setUp() {
        super.setUp()
        UserDefaults().removePersistentDomain(forName: suite)
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testAssignPersistsAndReloads() {
        let keys = RightModifierKeys(defaults: defaults)
        XCTAssertNil(keys.assign(.option, to: .toggleRecording))
        XCTAssertEqual(keys.key(for: .toggleRecording), .option)
        XCTAssertEqual(keys.name(for: .option), .toggleRecording)
        let reloaded = RightModifierKeys(defaults: defaults)
        XCTAssertEqual(reloaded.key(for: .toggleRecording), .option)
    }

    func testKeyTakenByAnotherCommandIsRefused() {
        let keys = RightModifierKeys(defaults: defaults)
        keys.assign(.command, to: .pushToTalk)
        XCTAssertEqual(keys.assign(.command, to: .toggleRecording), .pushToTalk)
        XCTAssertNil(keys.key(for: .toggleRecording))
        XCTAssertEqual(keys.name(for: .command), .pushToTalk)
    }

    func testReassigningCommandReplacesItsKey() {
        let keys = RightModifierKeys(defaults: defaults)
        keys.assign(.option, to: .toggleRecording)
        XCTAssertNil(keys.assign(.command, to: .toggleRecording))
        XCTAssertEqual(keys.key(for: .toggleRecording), .command)
        XCTAssertNil(keys.name(for: .option))
    }

    func testClear() {
        let keys = RightModifierKeys(defaults: defaults)
        keys.assign(.option, to: .pasteLast)
        keys.clear(.pasteLast)
        XCTAssertNil(keys.key(for: .pasteLast))
        XCTAssertNil(RightModifierKeys(defaults: defaults).key(for: .pasteLast))
    }

    func testGarbageInDefaultsIsIgnored() {
        defaults.set(["toggleRecording": "fn"], forKey: RightModifierKeys.storageKey)
        XCTAssertNil(RightModifierKeys(defaults: defaults).key(for: .toggleRecording))
    }

    func testPressedStateUsesDeviceBitNotSharedFlag() {
        // Левый ⌥ зажат (общий флаг .option есть), правый отпущен.
        let leftOnly = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.option.rawValue | 0x20)
        XCTAssertFalse(RightModifierKey.option.isDown(in: leftOnly))
        let right = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.option.rawValue | 0x40)
        XCTAssertTrue(RightModifierKey.option.isDown(in: right))
        XCTAssertEqual(RightModifierKey(keyCode: 61), .option)
        XCTAssertEqual(RightModifierKey(keyCode: 54), .command)
        XCTAssertNil(RightModifierKey(keyCode: 58), "левый ⌥ — не правая клавиша")
    }
}
