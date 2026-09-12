import Foundation

/// Превращает тайм-коды в ответе модели («[12:34]») в ссылки
/// `doka-seek:<секунды>`, по которым запись перематывает плеер.
///
/// Чистая функция над Markdown: в хранимый текст анализа ссылки НЕ попадают —
/// они добавляются только при рендере (`MarkdownView(_:onSeek:)`), иначе
/// «Скопировать» и «Сохранить как…» отдали бы пользователю служебные скобки.
enum TimestampLinker {
    static let scheme = "doka-seek"

    /// Формат тайм-кода — тот же, что у `TranscriptFormatter.clock`:
    /// «[м:сс]», «[мм:сс]» и «[ч:мм:сс]». У диапазона «[1:23–2:45]»
    /// ссылкой становится начало.
    private static let pattern = try? NSRegularExpression(
        pattern: "\\[(\\d{1,2}:)?(\\d{1,2}):(\\d{2})(\\s*[–—-]\\s*(?:\\d{1,2}:)?\\d{1,2}:\\d{2})?\\]")

    /// `duration` — длительность записи: тайм-код заметно дальше конца
    /// записи не линкуется, это галлюцинация модели.
    static func linkify(_ markdown: String, duration: Double?) -> String {
        guard let pattern else { return markdown }
        let text = markdown as NSString
        let matches = pattern.matches(in: markdown, range: NSRange(location: 0, length: text.length))
        guard !matches.isEmpty else { return markdown }

        let limit = duration.map { $0 + 5 }
        var result = ""
        var cursor = 0
        // Чётность обратных кавычек считается ОДНИМ проходом вместе с
        // копированием текста: пересчёт с начала на каждое совпадение давал бы
        // квадратичную работу на длинном отчёте.
        var insideCode = false
        for match in matches {
            let range = match.range
            let gap = text.substring(with: NSRange(location: cursor, length: range.location - cursor))
            let gapParity = gap.reduce(into: false) { flag, character in
                if character == "`" { flag.toggle() }
            }
            // Исключающее ИЛИ: чётное число кавычек в промежутке оставляет
            // состояние, нечётное — переключает.
            let codeHere = insideCode != gapParity
            guard !codeHere, !isAlreadyLink(text, matchEnd: range.location + range.length),
                  let seconds = seconds(of: match, in: text),
                  limit.map({ seconds <= $0 }) ?? true
            else {
                // Совпадение пропущено: текст до него уедет в результат
                // вместе со следующим пропуском или хвостом.
                continue
            }
            result += gap
            insideCode = codeHere
            cursor = range.location + range.length
            // Ссылка охватывает ровно скобки: «[1:23](doka-seek:83)».
            result += "\(text.substring(with: range))(\(scheme):\(Int(seconds)))"
        }
        guard cursor > 0 else { return markdown }
        result += text.substring(from: cursor)
        return result
    }

    /// Секунды из ссылки `doka-seek:<число>`; nil — чужая ссылка.
    static func seconds(from url: URL) -> Double? {
        guard url.scheme == scheme else { return nil }
        let rest = url.absoluteString.dropFirst(scheme.count + 1)
        return Double(rest)
    }

    private static func seconds(of match: NSTextCheckingResult, in text: NSString) -> Double? {
        func number(_ index: Int) -> Int? {
            let range = match.range(at: index)
            guard range.location != NSNotFound else { return nil }
            return Int(text.substring(with: range).replacingOccurrences(of: ":", with: ""))
        }
        guard let minutes = number(2), let secondsPart = number(3), secondsPart < 60 else { return nil }
        let hours = number(1) ?? 0
        return Double(hours * 3600 + minutes * 60 + secondsPart)
    }

    /// Скобки уже оформлены ссылкой: сразу за «]» идёт «(».
    private static func isAlreadyLink(_ text: NSString, matchEnd: Int) -> Bool {
        matchEnd < text.length && text.character(at: matchEnd) == 40   // «(»
    }
}
