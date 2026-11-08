import XCTest
@testable import DOKA

/// Охрана локального сервера агентов: хост, Origin браузера и токен.
final class LocalAPIGuardTests: XCTestCase {
    private let token = "secret-token"

    private func request(host: String? = "127.0.0.1:47800", origin: String? = nil,
                         auth: String? = "Bearer secret-token") -> HTTPRequest {
        var headers: [String: String] = [:]
        if let host { headers["host"] = host }
        if let origin { headers["origin"] = origin }
        if let auth { headers["authorization"] = auth }
        return HTTPRequest(method: "POST", path: "/mcp", headers: headers, body: Data())
    }

    func testConsoleClientWithTokenIsAllowed() {
        XCTAssertEqual(LocalAPIGuard.check(request(), token: token), .allowed)
        XCTAssertEqual(LocalAPIGuard.check(request(host: "localhost:47800"), token: token), .allowed)
        XCTAssertEqual(LocalAPIGuard.check(request(host: "[::1]:47800"), token: token), .allowed)
        XCTAssertEqual(LocalAPIGuard.check(request(auth: "bearer secret-token"), token: token), .allowed)
    }

    func testMissingOrWrongTokenIsUnauthorized() {
        XCTAssertEqual(LocalAPIGuard.check(request(auth: nil), token: token), .unauthorized)
        XCTAssertEqual(LocalAPIGuard.check(request(auth: "Bearer wrong"), token: token), .unauthorized)
        XCTAssertEqual(LocalAPIGuard.check(request(auth: "Basic c2VjcmV0"), token: token), .unauthorized)
        XCTAssertEqual(LocalAPIGuard.check(request(auth: "Bearer secret-token-longer"), token: token), .unauthorized)
        // Пустой токен в настройках не пускает никого, даже с пустым заголовком.
        XCTAssertEqual(LocalAPIGuard.check(request(auth: "Bearer "), token: ""), .unauthorized)
    }

    /// Страница сайта в браузере: Origin чужой — отказ ещё до токена.
    func testBrowserPageIsForbidden() {
        XCTAssertEqual(LocalAPIGuard.check(request(origin: "https://example.com"), token: token), .forbidden)
        XCTAssertEqual(LocalAPIGuard.check(request(origin: "null"), token: token), .forbidden)
    }

    /// Отладчик MCP Inspector открыт с этого же Mac — пропускаем.
    func testLocalPageIsAllowed() {
        XCTAssertEqual(LocalAPIGuard.check(request(origin: "http://localhost:6274"), token: token), .allowed)
        XCTAssertEqual(LocalAPIGuard.check(request(origin: "http://127.0.0.1:6274"), token: token), .allowed)
    }

    /// DNS rebinding: запрос пришёл на 127.0.0.1, но под чужим именем хоста.
    func testForeignHostIsForbidden() {
        XCTAssertEqual(LocalAPIGuard.check(request(host: "evil.example.com:47800"), token: token), .forbidden)
        XCTAssertEqual(LocalAPIGuard.check(request(host: nil), token: token), .forbidden)
        XCTAssertEqual(LocalAPIGuard.check(request(host: "127.0.0.1.evil.com"), token: token), .forbidden)
    }
}
