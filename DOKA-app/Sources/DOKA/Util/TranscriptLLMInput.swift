import CryptoKit
import Foundation

/// Расшифровка, подготовленная для языковой модели: строки «[м:сс] Имя: текст»
/// и отпечаток входа. Чистая структура — тестируется без модели и без диска.
///
/// Формат строки тот же, что у экспорта «тайм-коды + спикеры»
/// (`TranscriptFormatter.llmTranscript`): модель видит ровно то, что видит
/// пользователь, а `TimestampLinker` разбирает тайм-коды её ответа тем же
/// правилом.
struct TranscriptLLMInput: Equatable {
    struct Line: Equatable {
        let start: Double
        let end: Double
        /// Отображаемое имя спикера (после правок); nil — диаризации не было.
        let speaker: String?
        let text: String
        /// Готовая строка входа.
        let rendered: String
    }

    let title: String
    let duration: Double?
    let lines: [Line]
    /// Имена говорящих в порядке появления — для шапки промпта.
    let participants: [String]
    /// Есть ли у строк тайм-коды: без сегментов их нет, и модели нужно
    /// прямо сказать, чтобы она их не выдумывала.
    let hasTimestamps: Bool

    /// Отпечаток входа для пометки «расшифровку изменили после этого анализа».
    /// Считается от строк БЕЗ словаря замен: словарь — пользовательская линза
    /// поверх вывода, его переключение не делает анализ устаревшим.
    let fingerprint: String

    var isEmpty: Bool { lines.isEmpty }

    var text: String { lines.map(\.rendered).joined(separator: "\n") }

    /// Детализация, на которой строится вход анализа. ФИКСИРОВАННАЯ и не
    /// зависит от выбора пользователя в шапке «Транскрибации»: иначе смена
    /// детализации меняла бы отпечаток и все анализы разом становились бы
    /// «устаревшими». `.server` не годится — Parakeet отдаёт один сегмент на
    /// всю запись, и нарезать такую строку на части было бы нечем.
    static let detail: TimestampDetail = .medium

    /// Максимальная длительность склеенной реплики. Подряд идущие сегменты
    /// одного спикера объединяются, пока не упрутся в этот предел: одна
    /// реплика в одной строке читается моделью лучше, чем та же реплика,
    /// разорванная на предложения, но бесконечно длинная строка ломает
    /// нарезку на части (`LLMChunker` строки не режет).
    static let defaultMaxTurn: Double = 45

    /// `result` — то, что уйдёт в модель (со словарём замен, если он включён);
    /// `fingerprintSource` — тот же результат БЕЗ словаря, от него считается
    /// отпечаток. nil — отпечаток от самого `result` (в тестах и там, где
    /// словарь выключен).
    ///
    /// `result` должен быть построен с ФИКСИРОВАННОЙ детализацией (см.
    /// `AnalysisController.inputDetail`), а не с пользовательской: иначе
    /// смена детализации меняла бы отпечаток и все анализы разом становились
    /// «устаревшими».
    static func build(title: String, result: TranscriptResult,
                      fingerprintSource: TranscriptResult? = nil,
                      maxTurnSeconds: Double = defaultMaxTurn) -> TranscriptLLMInput {
        let lines = makeLines(result, maxTurnSeconds: maxTurnSeconds)
        var participants: [String] = []
        for line in lines {
            guard let speaker = line.speaker, !participants.contains(speaker) else { continue }
            participants.append(speaker)
        }
        let source = fingerprintSource ?? result
        let printed = fingerprintSource == nil
            ? lines
            : makeLines(source, maxTurnSeconds: maxTurnSeconds)
        return TranscriptLLMInput(
            title: title,
            duration: result.duration,
            lines: lines,
            participants: participants,
            hasTimestamps: !result.segments.isEmpty,
            fingerprint: fingerprint(of: printed.map(\.rendered).joined(separator: "\n")))
    }

    static func fingerprint(of text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(16).description
    }

    // MARK: - Строки

    private static func makeLines(_ result: TranscriptResult, maxTurnSeconds: Double) -> [Line] {
        guard !result.segments.isEmpty else { return sentenceLines(result) }

        var lines: [Line] = []
        var buffer: [String] = []
        var speaker: String?
        var start = 0.0
        var end = 0.0

        func flush() {
            guard !buffer.isEmpty else { return }
            let text = sanitize(buffer.joined(separator: " "))
            guard !text.isEmpty else { buffer.removeAll(); return }
            lines.append(Line(start: start, end: end, speaker: speaker, text: text,
                              rendered: render(start: start, speaker: speaker, text: text)))
            buffer.removeAll()
        }

        for segment in result.segments {
            let label = segment.speaker.flatMap { $0.isEmpty ? nil : result.speakerLabel($0) }
            // Новая реплика: сменился говорящий, либо текущая уже слишком длинная.
            let tooLong = !buffer.isEmpty && segment.end - start > maxTurnSeconds
            if label != speaker || tooLong {
                flush()
                speaker = label
                start = segment.start
            }
            if buffer.isEmpty { start = segment.start }
            buffer.append(segment.text.trimmingCharacters(in: .whitespacesAndNewlines))
            end = segment.end
        }
        flush()
        return lines
    }

    /// Сегментов нет (у результата только полный текст) — делим по
    /// предложениям тем же правилом, что и сплиттер: строки всё равно нужны,
    /// иначе часовую расшифровку нечем нарезать на части.
    private static func sentenceLines(_ result: TranscriptResult) -> [Line] {
        let text = sanitize(TranscriptFormatter.plainText(result))
        guard !text.isEmpty else { return [] }
        var lines: [Line] = []
        var current = ""
        for sentence in text.split(whereSeparator: \.isNewline).flatMap(splitSentences) {
            // Копим короткие предложения в одну строку: строка из трёх слов
            // раздувает число частей на ровном месте.
            if current.count + sentence.count > 400, !current.isEmpty {
                lines.append(Line(start: 0, end: 0, speaker: nil, text: current, rendered: current))
                current = ""
            }
            current += current.isEmpty ? sentence : " " + sentence
        }
        if !current.isEmpty {
            lines.append(Line(start: 0, end: 0, speaker: nil, text: current, rendered: current))
        }
        return lines
    }

    private static func splitSentences(_ text: Substring) -> [String] {
        var result: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if character == "." || character == "!" || character == "?" {
                let trimmed = current.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { result.append(trimmed) }
                current = ""
            }
        }
        let tail = current.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { result.append(tail) }
        return result
    }

    private static func render(start: Double, speaker: String?, text: String) -> String {
        let clock = "[\(TranscriptFormatter.clock(start))]"
        guard let speaker else { return "\(clock) \(text)" }
        return "\(clock) \(speaker): \(text)"
    }

    /// Вырезает служебные скобки chatml: мы токенизируем с `parse_special`,
    /// и расшифровка, где кто-то произнёс «<|im_start|>», иначе подменила бы
    /// роль в промпте.
    static func sanitize(_ text: String) -> String {
        guard text.contains("<|") || text.contains("|>") else { return text }
        return text.replacingOccurrences(of: "<|", with: "‹")
                   .replacingOccurrences(of: "|>", with: "›")
    }
}
