import Foundation

/// Проверка каждого запроса к локальному серверу агентов. Чистая функция.
///
/// Слушаем только 127.0.0.1, но этого мало: страница в браузере тоже может
/// отправить запрос на localhost, а через DNS rebinding — под чужим именем
/// хоста. Поэтому три барьера (спецификация MCP требует проверять Origin):
/// 1. `Host` — только адрес этого Mac (127.0.0.1, localhost, [::1]);
/// 2. `Origin`, если он есть, — тоже только этот Mac: браузер ставит его всегда,
///    консольные клиенты агентов — нет;
/// 3. `Authorization: Bearer <токен>` из настроек DOKA.
enum LocalAPIGuard {
    enum Verdict: Equatable {
        case allowed
        /// 403: чужой хост или страница сайта.
        case forbidden
        /// 401: нет токена или он неверный.
        case unauthorized
    }

    static func check(_ request: HTTPRequest, token: String) -> Verdict {
        check(headers: request.headers, token: token)
    }

    /// По одним заголовкам — до приёма тела.
    static func check(_ head: HTTPHead, token: String) -> Verdict {
        check(headers: head.headers, token: token)
    }

    /// `headers` — имена в нижнем регистре (так их отдаёт `HTTPRequestParser`).
    static func check(headers: [String: String], token: String) -> Verdict {
        guard let host = headers["host"], isLoopback(hostHeader: host) else { return .forbidden }
        if let origin = headers["origin"], !isLoopback(origin: origin) { return .forbidden }
        guard !token.isEmpty, let auth = headers["authorization"] else { return .unauthorized }
        let prefix = "bearer "
        guard auth.lowercased().hasPrefix(prefix) else { return .unauthorized }
        let presented = auth.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        return constantTimeEquals(presented, token) ? .allowed : .unauthorized
    }

    /// `Host: 127.0.0.1:47800` → хост без порта; IPv6 — в квадратных скобках.
    static func isLoopback(hostHeader: String) -> Bool {
        let value = hostHeader.trimmingCharacters(in: .whitespaces).lowercased()
        let host: String
        if value.hasPrefix("["), let close = value.firstIndex(of: "]") {
            host = String(value[value.index(after: value.startIndex)..<close])
        } else {
            host = String(value.split(separator: ":", maxSplits: 1).first ?? "")
        }
        return ["127.0.0.1", "localhost", "::1"].contains(host)
    }

    /// `Origin: http://localhost:6274` — страница, открытая с этого же Mac
    /// (например, отладчик MCP Inspector). `null` — песочница или file://.
    static func isLoopback(origin: String) -> Bool {
        guard let url = URL(string: origin), let host = url.host?.lowercased() else { return false }
        return ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host)
    }

    /// Сравнение без раннего выхода: время не выдаёт, сколько символов совпало.
    static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let left = Array(a.utf8)
        let right = Array(b.utf8)
        guard left.count == right.count else { return false }
        var diff: UInt8 = 0
        for index in left.indices { diff |= left[index] ^ right[index] }
        return diff == 0
    }
}
