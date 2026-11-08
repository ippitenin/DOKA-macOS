import Foundation

/// Заголовки запроса — их проверяют ДО приёма тела (`preflight`): без токена
/// сервер не примет ни байта тела. Имена заголовков — в нижнем регистре.
struct HTTPHead: Equatable {
    let method: String
    /// Путь без строки запроса («/mcp»).
    let path: String
    let headers: [String: String]
    /// Длина тела (`Content-Length`; 0 — тела нет).
    let contentLength: Int
    /// Сколько байт буфера заняли строка запроса и заголовки.
    let headerLength: Int

    func header(_ name: String) -> String? { headers[name.lowercased()] }
}

/// Входящий HTTP-запрос локального сервера агентов. Тело — в памяти (`body`,
/// маленькие JSON) или во временном файле (`bodyFile`, загрузка звука).
struct HTTPRequest: Equatable {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
    var bodyFile: URL? = nil

    init(method: String, path: String, headers: [String: String], body: Data, bodyFile: URL? = nil) {
        self.method = method
        self.path = path
        self.headers = headers
        self.body = body
        self.bodyFile = bodyFile
    }

    init(head: HTTPHead, body: Data, bodyFile: URL? = nil) {
        self.init(method: head.method, path: head.path, headers: head.headers, body: body, bodyFile: bodyFile)
    }

    func header(_ name: String) -> String? { headers[name.lowercased()] }
}

/// Ответ локального сервера. Соединение после ответа закрывается
/// (`Connection: close`): запросы агента редкие, держать keep-alive незачем.
struct HTTPResponse: Equatable {
    var status: Int
    var headers: [String: String] = [:]
    var body: Data = Data()

    static func json(_ data: Data, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, headers: ["Content-Type": "application/json"], body: data)
    }

    static func text(_ text: String, status: Int) -> HTTPResponse {
        HTTPResponse(status: status, headers: ["Content-Type": "text/plain; charset=utf-8"],
                     body: Data(text.utf8))
    }

    /// Готовые байты ответа для сокета.
    func serialized() -> Data {
        var head = "HTTP/1.1 \(status) \(Self.reason(for: status))\r\n"
        var all = headers
        all["Content-Length"] = String(body.count)
        all["Connection"] = "close"
        for key in all.keys.sorted() {
            head += "\(key): \(all[key] ?? "")\r\n"
        }
        head += "\r\n"
        var data = Data(head.utf8)
        data.append(body)
        return data
    }

    static func reason(for status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 202: return "Accepted"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 411: return "Length Required"
        case 413: return "Payload Too Large"
        case 415: return "Unsupported Media Type"
        case 429: return "Too Many Requests"
        case 500: return "Internal Server Error"
        case 503: return "Service Unavailable"
        case 507: return "Insufficient Storage"
        case 431: return "Request Header Fields Too Large"
        case 501: return "Not Implemented"
        default: return "Error"
        }
    }
}

/// Разбор HTTP/1.1-запроса из накопленных байтов соединения. Чистая логика:
/// сокет кормит её по мере прихода данных, пока не получит запрос или отказ.
/// Поддерживается только тело с `Content-Length` — chunked агентам MCP не нужен.
enum HTTPRequestParser {
    /// Заголовки длиннее — отказ: настоящему клиенту MCP столько не нужно.
    static let maxHeaderBytes = 16 * 1024
    /// Тело в памяти (JSON-RPC MCP) — маленькие объекты: пути к файлам, а не
    /// сами файлы. Звук идёт потоком на диск (`OpenAIPreflight.maxUploadBytes`).
    static let maxBodyBytes = 1024 * 1024

    enum HeadOutcome: Equatable {
        /// Байтов пока мало — ждать ещё.
        case incomplete
        case head(HTTPHead)
        /// Запрос разобрать нельзя — ответить этим статусом и закрыть.
        case failure(status: Int)
    }

    enum Outcome: Equatable {
        case incomplete
        case request(HTTPRequest)
        case failure(status: Int)
    }

    /// Только строка запроса и заголовки. Длину тела НЕ ограничивает — это
    /// решает маршрут (`preflight`): `/mcp` — 1 МБ в памяти, загрузка звука —
    /// до 1 ГБ потоком на диск.
    static func parseHead(_ buffer: Data) -> HeadOutcome {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerEnd = buffer.range(of: separator) else {
            return buffer.count > maxHeaderBytes ? .failure(status: 431) : .incomplete
        }
        guard headerEnd.lowerBound - buffer.startIndex <= maxHeaderBytes else { return .failure(status: 431) }
        guard let head = String(data: buffer[buffer.startIndex..<headerEnd.lowerBound], encoding: .utf8) else {
            return .failure(status: 400)
        }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1.") else {
            return .failure(status: 400)
        }
        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { return .failure(status: 400) }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return .failure(status: 400) }
            // Два заголовка с одним именем, от которых зависит решение
            // (длина, хост, токен, Origin), — признак подделки: отказ.
            if headers[name] != nil, ["content-length", "host", "authorization", "origin", "content-type"].contains(name) {
                return .failure(status: 400)
            }
            headers[name] = value
        }
        if let encoding = headers["transfer-encoding"], encoding.lowercased() != "identity" {
            return .failure(status: 501)
        }
        let method = String(requestLine[0]).uppercased()
        let target = String(requestLine[1])
        let path = String(target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")

        let length: Int
        if let raw = headers["content-length"] {
            guard !raw.isEmpty, raw.allSatisfy(\.isASCII), raw.allSatisfy(\.isNumber),
                  let value = Int(raw), value >= 0 else { return .failure(status: 400) }
            length = value
        } else {
            // POST без длины тела разобрать нельзя (chunked не поддерживаем).
            if method == "POST" { return .failure(status: 411) }
            length = 0
        }
        return .head(HTTPHead(method: method, path: path, headers: headers, contentLength: length,
                              headerLength: headerEnd.upperBound - buffer.startIndex))
    }

    /// Запрос целиком с телом в памяти не больше `maxBodyBytes`.
    static func parse(_ buffer: Data) -> Outcome {
        switch parseHead(buffer) {
        case .incomplete: return .incomplete
        case .failure(let status): return .failure(status: status)
        case .head(let head):
            guard head.contentLength <= maxBodyBytes else { return .failure(status: 413) }
            let bodyStart = buffer.startIndex + head.headerLength
            guard buffer.count - head.headerLength >= head.contentLength else { return .incomplete }
            let body = Data(buffer[bodyStart..<(bodyStart + head.contentLength)])
            return .request(HTTPRequest(head: head, body: body))
        }
    }
}
