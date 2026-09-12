import SwiftUI

/// Нативный рендер лёгкого Markdown (LLM-анализ) — заголовки, абзацы, списки и
/// таблицы без символов разметки. Блочный разбор — чистый ``LightMarkdown``;
/// inline (**жирный**, *курсив*, `код`, ссылки) — через `AttributedString`.
/// Таблицы выделены в ``MarkdownTableView``, сворачивание — общий
/// ``CollapsibleReveal`` (`UI/Components.swift`).
struct MarkdownView: View {
    private let blocks: [LightMarkdown.Block]

    /// `duration` — длительность записи: с ней тайм-коды ответа («[12:34]»)
    /// становятся ссылками `doka-seek:<сек>`, которые ловит `OpenURLAction`
    /// записи и перематывает плеер. В ХРАНИМЫЙ markdown ссылки не попадают:
    /// они добавляются только здесь, при рендере, иначе «Скопировать» и
    /// «Сохранить как…» отдали бы пользователю служебные скобки.
    /// nil — ссылки не нужны (звука у записи нет).
    init(_ markdown: String, seekDuration duration: Double? = nil) {
        let source = duration == nil ? markdown : TimestampLinker.linkify(markdown, duration: duration)
        self.blocks = LightMarkdown.parse(source)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: LightMarkdown.Block) -> some View {
        switch block {
        case let .heading(level, text):
            Text(LightMarkdown.inlineAttributed(text))
                .font(headingFont(level))
                .padding(.top, level <= 2 ? 4 : 2)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case let .paragraph(text):
            Text(LightMarkdown.inlineAttributed(text))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case let .bullet(text):
            listRow(marker: "•", text: text)
        case let .ordered(number, text):
            listRow(marker: "\(number).", text: text)
        case let .table(header, rows):
            MarkdownTableView(header: header, rows: rows)
        case .rule:
            // Не линия (разделы и так отчёркнуты заголовками) — просто больше
            // воздуха между смысловыми блоками.
            Color.clear.frame(height: 12)
        }
    }

    private func listRow(marker: String, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(marker)
                .foregroundStyle(.secondary)
                .frame(minWidth: 16, alignment: .trailing)
            Text(LightMarkdown.inlineAttributed(text))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .title3.weight(.bold)
        case 2: return .headline
        default: return .subheadline.weight(.semibold)
        }
    }
}

/// Markdown-таблица: колонки фиксированной ширины (текст ПЕРЕНОСИТСЯ на следующую
/// строку, а не обрезается), тонкие линии между строками и колонками, серый тинт
/// подложки и скруглённые углы; если таблица шире карточки — горизонтальный
/// скролл внутри неё. Как таблицы в Telegram. `Grid` для этого не годится: в
/// горизонтальном ScrollView он не переносит текст и считает высоту строк по
/// одной строке (строки налезали друг на друга) — поэтому ручная вёрстка
/// VStack/HStack. Тот же недомер высоты ловит и `Text` без явного
/// `.fixedSize(horizontal: false, vertical: true)` на КАЖДОЙ ячейке — см. row().
struct MarkdownTableView: View {
    let header: [String]
    let rows: [[String]]

    /// Ширина видимой области (карточки). Таблица уже неё — колонки
    /// растягиваются пропорционально до полной ширины; шире — скроллится.
    @State private var viewportWidth: CGFloat = 0

    /// Горизонтальный паддинг ячейки; участвует в раскладке линий колонок.
    private let cellPad: CGFloat = 8

    var body: some View {
        let columnCount = max(header.count, rows.map(\.count).max() ?? 0)
        let widths = fittedWidths(columnCount: columnCount)
        let shape = RoundedRectangle(cornerRadius: DS.Radius.badge, style: .continuous)
        ScrollView(.horizontal, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 0) {
                row(header, widths: widths, isHeader: true)
                    .background(Color(nsColor: .quaternarySystemFill))
                Divider().opacity(0.5)
                ForEach(Array(rows.enumerated()), id: \.offset) { index, cells in
                    if index > 0 { Divider().opacity(0.18) }
                    row(cells, widths: widths, isHeader: false)
                }
            }
            // Линии колонок — одним оверлеем на всю высоту таблицы: Divider
            // внутри строк тянулся только на высоту своей строки и до нижнего
            // края таблицы не доходил.
            .overlay(alignment: .topLeading) { columnSeparators(widths) }
        }
        // Высота = высота таблицы (иначе ScrollView раздувается по вертикали),
        // ширина остаётся гибкой и скроллится.
        .fixedSize(horizontal: false, vertical: true)
        // Тинт и скругление — на viewport (а не на контенте), чтобы углы и
        // подложка не уезжали при горизонтальном скролле.
        .background(Color(nsColor: .quinarySystemFill))
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.primary.opacity(0.08)))
        // Замер ширины карточки — фоном, чтобы не влиять на интринсик-высоту
        // (паттерн heightReader из CollapsibleReveal).
        .background(WidthReader(width: $viewportWidth))
    }

    /// Строка: ячейки фиксированной ширины, текст переносится.
    private func row(_ cells: [String], widths: [CGFloat], isHeader: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(widths.enumerated()), id: \.offset) { i, w in
                Text(LightMarkdown.inlineAttributed(i < cells.count ? cells[i] : ""))
                    .font(isHeader ? .caption.weight(.semibold) : .callout)
                    .foregroundStyle(isHeader ? Color.secondary : Color.primary)
                    // Без fixedSize текст внутри горизонтального ScrollView
                    // недомеряет высоту переноса (одна строка) — соседние строки
                    // таблицы рисуются друг поверх друга.
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: w, alignment: .topLeading)
                    .padding(.horizontal, cellPad)
                    .padding(.vertical, 6)
                    .textSelection(.enabled)
            }
        }
    }

    /// Вертикальные линии между колонками на всю высоту таблицы. Позиции —
    /// по известным ширинам ячеек, «пустышка + линия 1 pt» в HStack; у второй
    /// и дальше пустышек ширина на 1 pt меньше — компенсация толщины линии.
    private func columnSeparators(_ widths: [CGFloat]) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(widths.dropLast().enumerated()), id: \.offset) { i, w in
                Color.clear.frame(width: w + cellPad * 2 - (i == 0 ? 0 : 1))
                Rectangle()
                    .fill(Color.primary.opacity(0.1))
                    .frame(width: 1)
            }
        }
    }

    /// Ширины колонок: оценка по контенту (``columnWidth(_:)``), а если сумма
    /// уже карточки — пропорциональное растягивание до её полной ширины, чтобы
    /// таблица не обрывалась посреди контейнера.
    private func fittedWidths(columnCount: Int) -> [CGFloat] {
        let base = (0..<columnCount).map { columnWidth($0) }
        let text = base.reduce(0, +)
        let natural = text + CGFloat(columnCount) * cellPad * 2
        guard viewportWidth > natural, text > 0 else { return base }
        let scale = (viewportWidth - CGFloat(columnCount) * cellPad * 2) / text
        return base.map { $0 * scale }
    }

    /// Ширина колонки по длине содержимого: короткие (№) — узкие, длинные
    /// капаются потолком, чтобы текст переносился, а не растягивал таблицу без
    /// конца. Оценка грубая (символы × средняя ширина) — точность не важна:
    /// текст в любом случае виден целиком, просто в несколько строк.
    private func columnWidth(_ index: Int) -> CGFloat {
        let cells = ([header] + rows).compactMap { index < $0.count ? $0[index] : nil }
        let longest = cells
            .map { $0.replacingOccurrences(of: "*", with: "").replacingOccurrences(of: "`", with: "") }
            .map(\.count)
            .max() ?? 0
        return min(300, max(48, CGFloat(longest) * 8.5))
    }
}

/// Замер фактической ширины вью фоном: `GeometryReader` в `.background` не
/// влияет на layout самого вью (в отличие от обёртки).
private struct WidthReader: View {
    @Binding var width: CGFloat

    var body: some View {
        GeometryReader { geo in
            Color.clear
                .onAppear { width = geo.size.width }
                .onChange(of: geo.size.width) { _, new in width = new }
        }
    }
}
