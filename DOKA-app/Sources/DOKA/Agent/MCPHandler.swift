import Foundation

/// Описание инструмента для `tools/list`.
struct AgentToolSpec {
    let name: String
    /// Описание для модели агента — на английском: это не строка интерфейса,
    /// а часть протокола, и агенты понимают её лучше всего.
    let description: String
    /// JSON Schema аргументов.
    let inputSchema: [String: Any]
}

/// Итог вызова инструмента: текст для агента и признак ошибки.
struct AgentToolResult: Equatable {
    var text: String
    var isError: Bool
    /// Отказ по выключенному разрешению — для журнала обращений; в протокол
    /// уходит обычной ошибкой инструмента.
    var isDenial = false

    static func error(_ message: String) -> AgentToolResult {
        AgentToolResult(text: message, isError: true)
    }

    static func denied(_ permission: AgentPermission) -> AgentToolResult {
        AgentToolResult(text: permission.denialMessage, isError: true, isDenial: true)
    }

    /// Ответ-объект: агенту удобнее разбирать JSON, чем прозу.
    static func json(_ object: Any) -> AgentToolResult {
        let options: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: options),
              let text = String(data: data, encoding: .utf8) else {
            return .error("internal error: result is not serializable")
        }
        return AgentToolResult(text: text, isError: false)
    }
}

/// Источник инструментов: настоящий `AgentTools` или заглушка в тестах.
@MainActor
protocol AgentToolProvider: AnyObject {
    var specs: [AgentToolSpec] { get }
    /// nil — такого инструмента нет.
    func call(_ name: String, arguments: [String: Any]) async -> AgentToolResult?
}

/// MCP поверх JSON-RPC 2.0, транспорт Streamable HTTP без SSE: на каждый
/// POST — один JSON-ответ, на уведомление — пустой ответ 202. Свой слой, а не
/// SDK: методов всего пять.
@MainActor
final class MCPHandler {
    /// Поддерживаемые версии протокола, новые — первыми. Нужное нам
    /// подмножество (инструменты без SSE) во всех версиях одинаково.
    static let supportedVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    private let provider: AgentToolProvider
    private let serverVersion: String
    private let instructions: String

    init(provider: AgentToolProvider, serverVersion: String, instructions: String) {
        self.provider = provider
        self.serverVersion = serverVersion
        self.instructions = instructions
    }

    enum RPCError {
        static let parse = -32_700
        static let invalidRequest = -32_600
        static let methodNotFound = -32_601
        static let invalidParams = -32_602
    }

    /// Тело ответа; nil — ответа нет (уведомление), HTTP 202.
    func handle(_ body: Data) async -> Data? {
        guard let object = try? JSONSerialization.jsonObject(with: body) else {
            return Self.error(id: NSNull(), code: RPCError.parse, message: "Parse error")
        }
        guard let message = object as? [String: Any] else {
            // Пакеты (массивы) в MCP с 2025-06-18 убраны.
            return Self.error(id: NSNull(), code: RPCError.invalidRequest, message: "Batches are not supported")
        }
        guard message["jsonrpc"] as? String == "2.0", let method = message["method"] as? String else {
            // Ответ клиента на наш запрос — нам их не шлют, но и ругаться не за что.
            if message["result"] != nil || message["error"] != nil { return nil }
            return Self.error(id: message["id"] ?? NSNull(), code: RPCError.invalidRequest,
                              message: "Invalid request")
        }
        guard let id = message["id"], !(id is NSNull) else {
            // Уведомление (`notifications/initialized` и др.): ответа нет.
            return nil
        }
        let params = message["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            return Self.result(id: id, initializeResult(params))
        case "ping":
            return Self.result(id: id, [String: Any]())
        case "tools/list":
            let tools: [[String: Any]] = provider.specs.map {
                ["name": $0.name, "description": $0.description, "inputSchema": $0.inputSchema]
            }
            return Self.result(id: id, ["tools": tools])
        case "tools/call":
            guard let name = params["name"] as? String else {
                return Self.error(id: id, code: RPCError.invalidParams, message: "Missing tool name")
            }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            guard let outcome = await provider.call(name, arguments: arguments) else {
                return Self.error(id: id, code: RPCError.invalidParams, message: "Unknown tool: \(name)")
            }
            var result: [String: Any] = ["content": [["type": "text", "text": outcome.text]]]
            if outcome.isError { result["isError"] = true }
            return Self.result(id: id, result)
        default:
            return Self.error(id: id, code: RPCError.methodNotFound, message: "Method not found: \(method)")
        }
    }

    private func initializeResult(_ params: [String: Any]) -> [String: Any] {
        let requested = params["protocolVersion"] as? String
        let version = requested.flatMap { Self.supportedVersions.contains($0) ? $0 : nil }
            ?? Self.supportedVersions[0]
        return [
            "protocolVersion": version,
            "capabilities": ["tools": ["listChanged": false]],
            "serverInfo": ["name": "DOKA", "version": serverVersion],
            "instructions": instructions
        ]
    }

    private static func result(id: Any, _ result: Any) -> Data? {
        encode(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private static func error(id: Any, code: Int, message: String) -> Data? {
        encode(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    private static func encode(_ object: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
    }
}
