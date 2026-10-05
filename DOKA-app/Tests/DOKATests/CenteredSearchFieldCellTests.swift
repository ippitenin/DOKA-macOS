import AppKit
import KeyboardShortcuts
import XCTest
@testable import DOKA

/// Центровка текста в полях без лупы: рекордеры сочетаний и рекордер кнопки
/// мыши. Текст обязан стоять по центру ВСЕГО поля — тогда «⌘1» в рекордере
/// клавиш и «Кнопка 4» в рекордере мыши стоят одинаково (с KeyboardShortcuts
/// 3.1 так же центрирует и сам `RecorderCocoa`).
@MainActor
final class CenteredSearchFieldCellTests: XCTestCase {
    private let bounds = NSRect(x: 0, y: 0, width: 130, height: 22)

    private func makeCell(text: String = "⌘1", search: Bool = false,
                          cancel: Bool = false) -> CenteredSearchFieldCell {
        let cell = CenteredSearchFieldCell(textCell: text)
        if !search { cell.searchButtonCell = nil }
        if !cancel { cell.cancelButtonCell = nil }
        return cell
    }

    private func assertCentered(_ rect: NSRect, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(rect.minX - bounds.minX, bounds.maxX - rect.maxX, accuracy: 0.001,
                       "текст не по центру поля: \(rect)", file: file, line: line)
        XCTAssertGreaterThan(rect.width, 0, file: file, line: line)
    }

    /// Без лупы и без крестика — по 4 pt с обеих сторон, а не системные −4.
    func testNoButtonsCentersWithInset() {
        let cell = makeCell()
        for rect in [cell.searchTextRect(forBounds: bounds), cell.drawingRect(forBounds: bounds)] {
            assertCentered(rect)
            XCTAssertEqual(rect.minX, 4, accuracy: 0.001)
        }
    }

    /// С крестиком — его отступ зеркалится слева, и текст не залезает под крестик.
    func testCancelButtonIsMirrored() {
        let cell = makeCell(cancel: true)
        let cancel = cell.cancelButtonRect(forBounds: bounds)
        let rect = cell.searchTextRect(forBounds: bounds)
        XCTAssertGreaterThan(cancel.width, 0, "у непустого поля крестик должен быть")
        assertCentered(rect)
        XCTAssertLessThanOrEqual(rect.maxX, cancel.minX + 0.001)
        XCTAssertEqual(rect.minX, bounds.maxX - cancel.minX, accuracy: 0.001)
    }

    /// Обычное поле поиска (с лупой) ячейка не трогает.
    func testFieldWithSearchButtonIsUntouched() {
        let ours = makeCell(search: true, cancel: true)
        let system = NSSearchFieldCell(textCell: "⌘1")
        XCTAssertEqual(ours.searchTextRect(forBounds: bounds), system.searchTextRect(forBounds: bounds))
        XCTAssertEqual(ours.drawingRect(forBounds: bounds), system.drawingRect(forBounds: bounds))
    }

    /// Рекордер KeyboardShortcuts берёт ячейку из `cellClass` (на этом держится
    /// `install()`), и у него нет лупы — значит, правка до него доходит.
    func testRecorderPicksUpInstalledCell() {
        let saved: AnyClass? = NSSearchField.cellClass
        defer { NSSearchField.cellClass = saved }
        CenteredSearchFieldCell.install()

        let recorder = KeyboardShortcuts.RecorderCocoa(for: .init("dokaTestRecorderCell"))
        let cell = recorder.cell as? CenteredSearchFieldCell
        XCTAssertNotNil(cell, "рекордер создал ячейку не через cellClass: \(type(of: recorder.cell))")
        XCTAssertNil(cell?.searchButtonCell)
        if let cell {
            assertCentered(cell.searchTextRect(forBounds: bounds))
        }
    }
}
