import XCTest
@testable import DOKA

/// Корзина фонового удаления — общая у библиотеки, моделей и «Губ».
/// Зачем: каждый пункт здесь — про потерю данных или мусор. Переименование
/// убирает элемент сразу, стирание корзины не задевает соседей, а огрызок
/// корзины узнаётся по имени при уборке на старте.
final class DiskTrashTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("doka-disktrash-tests-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? fm.removeItem(at: root)
    }

    private func makeFolder(_ name: String, bytes: Int = 4) throws -> URL {
        let folder = root.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(repeating: 1, count: bytes).write(to: folder.appendingPathComponent("file.bin"))
        return folder
    }

    func testMoveRenamesNextToItself() throws {
        let folder = try makeFolder("record")
        let bin = try XCTUnwrap(DiskTrash.move(folder))
        XCTAssertFalse(fm.fileExists(atPath: folder.path))
        XCTAssertTrue(fm.fileExists(atPath: bin.appendingPathComponent("file.bin").path))
        XCTAssertEqual(bin.deletingLastPathComponent().standardizedFileURL, root.standardizedFileURL)
        XCTAssertTrue(bin.lastPathComponent.hasPrefix("record.deleting-"))
        XCTAssertTrue(DiskTrash.isTrash(bin.lastPathComponent))
    }

    func testMoveOfMissingItemIsNil() {
        XCTAssertNil(DiskTrash.move(root.appendingPathComponent("nothing")))
    }

    func testEmptyRemovesOnlyTrash() throws {
        let keep = try makeFolder("keep")
        let gone = try makeFolder("gone")
        DiskTrash.move(gone)
        DiskTrash.empty(root)
        XCTAssertTrue(fm.fileExists(atPath: keep.path))
        let names = try fm.contentsOfDirectory(atPath: root.path)
        XCTAssertEqual(names, ["keep"])
    }

    func testAllocatedSizeCountsNestedFiles() throws {
        let folder = try makeFolder("model", bytes: 10_000)
        let nested = folder.appendingPathComponent("nested", isDirectory: true)
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data(repeating: 2, count: 10_000).write(to: nested.appendingPathComponent("more.bin"))
        XCTAssertGreaterThanOrEqual(fm.allocatedSize(of: folder), 20_000)
        XCTAssertEqual(fm.allocatedSize(of: root.appendingPathComponent("nothing")), 0)
    }

    func testModificationDate() throws {
        let folder = try makeFolder("dated")
        let past = Date(timeIntervalSince1970: 1_700_000_000)
        try fm.setAttributes([.modificationDate: past], ofItemAtPath: folder.path)
        XCTAssertEqual(URL(fileURLWithPath: folder.path).contentModificationDate?.timeIntervalSince1970 ?? 0,
                       past.timeIntervalSince1970, accuracy: 1)
        XCTAssertNil(root.appendingPathComponent("nothing").contentModificationDate)
    }
}
