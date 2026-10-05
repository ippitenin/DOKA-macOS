import AppKit
import UniformTypeIdentifiers

/// PDF ИИ-анализа: шапка (запись, название анализа, модель и даты), текст
/// отчёта и номера страниц «2 / 5» внизу.
///
/// Документ собирается НАТИВНО из блоков `LightMarkdown`, а не импортом
/// `NSAttributedString(html:)`: импорт раскладывает таблицы сам и сжимает
/// короткие колонки до буквы в строке («С/р/о/к»), теряет точки нумерации и
/// отступы списков. Здесь ширины колонок считает `PDFTableLayout` по ширине
/// страницы, поэтому широкая таблица переносит текст в ячейках, а не
/// вылезает за поле.
///
/// Бумага — всегда A4 с полями 2 см (решение владельца): «как в системе» на
/// маке с регионом США дало бы Letter. Цвета фиксированные, не системные:
/// в тёмной теме `labelColor` белый, и текст пропал бы на белой бумаге.
/// Тайм-коды остаются текстом — ссылки на плеер в файле бессмысленны.
@MainActor
enum AnalysisPDF {
    struct Header {
        /// Название записи — крупным заголовком.
        var title: String
        /// Название анализа (шаблон или «Свой запрос»).
        var subtitle: String
        /// Строки метаданных мелким серым: дата записи, модель и дата анализа.
        var meta: [String]
    }

    /// A4 в пунктах.
    static let paperSize = NSSize(width: 595.28, height: 841.89)
    /// 2 см.
    static let margin: CGFloat = 72 / 2.54 * 2
    static var contentWidth: CGFloat { paperSize.width - margin * 2 }

    private static let bodySize: CGFloat = 11
    private static let tableSize: CGFloat = 9.5
    private static let cellPaddingX: CGFloat = 5
    private static let cellPaddingY: CGFloat = 3
    private static let borderWidth: CGFloat = 0.5
    private static let listIndent: CGFloat = 18

    private static let textColor = NSColor(white: 0.1, alpha: 1)
    private static let secondaryColor = NSColor(white: 0.42, alpha: 1)
    private static let ruleColor = NSColor(white: 0.78, alpha: 1)
    private static let headerFill = NSColor(white: 0.95, alpha: 1)

    // MARK: - Сохранение

    /// «Сохранить как…» → PDF: системный диалог и запись файла.
    static func save(markdown: String, header: Header, suggestedName: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.pdf]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if !write(document(markdown: markdown, header: header), title: header.title, to: url) {
            NSLog("DOKA: не удалось сохранить PDF анализа: \(url.path)")
        }
    }

    /// Печать документа в PDF-файл без диалогов. Страницы режет `NSTextView`:
    /// строку текста он пополам не разрывает.
    @discardableResult
    static func write(_ document: NSAttributedString, title: String, to url: URL) -> Bool {
        guard let info = NSPrintInfo.shared.copy() as? NSPrintInfo else { return false }
        info.paperSize = paperSize
        info.orientation = .portrait
        info.topMargin = margin
        info.bottomMargin = margin
        info.leftMargin = margin
        info.rightMargin = margin
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
        info.dictionary()[NSPrintInfo.AttributeKey.headerAndFooter] = true

        // TextKit 1 явно: таблицы (`NSTextTable`) TextKit 2 не рисует.
        let view = PageNumberedTextView(usingTextLayoutManager: false)
        view.frame = NSRect(x: 0, y: 0, width: contentWidth, height: 1)
        view.isEditable = false
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.isVerticallyResizable = true
        view.textStorage?.setAttributedString(document)
        if let container = view.textContainer {
            view.layoutManager?.ensureLayout(for: container)
        }
        view.sizeToFit()

        let operation = NSPrintOperation(view: view, printInfo: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        operation.jobTitle = title
        return operation.run()
    }

    // MARK: - Документ

    static func document(markdown: String, header: Header) -> NSAttributedString {
        let out = NSMutableAttributedString()

        // Шапка — один текстовый блок с линией снизу.
        // Ширина — абсолютная, ровно по тексту: с «100 %» линия вылезала за
        // правый край текста, а без ширины блок не рисуется вовсе.
        let headerBlock = NSTextBlock()
        headerBlock.setContentWidth(contentWidth, type: .absoluteValueType)
        headerBlock.setWidth(borderWidth, type: .absoluteValueType, for: .border, edge: .maxY)
        headerBlock.setBorderColor(ruleColor, for: .maxY)
        headerBlock.setWidth(10, type: .absoluteValueType, for: .padding, edge: .maxY)
        headerBlock.setWidth(14, type: .absoluteValueType, for: .margin, edge: .maxY)
        if !header.title.isEmpty {
            appendParagraph(plain(header.title, font: font(18, .bold), color: textColor),
                            to: out, style: style(after: 3, blocks: [headerBlock]))
        }
        if !header.subtitle.isEmpty {
            appendParagraph(plain(header.subtitle, font: font(12.5, .semibold),
                                  color: textColor),
                            to: out, style: style(after: 4, blocks: [headerBlock]))
        }
        for line in header.meta where !line.isEmpty {
            appendParagraph(plain(line, font: font(9), color: secondaryColor),
                            to: out, style: style(after: 1, blocks: [headerBlock]))
        }

        var previous: LightMarkdown.Block?
        var extraSpace: CGFloat = 0
        for block in LightMarkdown.parse(markdown) {
            let isFirst = previous == nil
            switch block {
            case let .heading(level, text):
                let size: CGFloat = level <= 1 ? 15 : (level == 2 ? 13.5 : 12)
                appendParagraph(inline(text, font: font(size, .bold)), to: out,
                                style: style(before: (isFirst ? 0 : 12) + extraSpace, after: 4))
            case let .paragraph(text):
                appendParagraph(inline(text, font: font(bodySize)), to: out,
                                style: style(before: spacing(after: previous) + extraSpace))
            case let .bullet(text):
                appendListItem(marker: "•", text: text, to: out,
                               before: listSpacing(after: previous) + extraSpace)
            case let .ordered(number, text):
                appendListItem(marker: "\(number).", text: text, to: out,
                               before: listSpacing(after: previous) + extraSpace)
            case let .table(headerCells, rows):
                appendTable(header: headerCells, rows: rows, to: out,
                            before: (isFirst ? 0 : 6) + extraSpace)
            case .rule:
                // Как на экране: `---` — воздух, а не линия.
                extraSpace += 8
                continue
            }
            extraSpace = 0
            previous = block
        }
        return out
    }

    // MARK: - Блоки

    private static func appendListItem(marker: String, text: String,
                                       to out: NSMutableAttributedString, before: CGFloat) {
        let paragraph = style(before: before, after: 0)
        paragraph.headIndent = listIndent
        paragraph.firstLineHeadIndent = 0
        paragraph.tabStops = [NSTextTab(textAlignment: .left, location: listIndent)]
        let bodyFont = font(bodySize)
        let line = NSMutableAttributedString(attributedString: plain(marker + "\t", font: bodyFont, color: textColor))
        line.append(inline(text, font: bodyFont))
        appendParagraph(line, to: out, style: paragraph)
    }

    private static func appendTable(header: [String], rows: [[String]],
                                    to out: NSMutableAttributedString, before: CGFloat) {
        let columnCount = max(header.count, rows.map(\.count).max() ?? 0)
        guard columnCount > 0 else { return }
        let headerFont = font(tableSize, .semibold)
        let bodyFont = font(tableSize)
        let allRows = [header] + rows
        func cell(_ row: Int, _ column: Int) -> NSAttributedString {
            let cells = allRows[row]
            return inline(column < cells.count ? cells[column] : "",
                          font: row == 0 ? headerFont : bodyFont)
        }

        // Ширины: по содержимому, в сумме — ровно ширина страницы. Поверх
        // полей ячейки — запас в пару пунктов: раскладка строки в блоке
        // таблицы чуть шире замера `size()`, и без запаса «Срок» рвался на «Сро/к».
        let chrome = cellPaddingX * 2 + borderWidth * 2 + 3
        var minimums = [CGFloat](repeating: 0, count: columnCount)
        var naturals = [CGFloat](repeating: 0, count: columnCount)
        for row in allRows.indices {
            for column in 0..<columnCount {
                let text = cell(row, column)
                naturals[column] = max(naturals[column], ceil(text.size().width) + chrome)
                minimums[column] = max(minimums[column], longestWordWidth(text) + chrome)
            }
        }
        let widths = PDFTableLayout.widths(minimums: minimums, naturals: naturals,
                                           available: contentWidth)

        // Воздух над таблицей — пустой строкой нужной высоты, а не отступом
        // самой таблицы: `margin` NSTextTable вычитает из ширины, и после
        // заголовка таблица выходила уже текста на 6 pt (замерено по PDF).
        if before > 0 {
            let spacer = NSMutableParagraphStyle()
            spacer.minimumLineHeight = before
            spacer.maximumLineHeight = before
            out.append(NSAttributedString(string: "\n", attributes: [.font: font(1),
                                                                     .paragraphStyle: spacer]))
        }
        let table = NSTextTable()
        table.numberOfColumns = columnCount
        table.layoutAlgorithm = .fixedLayoutAlgorithm
        table.collapsesBorders = true
        table.hidesEmptyCells = false

        for row in allRows.indices {
            for column in 0..<columnCount {
                let block = NSTextTableBlock(table: table, startingRow: row, rowSpan: 1,
                                             startingColumn: column, columnSpan: 1)
                // Линии схлопнуты: на ячейку приходится одна; запас замера
                // остаётся в ширине текста.
                block.setContentWidth(max(1, widths[column] - cellPaddingX * 2 - borderWidth),
                                      type: .absoluteValueType)
                block.setWidth(borderWidth, type: .absoluteValueType, for: .border)
                block.setBorderColor(ruleColor)
                block.setWidth(cellPaddingX, type: .absoluteValueType, for: .padding, edge: .minX)
                block.setWidth(cellPaddingX, type: .absoluteValueType, for: .padding, edge: .maxX)
                block.setWidth(cellPaddingY, type: .absoluteValueType, for: .padding, edge: .minY)
                block.setWidth(cellPaddingY, type: .absoluteValueType, for: .padding, edge: .maxY)
                if row == 0 { block.backgroundColor = headerFill }
                appendParagraph(cell(row, column), to: out, style: style(after: 0, blocks: [block]))
            }
        }
    }

    // MARK: - Текст

    /// Шрифт бумаги — Helvetica Neue, НЕ системный: у SF Pro кириллическая «к»
    /// нарисована общим глифом с латинской «ĸ» (kra), и текст, скопированный из
    /// PDF, выходил «Теĸст», а поиск по «команда» в Просмотре ничего не находил.
    /// Helvetica Neue (и Menlo для кода) извлекается чисто — проверено тестом.
    static func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        let descriptor = NSFontDescriptor(fontAttributes: [
            .family: "Helvetica Neue",
            .traits: [NSFontDescriptor.TraitKey.weight: weight]
        ])
        return NSFont(descriptor: descriptor, size: size) ?? .systemFont(ofSize: size, weight: weight)
    }

    /// Inline-разметка строки (**жирный**, *курсив*, `код`, ссылки) — тем же
    /// разбором, что экранный рендер, но со шрифтами для бумаги. Переносы
    /// `<br>` — разделителем строк (U+2028), а не концом абзаца: абзац в ячейке
    /// таблицы обязан остаться одним.
    static func inline(_ text: String, font: NSFont) -> NSAttributedString {
        let parsed = LightMarkdown.inlineAttributed(text)
        let out = NSMutableAttributedString()
        for run in parsed.runs {
            let piece = String(parsed[run.range].characters)
                .replacingOccurrences(of: "\n", with: "\u{2028}")
            let intent = run.inlinePresentationIntent ?? []
            var runFont = font
            if intent.contains(.code) {
                runFont = NSFont(name: "Menlo-Regular", size: font.pointSize * 0.9)
                    ?? .monospacedSystemFont(ofSize: font.pointSize * 0.9, weight: .regular)
            }
            var traits: NSFontDescriptor.SymbolicTraits = []
            if intent.contains(.stronglyEmphasized) { traits.insert(.bold) }
            if intent.contains(.emphasized) { traits.insert(.italic) }
            if !traits.isEmpty {
                let descriptor = runFont.fontDescriptor.withSymbolicTraits(
                    runFont.fontDescriptor.symbolicTraits.union(traits))
                runFont = NSFont(descriptor: descriptor, size: runFont.pointSize) ?? runFont
            }
            var attributes: [NSAttributedString.Key: Any] = [.font: runFont, .foregroundColor: textColor]
            if intent.contains(.strikethrough) {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            out.append(NSAttributedString(string: piece, attributes: attributes))
        }
        return out
    }

    private static func plain(_ text: String, font: NSFont, color: NSColor) -> NSAttributedString {
        NSAttributedString(string: text.replacingOccurrences(of: "\n", with: "\u{2028}"),
                           attributes: [.font: font, .foregroundColor: color])
    }

    private static func appendParagraph(_ text: NSAttributedString, to out: NSMutableAttributedString,
                                        style: NSParagraphStyle) {
        let paragraph = NSMutableAttributedString(attributedString: text)
        paragraph.append(NSAttributedString(string: "\n", attributes: [.font: font(bodySize)]))
        paragraph.addAttribute(.paragraphStyle, value: style,
                               range: NSRange(location: 0, length: paragraph.length))
        out.append(paragraph)
    }

    private static func style(before: CGFloat = 0, after: CGFloat = 0,
                              blocks: [NSTextBlock] = []) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacingBefore = before
        style.paragraphSpacing = after
        style.lineHeightMultiple = 1.12
        style.textBlocks = blocks
        return style
    }

    /// Абзац после абзаца или списка — с воздухом, сразу под заголовком — плотнее.
    private static func spacing(after previous: LightMarkdown.Block?) -> CGFloat {
        switch previous {
        case .none: return 0
        case .heading: return 2
        default: return 7
        }
    }

    /// Пункты одного списка — плотно, первый пункт — как абзац.
    private static func listSpacing(after previous: LightMarkdown.Block?) -> CGFloat {
        switch previous {
        case .bullet, .ordered: return 2
        default: return spacing(after: previous)
        }
    }

    /// Ширина самого длинного слова — меньше неё колонку не сжимаем, чтобы
    /// «Срок» не рвался по буквам.
    private static func longestWordWidth(_ text: NSAttributedString) -> CGFloat {
        let string = text.string as NSString
        var widest: CGFloat = 0
        string.enumerateSubstrings(in: NSRange(location: 0, length: string.length),
                                   options: .byWords) { _, range, _, _ in
            widest = max(widest, ceil(text.attributedSubstring(from: range).size().width))
        }
        return widest
    }
}

/// `NSTextView` для печати: без верхнего колонтитула, внизу по центру —
/// «страница / всего».
private final class PageNumberedTextView: NSTextView {
    override var pageHeader: NSAttributedString { NSAttributedString() }

    override var pageFooter: NSAttributedString {
        guard let operation = NSPrintOperation.current else { return NSAttributedString() }
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        return NSAttributedString(
            string: "\(operation.currentPage) / \(operation.pageRange.length)",
            attributes: [.font: AnalysisPDF.font(8.5),
                         .foregroundColor: NSColor(white: 0.42, alpha: 1),
                         .paragraphStyle: style])
    }
}

/// Ширины колонок таблицы на странице: чистая логика.
enum PDFTableLayout {
    /// Самое длинное слово не занимает больше этой доли страницы: строку без
    /// пробелов всё равно придётся рвать, и пусть она не отнимает место у
    /// соседних колонок.
    static let maxMinimumShare: CGFloat = 0.3

    /// `minimums` — ширина самого длинного слова колонки, `naturals` — ширина
    /// самой длинной ячейки одной строкой (обе — с полями ячейки). Сумма
    /// результата всегда равна `available`:
    /// - всё влезает одной строкой — колонки растягиваются пропорционально;
    /// - иначе узкие колонки (№, срок, статус — те, кому хватает средней доли
    ///   оставшегося места) получают ширину в одну строку, а остаток делят
    ///   длинные: каждой минимум плюс доля пропорционально тому, сколько ей не
    ///   хватает до одной строки. Без первого шага узкая колонка получала
    ///   «минимум плюс крохи», и «Участник 1» влезал в строку, а «Участник 3» — нет;
    /// - не влезают даже минимумы — они сжимаются пропорционально.
    static func widths(minimums: [CGFloat], naturals: [CGFloat], available: CGFloat) -> [CGFloat] {
        let count = min(minimums.count, naturals.count)
        guard count > 0, available > 0 else { return [] }
        let mins = (0..<count).map { max(0, min(minimums[$0], available * maxMinimumShare)) }
        let nats = (0..<count).map { max(mins[$0], naturals[$0]) }
        let natSum = nats.reduce(0, +)
        if natSum <= available {
            return natSum > 0
                ? nats.map { $0 * available / natSum }
                : [CGFloat](repeating: available / CGFloat(count), count: count)
        }

        // Узкие колонки — в одну строку, пока им хватает средней доли остатка.
        var result = [CGFloat?](repeating: nil, count: count)
        var remaining = available
        var changed = true
        while changed {
            changed = false
            let free = result.indices.filter { result[$0] == nil }
            guard free.count > 1 else { break }
            let fair = remaining / CGFloat(free.count)
            for index in free where nats[index] <= fair {
                result[index] = nats[index]
                remaining -= nats[index]
                changed = true
            }
        }

        // Длинные — минимум плюс доля недостающего.
        let free = result.indices.filter { result[$0] == nil }
        let minSum = free.map { mins[$0] }.reduce(0, +)
        if minSum >= remaining {
            // Минимумы длинных не влезают: сжимаем ВСЕ минимумы, узкие
            // колонки тоже возвращаются к своему минимуму.
            let allMin = mins.reduce(0, +)
            return allMin > 0
                ? mins.map { $0 * available / allMin }
                : [CGFloat](repeating: available / CGFloat(count), count: count)
        }
        let extra = remaining - minSum
        let slackSum = free.map { nats[$0] - mins[$0] }.reduce(0, +)
        for index in free {
            let slack = nats[index] - mins[index]
            result[index] = mins[index] + (slackSum > 0 ? slack * extra / slackSum
                                                       : extra / CGFloat(free.count))
        }
        return result.map { $0 ?? 0 }
    }
}
