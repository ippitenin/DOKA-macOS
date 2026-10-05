import Foundation

/// Импорт и экспорт шаблонов анализа файлом JSON. Чистая логика без UI:
/// разбор файла, перевод формата Memento, уникальные имена.
///
/// Экспорт — собственный формат DOKA: тот же `AnalysisTemplate`, но без
/// идентификаторов (при импорте они всё равно назначаются заново). Под Memento
/// экспорт не подгоняется: своих шаблонов из файла Memento не читает, у него
/// они живут в базе.
///
/// Импорт понимает и свой формат, и шаблоны Memento
/// (`name`, `description`, `sections[{title, instruction, format, item_format?}]`):
/// - `format: "string"` — однострочное поле вроде «Дата встречи» — становится
///   связным текстом;
/// - `item_format` с шапкой таблицы Markdown (`| **Owner** | **Task** |`) —
///   таблицей с колонками из шапки;
/// - `pipeline` и прочие ключи игнорируются: такой шаблон — один раздел
///   с длинной инструкцией, и наш промпт оборачивает его как любой другой.
enum AnalysisTemplateTransfer {
    enum ImportError: Error, Equatable {
        /// Файл не прочитался (это знает только тот, кто его читал).
        case unreadable
        /// JSON не похож ни на шаблон, ни на массив шаблонов.
        case notTemplate
        /// Шаблон разобран, но не проходит валидацию редактора; текст — уже
        /// локализованная причина из `AnalysisTemplate.validationError`.
        case invalid(String)

        /// Причина для алерта «Не удалось импортировать».
        var message: String {
            switch self {
            case .unreadable: return L("analysis.templates.import.unreadable")
            case .notTemplate: return L("analysis.templates.import.notTemplate")
            case .invalid(let message): return message
            }
        }
    }

    /// Файл, выбранный для импорта: имя с расширением и содержимое (`nil` —
    /// не прочитался).
    struct ImportFile {
        let fileName: String
        let data: Data?
    }

    /// Итог импорта пачки файлов: шаблоны с уже свободными именами — в порядке
    /// файлов, и отказы по файлам.
    struct ImportOutcome {
        struct Failure: Equatable {
            let fileName: String
            let reason: ImportError
        }

        var templates: [AnalysisTemplate] = []
        var failures: [Failure] = []
    }

    /// Импорт нескольких файлов разом: каждый разбирается `parse` (имя файла
    /// без расширения — запасное имя шаблона), совпавшие имена — с занятыми
    /// `existingNames` и друг с другом — получают « (2)». Битый файл не мешает
    /// остальным: он попадает в `failures`.
    static func importFiles(_ files: [ImportFile], existingNames: [String]) -> ImportOutcome {
        var names = AnalysisTemplateNames(existingNames)
        var outcome = ImportOutcome()
        for file in files {
            do {
                guard let data = file.data else { throw ImportError.unreadable }
                let fallback = (file.fileName as NSString).deletingPathExtension
                for var template in try parse(data, fallbackName: fallback) {
                    template.name = names.claim(template.name)
                    outcome.templates.append(template)
                }
            } catch {
                outcome.failures.append(.init(fileName: file.fileName,
                                              reason: error as? ImportError ?? .notTemplate))
            }
        }
        return outcome
    }

    /// Шаблоны из файла: один объект или массив. Идентификаторы всегда новые —
    /// повторный импорт своего же экспорта не должен совпасть по id с
    /// исходником, а экспорт встроенного не должен притвориться встроенным.
    /// `fallbackName` — имя файла: подставляется, если у шаблона нет названия.
    static func parse(_ data: Data, fallbackName: String) throws -> [AnalysisTemplate] {
        let decoder = JSONDecoder()
        let files: [FileTemplate]
        if let many = try? decoder.decode([FileTemplate].self, from: data) {
            files = many
        } else if let one = try? decoder.decode(FileTemplate.self, from: data) {
            files = [one]
        } else {
            throw ImportError.notTemplate
        }
        guard !files.isEmpty else { throw ImportError.notTemplate }
        return try files.map { try template(from: $0, fallbackName: fallbackName) }
    }

    /// JSON одного шаблона для «Экспортировать…».
    static func exportData(_ template: AnalysisTemplate) throws -> Data {
        let file = ExportTemplate(
            name: template.name,
            description: template.description,
            sections: template.sections.map {
                ExportSection(title: $0.title, instruction: $0.instruction, format: $0.format,
                              columns: $0.format == .table ? $0.columns : nil,
                              cite: $0.cite)
            })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        return try encoder.encode(file)
    }

    /// Колонки из шапки таблицы Markdown — первой строки `item_format`.
    /// Не таблица (строка не начинается с «|», меньше двух колонок, первая
    /// строка — разделитель `---`) — пустой массив: раздел остаётся списком.
    static func tableColumns(fromItemFormat itemFormat: String) -> [String] {
        guard let header = itemFormat
            .components(separatedBy: .newlines)
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { !$0.isEmpty }),
            header.hasPrefix("|") else { return [] }
        let cells = header
            .split(separator: "|", omittingEmptySubsequences: false)
            .map { cell in
                cell.replacingOccurrences(of: "**", with: "")
                    .replacingOccurrences(of: "__", with: "")
                    .replacingOccurrences(of: "`", with: "")
                    .trimmingCharacters(in: .whitespaces)
            }
            .filter { !$0.isEmpty }
        let isSeparator = cells.allSatisfy { cell in
            cell.allSatisfy { $0 == "-" || $0 == ":" }
        }
        guard cells.count >= 2, !isSeparator else { return [] }
        return cells
    }

    // MARK: - Перевод в AnalysisTemplate

    private static func template(from file: FileTemplate,
                                 fallbackName: String) throws -> AnalysisTemplate {
        var name = file.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if name.isEmpty {
            name = fallbackName.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let template = AnalysisTemplate(
            name: String(name.prefix(AnalysisTemplate.maxNameLength)),
            description: file.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            sections: (file.sections ?? []).map(section(from:)))
        if let error = template.validationError {
            throw ImportError.invalid(error)
        }
        return template
    }

    private static func section(from file: FileSection) -> AnalysisSection {
        var format: AnalysisSectionFormat
        switch file.format?.lowercased() {
        case "table": format = .table
        case "paragraph", "string": format = .paragraph
        default: format = .list
        }
        var columns = file.columns ?? []
        let headerColumns = file.itemFormat.map(tableColumns(fromItemFormat:)) ?? []
        if !headerColumns.isEmpty {
            format = .table
            columns = headerColumns
        }
        return AnalysisSection(title: file.title.trimmingCharacters(in: .whitespacesAndNewlines),
                               instruction: file.instruction ?? "",
                               format: format,
                               columns: format == .table ? columns : [],
                               cite: file.cite ?? false)
    }

    // MARK: - Формат файла

    /// Терпимый разбор: всё, кроме названия раздела, необязательно — так
    /// читаются и наши файлы, и шаблоны Memento.
    private struct FileTemplate: Decodable {
        let name: String?
        let description: String?
        let sections: [FileSection]?
    }

    private struct FileSection: Decodable {
        let title: String
        let instruction: String?
        /// Строкой, а не `AnalysisSectionFormat`: у Memento есть `string`,
        /// которого у нас нет.
        let format: String?
        let columns: [String]?
        let cite: Bool?
        let itemFormat: String?

        private enum CodingKeys: String, CodingKey {
            case title, instruction, format, columns, cite
            case itemFormat = "item_format"
        }
    }

    private struct ExportTemplate: Encodable {
        let name: String
        let description: String
        let sections: [ExportSection]
    }

    private struct ExportSection: Encodable {
        let title: String
        let instruction: String
        let format: AnalysisSectionFormat
        let columns: [String]?
        let cite: Bool
    }
}

/// Занятые имена шаблонов: совпадение — без учёта регистра и пробелов по
/// краям, свободное имя — с пометкой « (2)», « (3)»…, не длиннее лимита.
struct AnalysisTemplateNames {
    private var taken: Set<String>

    init(_ names: [String]) {
        taken = Set(names.map(Self.key))
    }

    /// Свободное имя на основе `name`; оно сразу становится занятым.
    mutating func claim(_ name: String) -> String {
        let base = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var candidate = base
        var number = 2
        while taken.contains(Self.key(candidate)) {
            let suffix = " (\(number))"
            candidate = String(base.prefix(AnalysisTemplate.maxNameLength - suffix.count)) + suffix
            number += 1
        }
        taken.insert(Self.key(candidate))
        return candidate
    }

    private static func key(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
