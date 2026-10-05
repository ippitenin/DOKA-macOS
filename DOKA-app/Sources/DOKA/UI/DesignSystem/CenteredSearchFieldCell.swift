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

    /// Текст — по центру ВСЕГО поля: правый отступ (крестик или 4 pt без
    /// него) зеркалится слева. Так же с версии 3.1 центрирует текст на
    /// macOS 27 и сам `RecorderCocoa` (его `layout()` двигает подвью поля,
    /// только если справа отступ больше, чем слева, — после нашей ячейки
    /// это уже не так, и правки не складываются). Прежняя центровка «между
    /// левой кромкой и крестиком» разъехалась бы с рекордерами клавиш: у
    /// них текст по центру поля, у рекордера мыши — левее.
    private func centered(_ system: NSRect, in bounds: NSRect) -> NSRect {
        guard searchButtonCell == nil else { return system }
        // У пустого поля система отдаёт крестику прямоугольник нулевой
        // ширины у правой кромки — такой крестик считается отсутствующим.
        let cancel = cancelButtonCell != nil ? cancelButtonRect(forBounds: bounds) : .zero
        let right = cancel.width > 0 ? cancel.minX : bounds.maxX - Self.inset
        let sideInset = max(Self.inset, bounds.maxX - right)
        var rect = system
        rect.origin.x = bounds.minX + sideInset
        rect.size.width = max(0, bounds.width - sideInset * 2)
        return rect
    }
}
