import KeyboardShortcuts
import XCTest
@testable import DOKA

/// Имена глобальных сочетаний и их хранение. Главное — сочетания, сохранённые
/// прошлыми версиями, переживают обновление KeyboardShortcuts (2.4 → 3.1
/// переименовал `default:` в `initial:`): потерять их значит молча оставить
/// пользователя без хоткея диктовки.
///
/// Фикстуры — строки ровно в том виде, в каком их хранит установленная DOKA
/// (ключ `KeyboardShortcuts_<имя>`, JSON с carbon-кодами; порядок ключей у
/// разных записей разный — так их и записала 2.x).
@MainActor
final class HotkeyNamesTests: XCTestCase {
    private var usedKeys: [String] = []

    override func tearDown() {
        for key in usedKeys { UserDefaults.standard.removeObject(forKey: key) }
        usedKeys = []
        super.tearDown()
    }

    /// Тестовое имя с уже сохранённым значением — как у пользователя после
    /// обновления. Имя уникально на тест: хранение у пакета глобальное.
    private func storedName(_ value: Any?, initial: KeyboardShortcuts.Shortcut? = nil,
                            id: String = #function) -> KeyboardShortcuts.Name {
        // Точка в имени запрещена пакетом — оставляем только буквы и цифры.
        let raw = "dokaTest" + id.filter { $0.isLetter || $0.isNumber }
        let key = "KeyboardShortcuts_" + raw
        usedKeys.append(key)
        UserDefaults.standard.removeObject(forKey: key)
        if let value { UserDefaults.standard.set(value, forKey: key) }
        return KeyboardShortcuts.Name(raw, initial: initial)
    }

    func testInitialShortcuts() {
        XCTAssertEqual(KeyboardShortcuts.Name.toggleRecording.initialShortcut,
                       .init(.tab, modifiers: [.option]))
        XCTAssertEqual(KeyboardShortcuts.Name.pasteLast.initialShortcut,
                       .init(.v, modifiers: [.control, .option]))
        XCTAssertEqual(KeyboardShortcuts.Name.cancelRecording.initialShortcut, .init(.escape))
        // Без дефолта намеренно: глобальный Cmd+, отобрал бы «Настройки» у всех
        // приложений, а push-to-talk и тихий режим пользователь задаёт сам.
        XCTAssertNil(KeyboardShortcuts.Name.pushToTalk.initialShortcut)
        XCTAssertNil(KeyboardShortcuts.Name.openMainWindow.initialShortcut)
        XCTAssertNil(KeyboardShortcuts.Name.openHistoryWindow.initialShortcut)
        XCTAssertNil(KeyboardShortcuts.Name.toggleQuietMode.initialShortcut)
    }

    /// Строки, записанные прошлой версией пакета, читаются как те же сочетания.
    func testShortcutsStoredByPreviousVersionDecode() {
        let cases: [(String, KeyboardShortcuts.Shortcut)] = [
            (#"{"carbonKeyCode":48,"carbonModifiers":2048}"#, .init(.tab, modifiers: [.option])),
            (#"{"carbonKeyCode":9,"carbonModifiers":6144}"#, .init(.v, modifiers: [.control, .option])),
            (#"{"carbonKeyCode":53,"carbonModifiers":0}"#, .init(.escape)),
            (#"{"carbonKeyCode":18,"carbonModifiers":256}"#, .init(.one, modifiers: [.command])),
            (#"{"carbonModifiers":256,"carbonKeyCode":19}"#, .init(.two, modifiers: [.command]))
        ]
        for (index, (stored, expected)) in cases.enumerated() {
            let name = storedName(stored, id: "decode\(index)")
            XCTAssertEqual(KeyboardShortcuts.getShortcut(for: name), expected, stored)
        }
    }

    /// Своё сочетание пользователя дефолт не перетирает.
    func testStoredShortcutWinsOverInitial() {
        let name = storedName(#"{"carbonKeyCode":9,"carbonModifiers":6144}"#,
                              initial: .init(.tab, modifiers: [.option]))
        XCTAssertEqual(KeyboardShortcuts.getShortcut(for: name), .init(.v, modifiers: [.control, .option]))
    }

    /// Сочетание, которое пользователь стёр (хранится `false`), остаётся
    /// стёртым и после обновления — дефолт не возвращается.
    func testDisabledShortcutStaysDisabled() {
        let name = storedName(false, initial: .init(.tab, modifiers: [.option]))
        XCTAssertNil(KeyboardShortcuts.getShortcut(for: name))
    }

    /// Новая установка — сочетание по умолчанию сразу на месте.
    func testMissingShortcutGetsInitial() {
        let name = storedName(nil, initial: .init(.tab, modifiers: [.option]))
        XCTAssertEqual(KeyboardShortcuts.getShortcut(for: name), .init(.tab, modifiers: [.option]))
    }
}
