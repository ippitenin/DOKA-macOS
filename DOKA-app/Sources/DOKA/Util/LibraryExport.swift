import Foundation

/// Экспорт записей библиотеки: имена файлов и объединённые документы.
/// Чистые функции (как `HistoryExport`) — метаданные записи вызывающий
/// форматирует сам, поэтому результат не зависит от локали и часов.
enum LibraryExport {
    /// Одна запись объединённого документа.
    struct Entry: Equatable {
        let title: String
        /// Готовая строка метаданных («дата · сервис · длительность»); пустая — без неё.
        let meta: String
        let text: String
    }

    static let maxBaseNameLength = 80
    /// Лимит имени в APFS — 255 байт UTF-8; запас — под « (N).ext».
    static let maxBaseNameBytes = 200

    /// Заголовок → безопасное имя файла: разделители путей и управляющие
    /// символы заменяются дефисом, длина ограничена и в символах, и в байтах
    /// (80 эмодзи-последовательностей — это под 2 КБ), пустое — «transcript».
    static func sanitizedFileName(_ title: String) -> String {
        let separators = CharacterSet(charactersIn: "/:\\")
        // Края обрезаются ДО замены: иначе хвостовой перевод строки стал бы «-».
        // Заменяются только управляющие символы (Cc), НЕ `.controlCharacters`:
        // тот включает и форматирующие (Cf), среди них ZWJ, — эмодзи-семья
        // «👨‍👩‍👧‍👦» рвалась бы на «👨-👩-👧-👦».
        let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
            .unicodeScalars
            .map { separators.contains($0) || $0.properties.generalCategory == .control ? "-" : String($0) }
            .joined()
        var limited = ""
        var bytes = 0
        for character in cleaned.prefix(maxBaseNameLength) {
            let size = character.utf8.count
            guard bytes + size <= maxBaseNameBytes else { break }
            limited.append(character)
            bytes += size
        }
        let trimmed = limited.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "transcript" : trimmed
    }

    /// Свободное имя «base.ext», «base (2).ext»… Сравнение без регистра: APFS
    /// по умолчанию регистронезависима, «Отчёт.txt» затёр бы «отчёт.txt».
    /// Выбранное имя добавляется в `taken`.
    static func uniqueName(base: String, ext: String, taken: inout Set<String>) -> String {
        var number = 1
        while true {
            let candidate = number == 1 ? "\(base).\(ext)" : "\(base) (\(number)).\(ext)"
            if taken.insert(candidate.lowercased()).inserted { return candidate }
            number += 1
        }
    }

    /// Объединённый Markdown: по разделу на запись. Строки текста становятся
    /// абзацами — одиночный перевод строки Markdown склеил бы реплики в одну.
    static func combinedMarkdown(_ entries: [Entry]) -> String {
        entries.map { entry in
            var parts = ["# \(entry.title)"]
            if !entry.meta.isEmpty { parts.append("*\(entry.meta)*") }
            let paragraphs = entry.text
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if !paragraphs.isEmpty { parts.append(paragraphs.joined(separator: "\n\n")) }
            return parts.joined(separator: "\n\n")
        }
        .joined(separator: "\n\n---\n\n") + "\n"
    }

    /// Объединённый текст: заголовок, метаданные, текст; записи разделены
    /// так же, как в объединённом экспорте истории.
    static func combinedPlainText(_ entries: [Entry]) -> String {
        entries.map { entry in
            var lines = [entry.title]
            if !entry.meta.isEmpty { lines.append(entry.meta) }
            return lines.joined(separator: "\n") + "\n\n" + entry.text
        }
        .joined(separator: "\n\n---\n\n") + "\n"
    }
}
