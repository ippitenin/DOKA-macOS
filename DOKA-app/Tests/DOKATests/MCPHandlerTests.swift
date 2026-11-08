import XCTest
@testable import DOKA

/// JSON-RPC слой MCP (`MCPHandler`) на заглушке инструментов.
@MainActor
final class MCPHandlerTests: XCTestCase {
    private final class StubTools: AgentToolProvider {
        var calls: [(String, [String: Any])] = []
        var specs: [AgentToolSpec] {
            [AgentToolSpec(name: "echo", description: "Echo", inputSchema: ["type": "object"])]
        }
        func call(_ name: String, arguments: [String: Any]) async -> AgentToolResult? {
            calls.append((name, arguments))
            guard name == "echo" else { return nil }
            if arguments["fail"] as? Bool == true { return .error("boom") }
            return AgentToolResult(text: arguments["text"] as? String ?? "", isError: false)
        }
    }

    private var tools: StubTools!
    private var handler: MCPHandler!

    override func setUp() async throws {
        tools = StubTools()
        handler = MCPHandler(provider: tools, serverVersion: "9.9", instructions: "hi")
    }

    private func send(_ json: String) async throws -> [String: Any]? {
        guard let data = await handler.handle(Data(json.utf8)) else { return nil }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testInitializeEchoesSupportedVersion() async throws {
        let reply = try await send(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#)
        let result = try XCTUnwrap(reply?["result"] as? [String: Any])
        XCTAssertEqual(result["protocolVersion"] as? String, "2025-03-26")
        XCTAssertEqual((result["serverInfo"] as? [String: Any])?["version"] as? String, "9.9")
        XCTAssertNotNil((result["capabilities"] as? [String: Any])?["tools"])
        XCTAssertEqual(reply?["id"] as? Int, 1)
    }

    func testInitializeWithUnknownVersionOffersNewest() async throws {
        let reply = try await send(#"{"jsonrpc":"2.0","id":"a","method":"initialize","params":{"protocolVersion":"1999-01-01"}}"#)
        let result = try XCTUnwrap(reply?["result"] as? [String: Any])
        XCTAssertEqual(result["protocolVersion"] as? String, MCPHandler.supportedVersions[0])
        XCTAssertEqual(reply?["id"] as? String, "a")
    }

    func testNotificationHasNoResponse() async throws {
        let reply = try await send(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        XCTAssertNil(reply)
    }

    func testToolsListAndCall() async throws {
        let list = try await send(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        let tools = try XCTUnwrap((list?["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.first?["name"] as? String, "echo")
        XCTAssertNotNil(tools.first?["inputSchema"])

        let call = try await send(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"echo","arguments":{"text":"привет"}}}"#)
        let result = try XCTUnwrap(call?["result"] as? [String: Any])
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        XCTAssertEqual(content.first?["type"] as? String, "text")
        XCTAssertEqual(content.first?["text"] as? String, "привет")
        XCTAssertNil(result["isError"])
    }

    /// Ошибка инструмента — обычный результат с isError, а не ошибка протокола:
    /// так её видит модель агента.
    func testToolErrorIsResultWithFlag() async throws {
        let call = try await send(#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"echo","arguments":{"fail":true}}}"#)
        let result = try XCTUnwrap(call?["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
    }

    func testProtocolErrors() async throws {
        let unknownTool = try await send(#"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"nope"}}"#)
        XCTAssertEqual((unknownTool?["error"] as? [String: Any])?["code"] as? Int, MCPHandler.RPCError.invalidParams)

        let unknownMethod = try await send(#"{"jsonrpc":"2.0","id":6,"method":"resources/list"}"#)
        XCTAssertEqual((unknownMethod?["error"] as? [String: Any])?["code"] as? Int, MCPHandler.RPCError.methodNotFound)

        let broken = try await send("{not json")
        XCTAssertEqual((broken?["error"] as? [String: Any])?["code"] as? Int, MCPHandler.RPCError.parse)

        let batch = try await send(#"[{"jsonrpc":"2.0","id":7,"method":"ping"}]"#)
        XCTAssertEqual((batch?["error"] as? [String: Any])?["code"] as? Int, MCPHandler.RPCError.invalidRequest)
    }

    func testPing() async throws {
        let reply = try await send(#"{"jsonrpc":"2.0","id":8,"method":"ping"}"#)
        XCTAssertNotNil(reply?["result"] as? [String: Any])
    }
}
