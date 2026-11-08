import AppKit

/// Полный снапшот и восстановление содержимого буфера обмена.
enum ClipboardManager {
    struct Snapshot {
        let items: [[NSPasteboard.PasteboardType: Data]]
    }

    @MainActor
    static func snapshot() -> Snapshot {
        let pasteboard = NSPasteboard.general
        let items = (pasteboard.pasteboardItems ?? []).map { item in
            var typed: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    typed[type] = data
                }
            }
            return typed
        }
        return Snapshot(items: items)
    }

    @MainActor
    static func restore(_ snapshot: Snapshot) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard !snapshot.items.isEmpty else { return }
        let items = snapshot.items.map { typed -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in typed {
                item.setData(data, forType: type)
            }
            return item
        }
        pasteboard.writeObjects(items)
    }

    @MainActor
    static func setString(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Маркеры nspasteboard.org: менеджеры буфера (Maccy, Paste, Raycast…)
    /// такие записи не сохраняют в историю.
    static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    /// Секрет (токен доступа агентов): только в буфер этого Mac — без
    /// Universal Clipboard на iPhone и другие Mac — и с маркерами «не
    /// сохранять в историю».
    @MainActor
    static func setSecret(_ text: String) {
        let pasteboard = NSPasteboard.general
        _ = pasteboard.prepareForNewContents(with: .currentHostOnly)
        pasteboard.setString(text, forType: .string)
        pasteboard.setData(Data(), forType: concealedType)
        pasteboard.setData(Data(), forType: transientType)
    }

    /// Текст сразу в трёх представлениях: plain — для обычных текстовых полей,
    /// HTML — для приложений с rich-вставкой (Telegram, Notes, Word): таблицы
    /// вставляются таблицами, списки списками; RTF (best-effort из того же
    /// HTML) — для полей на NSTextView, которые предпочитают RTF, а HTML из
    /// буфера игнорируют. Приложение само выбирает флейвор.
    @MainActor
    static func setRichText(plain: String, html: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(plain, forType: .string)
        item.setString(html, forType: .html)
        if let data = html.data(using: .utf8),
           let attributed = NSAttributedString(html: data, documentAttributes: nil),
           let rtf = attributed.rtf(
               from: NSRange(location: 0, length: attributed.length),
               documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
           ) {
            item.setData(rtf, forType: .rtf)
        }
        pasteboard.writeObjects([item])
    }
}
