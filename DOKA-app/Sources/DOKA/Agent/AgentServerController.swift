import Combine
import Foundation
import Security

/// Журнал обращений агента: последние вызовы инструментов, только в памяти.
/// Показывается на странице «Доступ для ИИ-агентов» — видно, что агент делал
/// и где упёрся в выключенное разрешение.
@MainActor
final class AgentActivityLog: ObservableObject {
    enum Outcome: Equatable {
        case done
        case denied
        case failed
    }

    struct Entry: Identifiable, Equatable {
        let id = UUID()
        let date: Date
        let tool: String
        let outcome: Outcome
    }

    static let limit = 50

    @Published private(set) var entries: [Entry] = []

    func add(tool: String, result: AgentToolResult) {
        add(tool: tool, outcome: result.isDenial ? .denied : (result.isError ? .failed : .done))
    }

    func add(tool: String, outcome: Outcome) {
        entries.insert(Entry(date: Date(), tool: tool, outcome: outcome), at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
    }

    func clear() { entries.removeAll() }
}

/// Локальный сервер для ИИ-агентов: живёт, пока включён главный тумблер.
/// Владеет транспортом (`LocalAPIServer`), токеном и MCP-обработчиком.
/// Создаётся в `AppDelegate` (`activate`), дальше следит за настройками сам.
@MainActor
final class AgentServerController: ObservableObject {
    static let shared = AgentServerController()

    enum Status: Equatable {
        case off
        case starting
        case running(port: Int)
        case failed(String)
    }

    /// Аккаунт токена в Keychain (сервис — общий `com.pitenin.doka`).
    nonisolated static let tokenAccount = "agent-access-token"
    /// Путь MCP-эндпоинта.
    nonisolated static let mcpPath = "/mcp"

    @Published private(set) var status: Status = .off
    /// Токен для заголовка `Authorization`; nil — ещё читается из Keychain.
    @Published private(set) var token: String?

    let access = AgentAccessSettings.shared
    let log = AgentActivityLog()
    private lazy var tools = AgentTools(access: access, log: log)
    private lazy var mcp = MCPHandler(provider: tools, serverVersion: AppVersion.short,
                                      instructions: AgentTools.serverInstructions)
    private var server: LocalAPIServer?
    private var cancellables = Set<AnyCancellable>()
    private var activated = false
    private var tokenLoading = false

    private init() {}

    /// Однократный запуск из `AppDelegate`: дальше контроллер следит за
    /// тумблером и портом сам.
    func activate() {
        guard !activated else { return }
        activated = true
        // Загрузки API, оставшиеся после аварийного выхода, — стереть.
        Task.detached(priority: .utility) { OpenAITranscriptionAPI.sweepLeftovers() }
        Publishers.CombineLatest(access.$isEnabled, access.$port)
            .removeDuplicates { $0 == $1 }
            .sink { [weak self] enabled, port in
                // @Published отдаёт значение до записи в свойство — берём из
                // параметров, а не из `access`.
                self?.sync(enabled: enabled, port: port)
            }
            .store(in: &cancellables)
    }

    /// Токен читается из Keychain (и создаётся при первом включении) только
    /// когда доступ включён — пока функцией не пользуются, секрета нет вовсе.
    /// Фоном: синхронное чтение Keychain может заморозить приложение диалогом
    /// доступа к ключу (корневой CLAUDE.md, «Синхронное чтение Keychain»).
    private func loadTokenIfNeeded() {
        guard token == nil, !tokenLoading else { return }
        tokenLoading = true
        Task.detached(priority: .utility) {
            let stored = KeychainHelper.getAPIKey(account: Self.tokenAccount)
            let value = stored ?? Self.makeToken()
            if stored == nil { KeychainHelper.setAPIKey(value, account: Self.tokenAccount) }
            await MainActor.run { AgentServerController.shared.tokenLoaded(value) }
        }
    }

    private func tokenLoaded(_ value: String) {
        tokenLoading = false
        // Пока читали, человек успел нажать «Сменить токен» — новый главнее.
        if token == nil { token = value }
        sync(enabled: access.isEnabled, port: access.port)
    }

    /// Новый токен: старый перестаёт работать сразу, агентов надо
    /// переподключить командой со страницы.
    func regenerateToken() {
        let value = Self.makeToken()
        token = value
        Task.detached(priority: .utility) {
            KeychainHelper.setAPIKey(value, account: Self.tokenAccount)
        }
    }

    /// Адрес MCP для подключения агента.
    var endpointURL: String { "http://127.0.0.1:\(access.port)\(Self.mcpPath)" }

    /// Токен для показа на экране: целиком его видно только в буфере обмена
    /// (демонстрация экрана и запись экрана его не покажут).
    nonisolated static func masked(_ token: String) -> String {
        "••••••••" + token.suffix(4)
    }

    // MARK: - Жизненный цикл сервера

    private func sync(enabled: Bool, port: Int) {
        guard enabled else {
            stopServer()
            status = .off
            return
        }
        // Без токена сервер не поднимаем: проверять было бы нечем.
        guard token != nil else {
            status = .starting
            loadTokenIfNeeded()
            return
        }
        if let server, server.port == port, status != .off, !isFailed { return }
        stopServer()
        let created = LocalAPIServer(
            port: port,
            preflight: { head in await AgentServerController.shared.preflight(head) },
            handler: { request in await AgentServerController.shared.respond(to: request) },
            onState: { state in
                Task { @MainActor in AgentServerController.shared.serverStateChanged(state, port: port) }
            })
        server = created
        status = .starting
        created.start()
    }

    private var isFailed: Bool {
        if case .failed = status { return true }
        return false
    }

    private func stopServer() {
        server?.stop()
        server = nil
    }

    private func serverStateChanged(_ state: LocalAPIServer.State, port: Int) {
        // Сообщение от старого сервера (сменили порт или выключили) — мимо.
        guard server?.port == port, access.isEnabled else { return }
        switch state {
        case .starting: status = .starting
        case .running(let port):
            status = .running(port: port)
            NSLog("DOKA: доступ для ИИ-агентов — сервер на 127.0.0.1:%d", port)
        case .failed(let message):
            status = .failed(message)
            server = nil
            NSLog("DOKA: доступ для ИИ-агентов — сервер не запустился: %@", message)
        case .stopped: break
        }
    }

    // MARK: - Запросы

    /// Пути обычного API для программ (OpenAI-совместимого).
    nonisolated static let apiModelsPath = "/v1/models"
    nonisolated static let apiTranscriptionsPath = "/v1/audio/transcriptions"

    /// Решение по заголовкам ДО приёма тела: охрана, маршрут, лимит тела.
    /// Без токена тело не читается вовсе.
    func preflight(_ head: HTTPHead) -> LocalAPIServer.Decision {
        let isAPI = head.path.hasPrefix("/v1/")
        // Выключили тумблер, а соединение уже пришло — не обслуживаем.
        guard access.isEnabled, let token else {
            return .reject(Self.failure(status: 503, message: "Service Unavailable", api: isAPI))
        }
        switch LocalAPIGuard.check(head, token: token) {
        case .forbidden:
            return .reject(Self.failure(status: 403, message: "Forbidden", api: isAPI))
        case .unauthorized:
            var response = isAPI
                ? OpenAIError(status: 401, type: "invalid_request_error", code: "invalid_api_key",
                              message: "Invalid API key. Copy the key from DOKA: General → AI agent access.").response
                : HTTPResponse.text("Unauthorized", status: 401)
            response.headers["WWW-Authenticate"] = "Bearer"
            return .reject(response)
        case .allowed:
            break
        }
        switch (head.path, head.method) {
        case (Self.mcpPath, "POST"), (Self.apiModelsPath, "GET"):
            guard head.contentLength <= HTTPRequestParser.maxBodyBytes else {
                return .reject(Self.failure(status: 413, message: "Payload Too Large", api: isAPI))
            }
            return .accept(.memory, onAbort: nil)
        case (Self.apiTranscriptionsPath, "POST"):
            let decision = OpenAITranscriptionAPI.shared.preflight(head, permissionOn: access.isAllowed(.openAIAPI))
            if case .reject = decision {
                log.add(tool: "API: transcriptions", outcome: access.isAllowed(.openAIAPI) ? .failed : .denied)
            }
            return decision
        case (Self.mcpPath, _), (Self.apiModelsPath, _), (Self.apiTranscriptionsPath, _):
            // SSE-потока для сервера у нас нет — спецификация MCP разрешает 405.
            var response = Self.failure(status: 405, message: "Method Not Allowed", api: isAPI)
            response.headers["Allow"] = head.path == Self.apiModelsPath ? "GET" : "POST"
            return .reject(response)
        default:
            return .reject(Self.failure(status: 404, message: "Not Found", api: isAPI))
        }
    }

    /// Тело принято (`preflight` разрешил) — ответить.
    func respond(to request: HTTPRequest) async -> HTTPResponse {
        switch request.path {
        case Self.mcpPath:
            guard let body = await mcp.handle(request.body) else { return HTTPResponse(status: 202) }
            return .json(body)
        case Self.apiModelsPath:
            guard access.isAllowed(.openAIAPI) else {
                return OpenAIError(status: 403, type: "permission_error", code: "api_disabled",
                                   message: AgentPermission.openAIAPI.denialMessage).response
            }
            let providerID = SettingsStore.shared.providerID
            let title = LocalModel.from(providerID: providerID)?.title
                ?? TranscriptionProvider(rawValue: SettingsStore.shared.providerTag(for: providerID))?.title
                ?? SettingsStore.shared.providerTag(for: providerID)
            return OpenAIResponses.models(serviceTitle: title)
        case Self.apiTranscriptionsPath:
            let started = Date()
            let (response, outcome) = await OpenAITranscriptionAPI.shared.handle(request)
            log.add(tool: "API: transcriptions (\(Int(Date().timeIntervalSince(started))) s)", outcome: outcome)
            return response
        default:
            return .text("Not Found", status: 404)
        }
    }

    /// Отказ: у API — в формате OpenAI (программы показывают `error.message`),
    /// у MCP — простым текстом.
    private static func failure(status: Int, message: String, api: Bool) -> HTTPResponse {
        guard api else { return .text(message, status: status) }
        return OpenAIError(status: status, type: status >= 500 ? "server_error" : "invalid_request_error",
                           code: message.lowercased().replacingOccurrences(of: " ", with: "_"),
                           message: message).response
    }

    // MARK: - Токен

    /// 32 случайных байта в base64url — без символов, которые ломают заголовок.
    nonisolated static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max) }
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
