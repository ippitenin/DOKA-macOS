import AppKit

/// Ячейка поля поиска, которая честно центрирует текст, когда иконка лупы
/// убрана. Так устроены рекордеры сочетаний (`KeyboardShortcuts.RecorderCocoa`)
/// и наш рекордер кнопки мыши (`CaptureField`): на macOS 27 без лупы
/// системная область текста начинается с −4 pt при полной ширине поля, и
/// центрированные «Добавить» и «⌘1» уезжали на 4 pt влево (проверено стендом:
/// `searchTextRect` = (−4, 4, 130, 16) у поля шириной 130).
///
/// Правка срабатывает ТОЛЬКО у полей без лупы (`searchButtonCell == nil`):
/// обычные поля поиска рисуются системой как есть.
final class CenteredSearchFieldCell: NSSearchFieldCell {
    /// Отступ текста от левой кромки и от крестика (или правой кромки).
    private static let inset: CGFloat = 4

    /// Ставит ячейку всем `NSSearchField` приложения. Звать до создания
    /// первого поля: рекордеры `KeyboardShortcuts` своего типа ячейки не
    /// задают, а берут `cellClass` в момент создания.
    static func install() {
        NSSearchField.cellClass = CenteredSearchFieldCell.self
    }

    override func searchTextRect(forBounds rect: NSRect) -> NSRect {
        centered(super.searchTextRect(forBounds: rect), in: rect)
    }

    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        centered(super.drawingRect(forBounds: rect), in: rect)
    }

    /// Текст — между левой кромкой и крестиком (без крестика — правой
    /// кромкой), с одинаковым отступом по обе стороны.
    private func centered(_ system: NSRect, in bounds: NSRect) -> NSRect {
        guard searchButtonCell == nil else { return system }
        // У пустого поля система отдаёт крестику прямоугольник нулевой
        // ширины у правой кромки — такой крестик считается отсутствующим.
        let cancel = cancelButtonCell != nil ? cancelButtonRect(forBounds: bounds) : .zero
        let right = cancel.width > 0 ? cancel.minX : bounds.maxX - Self.inset
        var rect = system
        rect.origin.x = bounds.minX + Self.inset
        rect.size.width = max(0, right - rect.origin.x)
        return rect
    }
}
