import XCTest
@testable import DOKA

/// Разбор HTTP-запроса локального сервера агентов (`HTTPRequestParser`) и
/// сборка ответа (`HTTPResponse.serialized`).
final class HTTPRequestParserTests: XCTestCase {
    private func raw(_ text: String) -> Data { Data(text.utf8) }

    func testFullPostIsParsedWithLowercasedHeaders() {
        let body = #"{"jsonrpc":"2.0"}"#
        let outcome = HTTPRequestParser.parse(raw(
            "POST /mcp?x=1 HTTP/1.1\r\nHost: 127.0.0.1:47800\r\nContent-Type: application/json\r\n"
            + "Content-Length: \(body.utf8.count)\r\n\r\n\(body)"))
        guard case .request(let request) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/mcp")
        XCTAssertEqual(request.header("HOST"), "127.0.0.1:47800")
        XCTAssertEqual(String(data: request.body, encoding: .utf8), body)
    }

    /// Байты приходят кусками: пока нет конца заголовков или всего тела — ждать.
    func testPartialRequestIsIncomplete() {
        XCTAssertEqual(HTTPRequestParser.parse(raw("POST /mcp HTTP/1.1\r\nHost: localhost")), .incomplete)
        XCTAssertEqual(HTTPRequestParser.parse(raw(
            "POST /mcp HTTP/1.1\r\nHost: localhost\r\nContent-Length: 10\r\n\r\n12345")), .incomplete)
    }

    func testGetWithoutBodyIsComplete() {
        guard case .request(let request) = HTTPRequestParser.parse(raw("GET /mcp HTTP/1.1\r\nHost: localhost\r\n\r\n")) else {
            return XCTFail("GET без тела должен разбираться")
        }
        XCTAssertEqual(request.method, "GET")
        XCTAssertTrue(request.body.isEmpty)
    }

    func testPostWithoutLengthIsRejected() {
        XCTAssertEqual(HTTPRequestParser.parse(raw("POST /mcp HTTP/1.1\r\nHost: localhost\r\n\r\n")),
                       .failure(status: 411))
    }

    func testChunkedIsNotSupported() {
        XCTAssertEqual(HTTPRequestParser.parse(raw(
            "POST /mcp HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n")), .failure(status: 501))
    }

    func testOversizedBodyAndHeadersAreRejected() {
        let tooBig = HTTPRequestParser.maxBodyBytes + 1
        XCTAssertEqual(HTTPRequestParser.parse(raw(
            "POST /mcp HTTP/1.1\r\nHost: localhost\r\nContent-Length: \(tooBig)\r\n\r\n")), .failure(status: 413))
        let longHeader = "GET / HTTP/1.1\r\nX: " + String(repeating: "a", count: HTTPRequestParser.maxHeaderBytes + 10)
        XCTAssertEqual(HTTPRequestParser.parse(raw(longHeader)), .failure(status: 431))
    }

    func testGarbageIsBadRequest() {
        XCTAssertEqual(HTTPRequestParser.parse(raw("hello\r\n\r\n")), .failure(status: 400))
        XCTAssertEqual(HTTPRequestParser.parse(raw("GET / HTTP/1.1\r\nno colon here\r\n\r\n")), .failure(status: 400))
        XCTAssertEqual(HTTPRequestParser.parse(raw(
            "POST / HTTP/1.1\r\nContent-Length: -5\r\n\r\n")), .failure(status: 400))
    }

    /// Заголовки разбираются без тела: решение «пускать или нет» принимается
    /// до того, как программа зальёт гигабайт.
    func testHeadIsAvailableBeforeBody() {
        let raw = raw("POST /v1/audio/transcriptions HTTP/1.1\r\nHost: localhost\r\nContent-Length: 900000000\r\n\r\nabc")
        guard case .head(let head) = HTTPRequestParser.parseHead(raw) else { return XCTFail("заголовки должны разбираться") }
        XCTAssertEqual(head.contentLength, 900_000_000)
        XCTAssertEqual(head.path, "/v1/audio/transcriptions")
        XCTAssertEqual(raw.count - head.headerLength, 3)
        // Целиком в память такой запрос не берётся.
        XCTAssertEqual(HTTPRequestParser.parse(raw), .failure(status: 413))
    }

    /// Два заголовка, от которых зависит решение, — отказ (подделка длины,
    /// хоста или токена).
    func testDuplicateSecurityHeadersAreRejected() {
        for name in ["Content-Length: 1", "Host: evil.com", "Authorization: Bearer x", "Origin: http://a"] {
            let request = "POST /mcp HTTP/1.1\r\nHost: localhost\r\nContent-Length: 1\r\nAuthorization: Bearer y\r\nOrigin: http://localhost\r\n\(name)\r\n\r\nx"
            XCTAssertEqual(HTTPRequestParser.parseHead(raw(request)), .failure(status: 400), name)
        }
        XCTAssertEqual(HTTPRequestParser.parseHead(raw("POST / HTTP/1.1\r\nContent-Length: +5\r\n\r\n")), .failure(status: 400))
    }

    func testResponseCarriesLengthAndClosesConnection() throws {
        let data = HTTPResponse.json(Data("{}".utf8)).serialized()
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 200 OK\r\n"))
        XCTAssertTrue(text.contains("Content-Length: 2\r\n"))
        XCTAssertTrue(text.contains("Connection: close\r\n"))
        XCTAssertTrue(text.hasSuffix("\r\n\r\n{}"))
    }
}
