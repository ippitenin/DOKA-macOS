import Foundation

/// Что именно просим у модели: шаблон из разделов либо свободный запрос
/// пользователя.
enum AnalysisTemplateBody: Equatable {
    case sections(AnalysisTemplate)
    case custom(prompt: String)

    var sectionTitles: [String] {
        switch self {
        case .sections(let template): return template.sections.map(\.title)
        case .custom: return []
        }
    }
}

/// Сборка промптов анализа. Чистые функции: на вход — шаблон, строки
/// расшифровки и язык ответа, на выход — сообщения чата. Тесты проверяют
/// структуру и подстановки, а не переводы (тексты идут через `L()` и зависят
/// от языка бандла).
enum AnalysisPromptBuilder {

    /// Финальный запрос: либо вся расшифровка (`lines`), либо конспекты
    /// частей (`notes`) — ровно одно из двух.
    static func final(template: AnalysisTemplateBody, input: TranscriptLLMInput,
                      lines: ArraySlice<TranscriptLLMInput.Line>?, notes: [NotePart]?,
                      languageName: String) -> [LLMMessage] {
        var user = header(input)
        user += "\n\n" + task(template, hasTimestamps: input.hasTimestamps)
        if let notes {
            user += "\n\n" + L("analysis.prompt.notesHeader") + "\n"
            user += notes.map { part in
                "\n" + L("analysis.prompt.notePart", part.index, part.total,
                         TranscriptFormatter.clock(part.start), TranscriptFormatter.clock(part.end))
                    + "\n" + part.text
            }.joined(separator: "\n")
        } else {
            user += "\n\n" + L("analysis.prompt.transcriptLabel") + "\n"
            user += (lines ?? input.lines[...]).map(\.rendered).joined(separator: "\n")
        }
        return [LLMMessage(role: .system, content: system(languageName: languageName)),
                LLMMessage(role: .user, content: user)]
    }

    /// Запрос на конспект одной части длинной записи (шаг map).
    static func map(template: AnalysisTemplateBody, lines: ArraySlice<TranscriptLLMInput.Line>,
                    part: Int, of total: Int, languageName: String) -> [LLMMessage] {
        let start = lines.first?.start ?? 0
        let end = lines.last?.end ?? 0
        var user = L("analysis.prompt.map", part, total,
                     TranscriptFormatter.clock(start), TranscriptFormatter.clock(end))
        let titles = template.sectionTitles
        if !titles.isEmpty {
            user += "\n" + L("analysis.prompt.mapFocus", titles.joined(separator: ", "))
        }
        user += "\n\n" + L("analysis.prompt.transcriptLabel") + "\n"
        user += lines.map(\.rendered).joined(separator: "\n")
        return [LLMMessage(role: .system, content: system(languageName: languageName)),
                LLMMessage(role: .user, content: user)]
    }

    /// Конспект одной части — вход шага reduce.
    struct NotePart: Equatable {
        let index: Int
        let total: Int
        let start: Double
        let end: Double
        let text: String
    }

    // MARK: - Части промпта

    static func system(languageName: String) -> String {
        L("analysis.prompt.system", languageName)
    }

    private static func header(_ input: TranscriptLLMInput) -> String {
        let duration = input.duration.map(TranscriptFormatter.clock) ?? "—"
        let participants = input.participants.isEmpty
            ? L("analysis.prompt.participantsUnknown")
            : input.participants.joined(separator: ", ")
        return L("analysis.prompt.transcriptHeader", input.title, duration, participants)
    }

    /// Задание: либо перечисление разделов, либо свой запрос пользователя.
    private static func task(_ template: AnalysisTemplateBody, hasTimestamps: Bool) -> String {
        switch template {
        case .custom(let prompt):
            var text = L("analysis.prompt.custom", prompt.trimmingCharacters(in: .whitespacesAndNewlines))
            if !hasTimestamps { text += "\n" + L("analysis.prompt.noTimestamps") }
            return text
        case .sections(let analysisTemplate):
            var blocks: [String] = []
            for section in analysisTemplate.sections {
                var block = "## \(section.title)"
                let instruction = section.instruction.trimmingCharacters(in: .whitespacesAndNewlines)
                if !instruction.isEmpty { block += "\n\(instruction)" }
                block += "\n" + formatRule(section)
                // Тайм-коды просим, только если они во входе есть: иначе
                // модель их выдумает, и линкер поведёт плеер в никуда.
                if section.cite && hasTimestamps { block += "\n" + L("analysis.prompt.cite") }
                blocks.append(block)
            }
            var text = L("analysis.prompt.sectionsHeader") + "\n\n" + blocks.joined(separator: "\n\n")
            if !hasTimestamps { text += "\n\n" + L("analysis.prompt.noTimestamps") }
            return text
        }
    }

    private static func formatRule(_ section: AnalysisSection) -> String {
        switch section.format {
        case .list: return L("analysis.prompt.format.list")
        case .paragraph: return L("analysis.prompt.format.paragraph")
        case .table:
            let columns = section.columns.isEmpty
                ? L("analysis.prompt.format.tableDefaultColumns")
                : section.columns.joined(separator: " · ")
            return L("analysis.prompt.format.table", columns)
        }
    }
}
