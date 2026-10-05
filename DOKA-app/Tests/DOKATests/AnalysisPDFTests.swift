import AppKit
import PDFKit
import XCTest
@testable import DOKA

/// PDF ИИ-анализа: ширины колонок таблицы, сборка документа из Markdown и
/// настоящая запись файла (страницы A4, кириллица, номера «N / M»).
@MainActor
final class AnalysisPDFTests: XCTestCase {

    private func assertSum(_ widths: [CGFloat], _ available: CGFloat,
                           file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(widths.reduce(0, +), available, accuracy: 0.001, file: file, line: line)
    }

    // MARK: - PDFTableLayout

    /// Всё влезает одной строкой — колонки растягиваются пропорционально.
    func testColumnsStretchWhenEverythingFits() {
        let widths = PDFTableLayout.widths(minimums: [20, 30], naturals: [50, 150], available: 400)
        assertSum(widths, 400)
        XCTAssertEqual(widths[0], 100, accuracy: 0.001)
        XCTAssertEqual(widths[1], 300, accuracy: 0.001)
    }

    /// Узкие колонки (№, кто, срок) — в одну строку, длинная забирает остаток.
    func testNarrowColumnsKeepOneLine() {
        let widths = PDFTableLayout.widths(minimums: [20, 50, 60, 30],
                                           naturals: [20, 60, 600, 35], available: 480)
        assertSum(widths, 480)
        XCTAssertEqual(widths[0], 20, accuracy: 0.001)
        XCTAssertEqual(widths[1], 60, accuracy: 0.001)
        XCTAssertEqual(widths[3], 35, accuracy: 0.001)
        XCTAssertEqual(widths[2], 365, accuracy: 0.001)
    }

    /// Две длинные колонки делят место пропорционально недостающему, и обе
    /// не уже своего самого длинного слова.
    func testLongColumnsShareByShortfall() {
        let widths = PDFTableLayout.widths(minimums: [100, 50], naturals: [300, 650], available: 450)
        assertSum(widths, 450)
        XCTAssertGreaterThanOrEqual(widths[0], 100)
        XCTAssertGreaterThanOrEqual(widths[1], 50)
        XCTAssertGreaterThan(widths[1], widths[0])
    }

    /// Не влезают даже минимумы — они сжимаются пропорционально; слово без
    /// пробелов не отнимает больше 30 % страницы.
    func testMinimumsShrinkAndLongWordIsCapped() {
        // Четыре колонки по 30 % — уже больше страницы.
        let squeezed = PDFTableLayout.widths(minimums: [200, 200, 200, 200],
                                             naturals: [400, 400, 400, 400], available: 300)
        assertSum(squeezed, 300)
        XCTAssertEqual(squeezed[0], 75, accuracy: 0.001)

        let capped = PDFTableLayout.widths(minimums: [450, 40], naturals: [450, 300], available: 480)
        assertSum(capped, 480)
        XCTAssertLessThan(capped[0], 450)
    }

    func testEmptyTable() {
        XCTAssertEqual(PDFTableLayout.widths(minimums: [], naturals: [], available: 480), [])
        XCTAssertEqual(PDFTableLayout.widths(minimums: [10], naturals: [10], available: 0), [])
    }

    // MARK: - Документ

    private let sample = """
    ## Итоги

    Обсудили **релиз** и *сроки*.

    - [03:12] Релиз 20 октября
    - [11:45] Бета для команды

    1. Первый
    2. Второй

    | Кто | Что | Срок |
    | --- | --- | --- |
    | Анна | Сборка беты | 12.10 |
    | Илья | Импорт<br>шаблонов | 08.10 |
    """

    private var header: AnalysisPDF.Header {
        AnalysisPDF.Header(title: "Встреча с командой", subtitle: "Протокол встречи",
                           meta: ["Запись: 3 окт. 2026", "Анализ: Qwen3.5 4B"])
    }

    /// Разметка уходит в шрифты: в тексте нет ни `#`, ни `**`, ни `|`,
    /// тайм-коды остаются текстом, у списков — свои маркеры.
    func testDocumentHasNoMarkdownSyntax() {
        let text = AnalysisPDF.document(markdown: sample, header: header).string
        XCTAssertTrue(text.hasPrefix("Встреча с командой\nПротокол встречи\nЗапись: 3 окт. 2026"))
        XCTAssertFalse(text.contains("#"))
        XCTAssertFalse(text.contains("**"))
        XCTAssertFalse(text.contains("|"))
        XCTAssertFalse(text.contains("<br>"))
        XCTAssertTrue(text.contains("•\t[03:12] Релиз 20 октября"))
        XCTAssertTrue(text.contains("2.\tВторой"))
        // Перенос в ячейке — разделитель строк, абзац ячейки остаётся одним.
        XCTAssertTrue(text.contains("Импорт\u{2028}шаблонов"))
    }

    func testInlineEmphasisBecomesFonts() {
        let text = AnalysisPDF.inline("Обсудили **релиз** и *сроки*.", font: .systemFont(ofSize: 11))
        XCTAssertEqual(text.string, "Обсудили релиз и сроки.")
        let boldFont = text.attribute(.font, at: 9, effectiveRange: nil) as? NSFont
        let italicFont = text.attribute(.font, at: 17, effectiveRange: nil) as? NSFont
        let plainFont = text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertTrue(boldFont?.fontDescriptor.symbolicTraits.contains(.bold) ?? false)
        XCTAssertTrue(italicFont?.fontDescriptor.symbolicTraits.contains(.italic) ?? false)
        XCTAssertFalse(plainFont?.fontDescriptor.symbolicTraits.contains(.bold) ?? true)
    }

    /// Таблица — ячейки `NSTextTableBlock` одной таблицы, по ячейке на абзац.
    func testTableBecomesTextTable() {
        let document = AnalysisPDF.document(markdown: sample, header: header)
        var cells: [NSTextTableBlock] = []
        document.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: document.length)) { value, _, _ in
            if let block = (value as? NSParagraphStyle)?.textBlocks.first as? NSTextTableBlock {
                cells.append(block)
            }
        }
        // Атрибут на абзац может прийти несколькими отрезками — считаем ячейки.
        let unique = Set(cells.map { "\($0.startingRow):\($0.startingColumn)" })
        XCTAssertEqual(unique.count, 9)
        XCTAssertEqual(cells.first?.table.numberOfColumns, 3)
        XCTAssertEqual(Set(cells.map { ObjectIdentifier($0.table) }).count, 1)
    }

    /// Цвета — фиксированные: системные динамические в тёмной теме дали бы
    /// белый текст на белой бумаге.
    func testColorsAreNotDynamic() {
        let document = AnalysisPDF.document(markdown: sample, header: header)
        document.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: document.length)) { value, _, _ in
            guard let color = value as? NSColor else { return }
            XCTAssertNotEqual(color.type, .catalog, "\(color)")
        }
    }

    // MARK: - Файл

    /// Настоящий PDF: страницы A4, текст извлекается (кириллица встроена),
    /// внизу номера «N / M».
    func testWritesPagedA4PDF() throws {
        let long = sample + String(repeating: "\n\nЁлка, щука, съешь же ещё этих мягких французских булок. "
                                   + String(repeating: "Текст анализа для переноса страниц. ", count: 30),
                                   count: 8)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("doka-analysis-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertTrue(AnalysisPDF.write(AnalysisPDF.document(markdown: long, header: header),
                                        title: header.title, to: url))
        let pdf = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertGreaterThanOrEqual(pdf.pageCount, 2)
        let bounds = try XCTUnwrap(pdf.page(at: 0)).bounds(for: .mediaBox)
        XCTAssertEqual(bounds.width, AnalysisPDF.paperSize.width, accuracy: 1)
        XCTAssertEqual(bounds.height, AnalysisPDF.paperSize.height, accuracy: 1)

        let firstPage = try XCTUnwrap(pdf.page(at: 0)?.string)
        XCTAssertTrue(firstPage.contains("Встреча с командой"))
        XCTAssertTrue(firstPage.contains("1 / \(pdf.pageCount)"))
        let lastPage = try XCTUnwrap(pdf.page(at: pdf.pageCount - 1)?.string)
        XCTAssertTrue(lastPage.contains("\(pdf.pageCount) / \(pdf.pageCount)"))
        XCTAssertTrue(pdf.string?.contains("Ёлка, щука") ?? false)
        // Системный SF Pro рисует «к» общим глифом с латинской «ĸ» (kra) — из
        // такого PDF копировалось «Теĸст». Шрифт бумаги обязан извлекаться чисто.
        XCTAssertFalse(pdf.string?.contains("ĸ") ?? true)
    }
}
