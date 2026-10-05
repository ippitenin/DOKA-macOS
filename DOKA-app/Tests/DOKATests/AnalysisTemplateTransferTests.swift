import XCTest
@testable import DOKA

/// Импорт и экспорт шаблонов анализа. Фикстуры Memento — синтетические, в их
/// формате (`name`, `description`, `sections[{title, instruction, format,
/// item_format?}]`, у части `pipeline`): настоящие файлы Memento в публичный
/// репозиторий не кладём.
///
/// Ловушка локализации: причины отказа идут через `L()` — проверяем случай
/// ошибки, а не её текст.
final class AnalysisTemplateTransferTests: XCTestCase {

    private func parse(_ json: String, fallbackName: String = "file") throws -> [AnalysisTemplate] {
        try AnalysisTemplateTransfer.parse(Data(json.utf8), fallbackName: fallbackName)
    }

    private func assertImportError(_ json: String, _ expected: (AnalysisTemplateTransfer.ImportError) -> Bool,
                                   file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try parse(json), file: file, line: line) { error in
            guard let importError = error as? AnalysisTemplateTransfer.ImportError else {
                return XCTFail("чужая ошибка: \(error)", file: file, line: line)
            }
            XCTAssertTrue(expected(importError), "\(importError)", file: file, line: line)
        }
    }

    // MARK: - Memento

    /// Шаблон «одним промптом» (`pipeline: custom_prompt_v1`): один раздел
    /// с длинной инструкцией, `pipeline` игнорируется.
    func testMementoSinglePromptTemplate() throws {
        let instruction = "Составь саммари встречи.\n\nНе добавляй сведения от себя."
        let json = """
        {"name": "Weekly Sync", "description": "Короткое саммари", "pipeline": "custom_prompt_v1",
         "sections": [{"title": "Summary", "instruction": \(String(reflecting: instruction)), "format": "list"}]}
        """
        let templates = try parse(json)
        XCTAssertEqual(templates.count, 1)
        let template = templates[0]
        XCTAssertEqual(template.name, "Weekly Sync")
        XCTAssertEqual(template.description, "Короткое саммари")
        XCTAssertFalse(template.isBuiltin)
        XCTAssertEqual(template.sections.count, 1)
        XCTAssertEqual(template.sections[0].title, "Summary")
        XCTAssertEqual(template.sections[0].instruction, instruction)
        XCTAssertEqual(template.sections[0].format, .list)
        XCTAssertEqual(template.sections[0].columns, [])
        XCTAssertFalse(template.sections[0].cite)
    }

    /// Шаблон разделами: `string` — связный текст, `item_format` с шапкой
    /// таблицы — таблица с колонками без `**`, остальное — как есть.
    func testMementoSectionsMapping() throws {
        let json = """
        {"name": "Status", "description": "",
         "sections": [
          {"title": "Meeting Date", "instruction": "Date and facilitator", "format": "string"},
          {"title": "Highlights", "instruction": "Key updates", "format": "list"},
          {"title": "Milestones", "instruction": "Progress", "format": "list",
           "item_format": "| **Milestone** | **Status** | **ETA** |\\n| --- | --- | --- |"},
          {"title": "Notes", "instruction": "Context", "format": "paragraph"}
         ]}
        """
        let sections = try XCTUnwrap(parse(json).first).sections
        XCTAssertEqual(sections.map(\.format), [.paragraph, .list, .table, .paragraph])
        XCTAssertEqual(sections[2].columns, ["Milestone", "Status", "ETA"])
        XCTAssertEqual(sections[0].columns, [])
        XCTAssertEqual(sections[1].columns, [])
    }

    /// `item_format` без шапки таблицы — раздел остаётся тем, чем был.
    func testItemFormatWithoutTableHeaderKeepsFormat() throws {
        let json = """
        {"name": "T", "sections": [
          {"title": "People", "instruction": "", "format": "list", "item_format": "- **Name**: role"},
          {"title": "Only separator", "instruction": "", "format": "list", "item_format": "| --- | --- |"},
          {"title": "One column", "instruction": "", "format": "list", "item_format": "| **Item** |"}
        ]}
        """
        let sections = try XCTUnwrap(parse(json).first).sections
        XCTAssertEqual(sections.map(\.format), [.list, .list, .list])
        XCTAssertTrue(sections.allSatisfy { $0.columns.isEmpty })
    }

    func testTableColumnsFromHeader() {
        XCTAssertEqual(AnalysisTemplateTransfer.tableColumns(
            fromItemFormat: "| **Owner** | __Task__ | `Due` |\n| --- | --- | --- |"),
            ["Owner", "Task", "Due"])
        XCTAssertEqual(AnalysisTemplateTransfer.tableColumns(fromItemFormat: "\n  | A | B |  "), ["A", "B"])
        XCTAssertEqual(AnalysisTemplateTransfer.tableColumns(fromItemFormat: "| :--- | ---: |"), [])
        XCTAssertEqual(AnalysisTemplateTransfer.tableColumns(fromItemFormat: "Owner | Task"), [])
        XCTAssertEqual(AnalysisTemplateTransfer.tableColumns(fromItemFormat: ""), [])
    }

    /// Незнакомый формат (шаблон из будущей версии) — список, а не отказ.
    func testUnknownFormatFallsBackToList() throws {
        let json = #"{"name": "T", "sections": [{"title": "S", "instruction": "", "format": "bullets"}]}"#
        XCTAssertEqual(try XCTUnwrap(parse(json).first).sections.first?.format, .list)
    }

    // MARK: - Свой формат

    /// Экспорт → импорт возвращает тот же шаблон; идентификаторов в файле нет,
    /// при импорте они новые.
    func testExportRoundTrip() throws {
        let original = AnalysisTemplate(
            name: "Протокол", description: "Решения и задачи",
            sections: [
                AnalysisSection(title: "Итоги", instruction: "Коротко", format: .paragraph),
                AnalysisSection(title: "Решения", instruction: "Что решили", format: .list, cite: true),
                AnalysisSection(title: "Задачи", instruction: "Кто что делает", format: .table,
                                columns: ["Кто", "Что", "Срок"])
            ])
        let data = try AnalysisTemplateTransfer.exportData(original)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(text.contains("\"id\""))
        XCTAssertTrue(text.contains("Протокол"))

        let imported = try XCTUnwrap(AnalysisTemplateTransfer.parse(data, fallbackName: "x").first)
        XCTAssertNotEqual(imported.id, original.id)
        XCTAssertEqual(imported.name, original.name)
        XCTAssertEqual(imported.description, original.description)
        XCTAssertEqual(imported.sections.map(\.title), original.sections.map(\.title))
        XCTAssertEqual(imported.sections.map(\.instruction), original.sections.map(\.instruction))
        XCTAssertEqual(imported.sections.map(\.format), original.sections.map(\.format))
        XCTAssertEqual(imported.sections.map(\.columns), original.sections.map(\.columns))
        XCTAssertEqual(imported.sections.map(\.cite), original.sections.map(\.cite))
        XCTAssertTrue(Set(imported.sections.map(\.id)).isDisjoint(with: original.sections.map(\.id)))
    }

    /// Экспорт встроенного шаблона после импорта — обычный свой шаблон.
    func testImportedBuiltinBecomesOwnTemplate() throws {
        let builtin = BuiltinAnalysisTemplate.meetingMinutes.template
        let data = try AnalysisTemplateTransfer.exportData(builtin)
        let imported = try XCTUnwrap(AnalysisTemplateTransfer.parse(data, fallbackName: "x").first)
        XCTAssertFalse(imported.isBuiltin)
        XCTAssertEqual(imported.sections.count, builtin.sections.count)
        XCTAssertEqual(imported.sections.map(\.columns), builtin.sections.map(\.columns))
    }

    /// Массив шаблонов в одном файле; два импорта одного файла дают разные id.
    func testArrayOfTemplatesAndFreshIDs() throws {
        let json = """
        [{"name": "A", "sections": [{"title": "S", "instruction": "x"}]},
         {"name": "B", "sections": [{"title": "S", "instruction": "y", "format": "table", "columns": ["P", "Q"]}]}]
        """
        let first = try parse(json)
        let second = try parse(json)
        XCTAssertEqual(first.map(\.name), ["A", "B"])
        XCTAssertEqual(first[1].sections[0].columns, ["P", "Q"])
        XCTAssertNotEqual(first.map(\.id), second.map(\.id))
    }

    // MARK: - Отказы и имена

    func testNotATemplate() {
        assertImportError("not json") { $0 == .notTemplate }
        assertImportError("[]") { $0 == .notTemplate }
        assertImportError(#"{"foo": 1}"#) { error in
            // Объект без разделов разбирается, но не проходит валидацию.
            if case .invalid = error { return true }
            return false
        }
        assertImportError(#"{"name": "T", "sections": [{"instruction": "без названия"}]}"#) { $0 == .notTemplate }
    }

    func testValidationLimits() {
        let tooMany = (0...AnalysisTemplate.maxSections)
            .map { #"{"title": "S\#($0)", "instruction": ""}"# }
            .joined(separator: ",")
        assertImportError(#"{"name": "T", "sections": [\#(tooMany)]}"#) { error in
            if case .invalid = error { return true }
            return false
        }
        let longInstruction = String(repeating: "я", count: AnalysisTemplate.maxInstructionLength + 1)
        assertImportError(#"{"name": "T", "sections": [{"title": "S", "instruction": "\#(longInstruction)"}]}"#) { error in
            if case .invalid = error { return true }
            return false
        }
        assertImportError(#"{"name": "T", "sections": [{"title": "  ", "instruction": ""}]}"#) { error in
            if case .invalid = error { return true }
            return false
        }
    }

    /// Пустое название — имя файла; длинное — обрезается до лимита, а не отказ.
    func testNameFallbackAndTruncation() throws {
        let section = #"[{"title": "S", "instruction": ""}]"#
        XCTAssertEqual(try parse(#"{"name": "  ", "sections": \#(section)}"#, fallbackName: "standup").first?.name,
                       "standup")
        XCTAssertEqual(try parse(#"{"sections": \#(section)}"#, fallbackName: "standup").first?.name, "standup")
        let long = String(repeating: "Ш", count: AnalysisTemplate.maxNameLength + 20)
        XCTAssertEqual(try parse(#"{"name": "\#(long)", "sections": \#(section)}"#).first?.name.count,
                       AnalysisTemplate.maxNameLength)
    }

    func testUniqueNames() {
        var names = AnalysisTemplateNames(["Резюме", "Протокол встречи", "Протокол встречи (2)"])
        XCTAssertEqual(names.claim("Новый"), "Новый")
        XCTAssertEqual(names.claim("новый "), "новый (2)")
        XCTAssertEqual(names.claim("РЕЗЮМЕ"), "РЕЗЮМЕ (2)")
        XCTAssertEqual(names.claim("Протокол встречи"), "Протокол встречи (3)")
        XCTAssertEqual(names.claim("Протокол встречи"), "Протокол встречи (4)")

        let long = String(repeating: "Ш", count: AnalysisTemplate.maxNameLength)
        var longNames = AnalysisTemplateNames([long])
        let renamed = longNames.claim(long)
        XCTAssertEqual(renamed.count, AnalysisTemplate.maxNameLength)
        XCTAssertTrue(renamed.hasSuffix(" (2)"))
    }
}
