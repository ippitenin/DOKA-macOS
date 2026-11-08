import XCTest
@testable import DOKA

/// Готовые настройки подключения агентов (`AgentClient`): у каждого клиента —
/// адрес и токен в правильном месте, JSON разбирается.
final class AgentClientSetupTests: XCTestCase {
    private let url = "http://127.0.0.1:47800/mcp"
    private let token = "abc_DEF-123"

    func testEverySnippetCarriesAddressAndToken() {
        for client in AgentClient.allCases {
            let snippet = client.snippet(url: url, token: token)
            XCTAssertTrue(snippet.contains(url), client.rawValue)
            XCTAssertTrue(snippet.contains("Bearer \(token)"), client.rawValue)
            XCTAssertFalse(client.title.isEmpty, client.rawValue)
            XCTAssertFalse(client.placeHint.isEmpty, client.rawValue)
        }
    }

    private func server(_ client: AgentClient, root: String) throws -> [String: Any] {
        let data = Data(client.snippet(url: url, token: token).utf8)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any], client.rawValue)
        let servers = try XCTUnwrap(object[root] as? [String: Any], client.rawValue)
        return try XCTUnwrap(servers[AgentClient.serverName] as? [String: Any], client.rawValue)
    }

    private func authorization(_ entry: [String: Any]) -> String? {
        (entry["headers"] as? [String: Any])?["Authorization"] as? String
    }

    /// Ключи — как в документации клиентов (сверено 8.11.2026).
    func testJSONSnippetsMatchClientFormats() throws {
        let cursor = try server(.cursor, root: "mcpServers")
        XCTAssertEqual(cursor["url"] as? String, url)
        XCTAssertEqual(authorization(cursor), "Bearer \(token)")

        let vscode = try server(.vscode, root: "servers")
        XCTAssertEqual(vscode["type"] as? String, "http")
        XCTAssertEqual(vscode["url"] as? String, url)
        XCTAssertEqual(authorization(vscode), "Bearer \(token)")

        let gemini = try server(.geminiCLI, root: "mcpServers")
        XCTAssertEqual(gemini["httpUrl"] as? String, url)
        XCTAssertEqual(authorization(gemini), "Bearer \(token)")

        let bridge = try server(.mcpRemote, root: "mcpServers")
        XCTAssertEqual(bridge["command"] as? String, "npx")
        XCTAssertEqual(bridge["args"] as? [String], ["-y", "mcp-remote", url, "--header", "Authorization: Bearer \(token)"])
    }

    func testCommandAndTomlSnippets() {
        XCTAssertEqual(AgentClient.claudeCode.snippet(url: url, token: token),
                       "claude mcp add --transport http doka \(url) --header \"Authorization: Bearer \(token)\"")
        let toml = AgentClient.codex.snippet(url: url, token: token)
        XCTAssertTrue(toml.hasPrefix("[mcp_servers.doka]\n"))
        XCTAssertTrue(toml.contains("url = \"\(url)\""))
        XCTAssertTrue(toml.contains("http_headers = { \"Authorization\" = \"Bearer \(token)\" }"))
    }

    /// Разрешения агента на странице — без API для программ (у него своя карточка).
    func testAgentPermissionsExcludeAppAPI() {
        XCTAssertFalse(AgentPermission.agentCases.contains(.openAIAPI))
        XCTAssertEqual(AgentPermission.agentCases.count, AgentPermission.allCases.count - 1)
    }
}
