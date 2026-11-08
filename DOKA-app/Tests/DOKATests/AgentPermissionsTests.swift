import XCTest
@testable import DOKA

/// Разрешения ИИ-агента: умолчания, правила доступа к записям и отказ
/// инструментов при выключенном тумблере.
@MainActor
final class AgentPermissionsTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suiteName = "AgentPermissionsTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    /// Личные данные по умолчанию закрыты, открыто только распознавание
    /// файлов, которые агент приносит сам. Сервер по умолчанию выключен.
    func testDefaults() {
        let settings = AgentAccessSettings(defaults: defaults)
        XCTAssertFalse(settings.isEnabled)
        XCTAssertEqual(settings.port, AgentAccessSettings.defaultPort)
        XCTAssertEqual(settings.permissions, [.transcribeFiles])
    }

    func testSettingsPersistAndSkipUnknownValues() {
        let settings = AgentAccessSettings(defaults: defaults)
        settings.set(.dictionary, allowed: true)
        settings.set(.transcribeFiles, allowed: false)
        settings.port = 50_000
        settings.isEnabled = true
        let reloaded = AgentAccessSettings(defaults: defaults)
        XCTAssertEqual(reloaded.permissions, [.dictionary])
        XCTAssertEqual(reloaded.port, 50_000)
        XCTAssertTrue(reloaded.isEnabled)

        // Значение из будущей версии не обнуляет набор.
        defaults.set(["libraryRead", "teleport"], forKey: "agentAccessPermissions")
        XCTAssertEqual(AgentAccessSettings(defaults: defaults).permissions, [.libraryRead])
    }

    func testPortIsClampedAndPersisted() {
        let settings = AgentAccessSettings(defaults: defaults)
        settings.port = 80
        XCTAssertEqual(settings.port, AgentAccessSettings.portRange.lowerBound)
        XCTAssertEqual(AgentAccessSettings(defaults: defaults).port, AgentAccessSettings.portRange.lowerBound)
    }

    /// Свои записи агент читает и меняет с одним «Распознавать файлы», чужие —
    /// только с доступом к библиотеке.
    func testRecordPolicy() {
        let onlyFiles: Set<AgentPermission> = [.transcribeFiles]
        XCTAssertTrue(AgentAccessPolicy.canRead(createdByAgent: true, permissions: onlyFiles))
        XCTAssertTrue(AgentAccessPolicy.canModify(createdByAgent: true, permissions: onlyFiles))
        XCTAssertFalse(AgentAccessPolicy.canRead(createdByAgent: false, permissions: onlyFiles))
        XCTAssertEqual(AgentAccessPolicy.missingForRead(createdByAgent: false, permissions: onlyFiles), .libraryRead)
        XCTAssertEqual(AgentAccessPolicy.missingForModify(createdByAgent: false, permissions: onlyFiles), .libraryWrite)

        let readOnly: Set<AgentPermission> = [.libraryRead]
        XCTAssertTrue(AgentAccessPolicy.canRead(createdByAgent: false, permissions: readOnly))
        XCTAssertFalse(AgentAccessPolicy.canModify(createdByAgent: false, permissions: readOnly))
        // Без «Распознавать файлы» и свои записи закрыты.
        XCTAssertEqual(AgentAccessPolicy.missingForRead(createdByAgent: true, permissions: readOnly), .transcribeFiles)
        XCTAssertNil(AgentAccessPolicy.missingForRead(createdByAgent: true, permissions: onlyFiles))
    }

    /// Каждый инструмент с разрешением при выключенном тумблере отвечает
    /// отказом с путём к тумблеру — ещё до обращения к сторам.
    func testGatedToolsAreDeniedWithPathToToggle() async {
        let settings = AgentAccessSettings(defaults: defaults)
        for permission in AgentPermission.allCases { settings.set(permission, allowed: false) }
        let log = AgentActivityLog()
        let tools = AgentTools(access: settings, log: log)
        var gated = 0
        for tool in AgentTools.Tool.allCases {
            guard let permission = AgentTools.requiredPermission(for: tool) else { continue }
            gated += 1
            let result = await tools.call(tool.rawValue, arguments: [:])
            XCTAssertEqual(result?.isError, true, tool.rawValue)
            XCTAssertEqual(result?.isDenial, true, tool.rawValue)
            XCTAssertEqual(result?.text, permission.denialMessage, tool.rawValue)
            XCTAssertTrue(permission.denialMessage.contains(permission.title), tool.rawValue)
        }
        XCTAssertEqual(gated, 8)
        XCTAssertEqual(log.entries.count, gated)
        XCTAssertTrue(log.entries.allSatisfy { $0.outcome == .denied })
    }

    func testEveryToolHasSpec() {
        let names = Set(AgentTools.specs.map(\.name))
        XCTAssertEqual(names, Set(AgentTools.Tool.allCases.map(\.rawValue)))
        for spec in AgentTools.specs {
            XCTAssertTrue(JSONSerialization.isValidJSONObject(spec.inputSchema), spec.name)
            XCTAssertEqual(spec.inputSchema["type"] as? String, "object", spec.name)
        }
    }

    func testUnknownToolIsNil() async {
        let tools = AgentTools(access: AgentAccessSettings(defaults: defaults), log: AgentActivityLog())
        let result = await tools.call("format_disk", arguments: [:])
        XCTAssertNil(result)
    }

    func testArgumentsTyping() throws {
        let args = Arguments(["s": "x", "b": true, "n": 3, "f": 2.5, "nil": NSNull()])
        XCTAssertEqual(try args.optionalString("s"), "x")
        XCTAssertNil(try args.optionalString("nil"))
        XCTAssertEqual(try args.optionalBool("b"), true)
        XCTAssertEqual(try args.optionalInt("n"), 3)
        XCTAssertThrowsError(try args.optionalInt("f"))
        XCTAssertThrowsError(try args.optionalBool("n"))   // 3 — не булево
        XCTAssertThrowsError(try args.optionalDouble("b")) // true — не число
        XCTAssertThrowsError(try args.requiredString("missing"))
        XCTAssertThrowsError(try args.requiredUUID("s"))
    }

    /// Регрессия: `Int(Double)` вне диапазона Int — аварийная остановка, и
    /// `{"limit": 1e300}` ронял DOKA одним запросом. Теперь — ошибка аргумента.
    func testHugeNumbersAreArgumentErrorsNotCrashes() throws {
        for huge in [1e300, -1e300, 9.223372036854775808e18, -9.223372036854775808e18, 1e7] {
            XCTAssertThrowsError(try Arguments(["n": huge]).optionalInt("n"), "\(huge)")
        }
        XCTAssertEqual(try Arguments(["n": 1_000_000]).optionalInt("n"), 1_000_000)
        XCTAssertEqual(try Arguments(["n": -5]).optionalInt("n"), -5)
    }

    /// Анализ сохраняется в запись: для записи человека нужны и чтение, и
    /// изменение библиотеки; свои записи агента — с одним «Распознавать файлы».
    func testAnalysisOfHumanRecordNeedsReadAndChange() {
        func missing(_ own: Bool, _ permissions: Set<AgentPermission>) -> AgentPermission? {
            AgentAccessPolicy.missingForRead(createdByAgent: own, permissions: permissions)
                ?? AgentAccessPolicy.missingForModify(createdByAgent: own, permissions: permissions)
        }
        XCTAssertEqual(missing(false, [.analysis, .libraryRead]), .libraryWrite)
        XCTAssertEqual(missing(false, [.analysis, .libraryWrite]), .libraryRead)
        XCTAssertNil(missing(false, [.analysis, .libraryRead, .libraryWrite]))
        XCTAssertNil(missing(true, [.analysis, .transcribeFiles]))
    }

    /// Чтение словаря не даёт права его менять.
    func testDictionaryReadAndWriteAreSeparate() {
        XCTAssertEqual(AgentTools.requiredPermission(for: .listDictionary), .dictionary)
        XCTAssertEqual(AgentTools.requiredPermission(for: .addDictionaryRule), .dictionaryWrite)
        XCTAssertEqual(AgentTools.requiredPermission(for: .removeDictionaryRule), .dictionaryWrite)
        XCTAssertFalse(AgentPermission.dictionaryWrite.isOnByDefault)
    }

    func testMaskedTokenHidesAllButTail() {
        let token = AgentServerController.makeToken()
        let masked = AgentServerController.masked(token)
        XCTAssertTrue(masked.hasSuffix(String(token.suffix(4))))
        XCTAssertFalse(masked.contains(String(token.prefix(8))))
    }

    func testParseDate() {
        XCTAssertNotNil(AgentTools.parseDate("2026-11-01"))
        XCTAssertNotNil(AgentTools.parseDate("2026-11-01T09:00:00Z"))
        XCTAssertNil(AgentTools.parseDate("вчера"))
    }

    func testTokenIsURLSafeAndRandom() {
        let first = AgentServerController.makeToken()
        let second = AgentServerController.makeToken()
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(first.count, 43)  // 32 байта в base64 без «=»
        XCTAssertNil(first.rangeOfCharacter(from: CharacterSet(charactersIn: "+/= ")))
    }
}
