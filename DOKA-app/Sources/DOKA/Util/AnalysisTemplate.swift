import Foundation

/// Формат раздела отчёта: подсказка модели, как оформить ответ.
enum AnalysisSectionFormat: String, Codable, CaseIterable, Identifiable {
    case list, paragraph, table

    var id: String { rawValue }
    var title: String { L("analysis.format.\(rawValue)") }

    /// Неизвестное значение (шаблон из будущей версии) — список, а не ошибка
    /// декода всего шаблона.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AnalysisSectionFormat(rawValue: raw) ?? .list
    }
}

/// Раздел отчёта: заголовок, что в него писать и как оформить.
struct AnalysisSection: Codable, Equatable, Identifiable {
    var id: UUID
    var title: String
    var instruction: String
    var format: AnalysisSectionFormat
    /// Колонки таблицы; осмысленно только при `format == .table`.
    var columns: [String]
    /// Требовать тайм-код у каждого пункта.
    var cite: Bool

    init(id: UUID = UUID(), title: String, instruction: String,
         format: AnalysisSectionFormat = .list, columns: [String] = [], cite: Bool = false) {
        self.id = id
        self.title = title
        self.instruction = instruction
        self.format = format
        self.columns = columns
        self.cite = cite
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, instruction, format, columns, cite
    }

    /// Ручной декодер: синтезированный требует все ключи, и шаблон, записанный
    /// прошлой версией (или принесённый из другого приложения), не прочитался бы.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decode(String.self, forKey: .title)
        instruction = try c.decodeIfPresent(String.self, forKey: .instruction) ?? ""
        format = try c.decodeIfPresent(AnalysisSectionFormat.self, forKey: .format) ?? .list
        columns = try c.decodeIfPresent([String].self, forKey: .columns) ?? []
        cite = try c.decodeIfPresent(Bool.self, forKey: .cite) ?? false
    }
}

/// Шаблон отчёта: набор разделов. Встроенные НЕ хранятся на диске — они
/// строятся на лету на языке интерфейса, поэтому смена языка меняет и
/// заголовки разделов, и язык инструкций модели.
struct AnalysisTemplate: Codable, Equatable, Identifiable {
    /// `builtin.<raw>` у встроенных, UUID-строка у своих.
    var id: String
    var name: String
    var description: String
    var sections: [AnalysisSection]

    var isBuiltin: Bool { id.hasPrefix(Self.builtinPrefix) }

    static let builtinPrefix = "builtin."
    /// Границы валидации редактора: длинное имя ломает попап, а больше
    /// двенадцати разделов не влезает ни в одно окно контекста.
    static let maxNameLength = 80
    static let maxSections = 12
    static let maxInstructionLength = 2000

    init(id: String = UUID().uuidString, name: String, description: String = "",
         sections: [AnalysisSection]) {
        self.id = id
        self.name = name
        self.description = description
        self.sections = sections
    }

    private enum CodingKeys: String, CodingKey { case id, name, description, sections }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try c.decode(String.self, forKey: .name)
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        sections = try c.decodeIfPresent([AnalysisSection].self, forKey: .sections) ?? []
    }

    /// Причина, по которой шаблон нельзя сохранить; nil — всё в порядке.
    var validationError: String? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || name.count > Self.maxNameLength {
            return L("analysis.templates.validation.name", Self.maxNameLength)
        }
        if sections.isEmpty || sections.count > Self.maxSections {
            return L("analysis.templates.validation.sections", Self.maxSections)
        }
        if sections.contains(where: { $0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return L("analysis.templates.validation.sectionTitle")
        }
        if sections.contains(where: { $0.instruction.count > Self.maxInstructionLength }) {
            return L("analysis.templates.validation.instruction", Self.maxInstructionLength)
        }
        return nil
    }

    /// Копия встроенного шаблона как своего: новый id, имя с пометкой.
    func duplicated() -> AnalysisTemplate {
        AnalysisTemplate(id: UUID().uuidString,
                         name: L("analysis.templates.copyName", name),
                         description: description,
                         sections: sections.map {
                             AnalysisSection(id: UUID(), title: $0.title, instruction: $0.instruction,
                                             format: $0.format, columns: $0.columns, cite: $0.cite)
                         })
    }
}

/// Встроенные шаблоны. Структура (какой раздел каким форматом, где нужны
/// тайм-коды) задана здесь, тексты — в `Localizable.strings` по ключам
/// `analysis.template.<raw>.…`; префикс `analysis.template.` объявлен
/// динамическим в `scripts/check-localization.sh`.
enum BuiltinAnalysisTemplate: String, CaseIterable, Identifiable {
    case summary, meetingMinutes, actionItems, lectureNotes, interview, chapters

    var id: String { rawValue }
    var templateID: String { AnalysisTemplate.builtinPrefix + rawValue }

    /// Скелет разделов: ключ строки, формат, нужны ли колонки и тайм-коды.
    private struct Slot {
        let format: AnalysisSectionFormat
        let cite: Bool
        var hasColumns: Bool { format == .table }

        init(_ format: AnalysisSectionFormat, cite: Bool = false) {
            self.format = format
            self.cite = cite
        }
    }

    private var slots: [Slot] {
        switch self {
        case .summary:
            return [Slot(.paragraph), Slot(.list, cite: true), Slot(.paragraph)]
        case .meetingMinutes:
            return [Slot(.list), Slot(.list, cite: true), Slot(.list, cite: true),
                    Slot(.table), Slot(.list)]
        case .actionItems:
            return [Slot(.table), Slot(.list, cite: true)]
        case .lectureNotes:
            return [Slot(.paragraph), Slot(.list, cite: true), Slot(.table),
                    Slot(.list, cite: true), Slot(.list), Slot(.list)]
        case .interview:
            return [Slot(.paragraph), Slot(.list, cite: true), Slot(.list, cite: true),
                    Slot(.list), Slot(.list)]
        case .chapters:
            return [Slot(.list, cite: true)]
        }
    }

    var template: AnalysisTemplate {
        let sections = slots.enumerated().map { index, slot in
            AnalysisSection(
                // id детерминированный: у встроенных шаблонов он не должен
                // меняться от перерисовки списка (ForEach по Identifiable).
                id: Self.sectionID(template: rawValue, index: index),
                title: L("analysis.template.\(rawValue).\(index).title"),
                instruction: L("analysis.template.\(rawValue).\(index).instruction"),
                format: slot.format,
                columns: slot.hasColumns
                    ? L("analysis.template.\(rawValue).\(index).columns")
                        .components(separatedBy: "|")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                    : [],
                cite: slot.cite)
        }
        return AnalysisTemplate(id: templateID,
                                name: L("analysis.template.\(rawValue).name"),
                                description: L("analysis.template.\(rawValue).description"),
                                sections: sections)
    }

    static var all: [AnalysisTemplate] { allCases.map(\.template) }

    /// Стабильный UUID из имени шаблона и номера раздела (UUIDv5 не нужен —
    /// достаточно детерминированной набивки байтов).
    private static func sectionID(template: String, index: Int) -> UUID {
        var bytes = [UInt8](repeating: 0, count: 16)
        let seed = Array("\(template)#\(index)".utf8)
        for (position, byte) in seed.enumerated() {
            bytes[position % 16] = bytes[position % 16] &+ byte &+ UInt8(position & 0x7F)
        }
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5],
                           bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11],
                           bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
