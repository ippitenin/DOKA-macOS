import Foundation

/// Готовая настройка подключения MCP-сервера DOKA для разных агентов —
/// список «Готовая настройка для:» на странице «Доступ для ИИ-агентов».
/// Сервер универсальный (MCP по HTTP): по адресу и токену подключается любой
/// агент, отличается только КУДА вписать настройку.
///
/// Форматы сверены с официальной документацией 8.11.2026 (Claude Code, Cursor,
/// VS Code, Gemini CLI, Codex, README mcp-remote). У Codex механизм
/// `http_headers` описан, но пример именно с `Authorization` не показан —
/// проверяется живьём (`SMOKE.md`).
///
/// Порядок кейсов — порядок в списке; `rawValue` хранится (`@AppStorage`) —
/// не переименовывать.
enum AgentClient: String, CaseIterable, Identifiable {
    case claudeCode
    case cursor
    case vscode
    case geminiCLI
    case codex
    /// Клиенты, которые умеют только запускать команду (Claude Desktop):
    /// мост `mcp-remote` переводит stdio в HTTP.
    case mcpRemote

    var id: String { rawValue }

    var title: String {
        switch self {
        case .claudeCode: return L("agent.client.claudeCode")
        case .cursor: return L("agent.client.cursor")
        case .vscode: return L("agent.client.vscode")
        case .geminiCLI: return L("agent.client.geminiCLI")
        case .codex: return L("agent.client.codex")
        case .mcpRemote: return L("agent.client.mcpRemote")
        }
    }

    /// Куда вставить фрагмент.
    var placeHint: String {
        switch self {
        case .claudeCode: return L("agent.client.claudeCode.hint")
        case .cursor: return L("agent.client.cursor.hint")
        case .vscode: return L("agent.client.vscode.hint")
        case .geminiCLI: return L("agent.client.geminiCLI.hint")
        case .codex: return L("agent.client.codex.hint")
        case .mcpRemote: return L("agent.client.mcpRemote.hint")
        }
    }

    /// Имя сервера в настройках агента.
    static let serverName = "doka"

    /// Фрагмент для копирования. `token` — настоящий (для буфера) или
    /// замаскированный (для экрана).
    func snippet(url: String, token: String) -> String {
        let authorization = "Bearer \(token)"
        switch self {
        case .claudeCode:
            return "claude mcp add --transport http \(Self.serverName) \(url) --header \"Authorization: \(authorization)\""
        case .cursor:
            return Self.json(["mcpServers": [Self.serverName: [
                "url": url, "headers": ["Authorization": authorization]]]])
        case .vscode:
            return Self.json(["servers": [Self.serverName: [
                "type": "http", "url": url, "headers": ["Authorization": authorization]]]])
        case .geminiCLI:
            return Self.json(["mcpServers": [Self.serverName: [
                "httpUrl": url, "headers": ["Authorization": authorization]]]])
        case .codex:
            // TOML строкой: адрес — цифры и латиница, токен — base64url,
            // экранировать нечего.
            return """
            [mcp_servers.\(Self.serverName)]
            url = "\(url)"
            http_headers = { "Authorization" = "\(authorization)" }
            """
        case .mcpRemote:
            return Self.json(["mcpServers": [Self.serverName: [
                "command": "npx",
                "args": ["-y", "mcp-remote", url, "--header", "Authorization: \(authorization)"]]]])
        }
    }

    /// JSON сериализатором, а не склейкой строк: кавычки и слеши экранируются.
    private static func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(
                withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }
}
