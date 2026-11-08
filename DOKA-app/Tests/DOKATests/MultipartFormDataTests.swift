import XCTest
@testable import DOKA

/// Разбор загрузки OpenAI Audio API (`MultipartFormData`).
final class MultipartFormDataTests: XCTestCase {
    private let boundary = "----DokaTest123"

    private func body(_ parts: [(headers: String, content: Data)], preamble: String = "") -> Data {
        var data = Data(preamble.utf8)
        for part in parts {
            data.append(Data("--\(boundary)\r\n\(part.headers)\r\n\r\n".utf8))
            data.append(part.content)
            data.append(Data("\r\n".utf8))
        }
        data.append(Data("--\(boundary)--\r\n".utf8))
        return data
    }

    private func field(_ name: String, _ value: String) -> (headers: String, content: Data) {
        ("Content-Disposition: form-data; name=\"\(name)\"", Data(value.utf8))
    }

    func testFieldsAndFileAreParsed() throws {
        let audio = Data([0x00, 0x0D, 0x0A, 0x2D, 0x2D, 0xFF])  // CRLF и «--» внутри файла
        let data = body([
            field("model", "whisper-1"),
            ("Content-Disposition: form-data; name=\"file\"; filename=\"встреча 1.m4a\"\r\nContent-Type: audio/mp4", audio),
            field("timestamp_granularities[]", "word"),
            field("timestamp_granularities[]", "segment")
        ], preamble: "ignored preamble\r\n")
        let form = try MultipartFormData.parse(data, boundary: boundary)
        XCTAssertEqual(form.field("model"), "whisper-1")
        XCTAssertEqual(form.fields["timestamp_granularities[]"], ["word", "segment"])
        let file = try XCTUnwrap(form.file)
        XCTAssertEqual(file.fileName, "встреча 1.m4a")
        XCTAssertEqual(file.contentType, "audio/mp4")
        XCTAssertEqual(data.subdata(in: file.range), audio)
    }

    func testBoundaryFromContentType() {
        XCTAssertEqual(MultipartFormData.boundary(fromContentType: "multipart/form-data; boundary=abc"), "abc")
        XCTAssertEqual(MultipartFormData.boundary(fromContentType: "Multipart/Form-Data; charset=utf-8; boundary=\"a b\""), "a b")
        XCTAssertNil(MultipartFormData.boundary(fromContentType: "application/json"))
        XCTAssertNil(MultipartFormData.boundary(fromContentType: "multipart/form-data"))
        XCTAssertNil(MultipartFormData.boundary(fromContentType: "multipart/form-data; boundary=" + String(repeating: "x", count: 71)))
        XCTAssertNil(MultipartFormData.boundary(fromContentType: nil))
    }

    func testMissingFileIsNotAnError() throws {
        let form = try MultipartFormData.parse(body([field("model", "x")]), boundary: boundary)
        XCTAssertNil(form.file)
    }

    func testTwoFilesAreRejected() {
        let file = ("Content-Disposition: form-data; name=\"file\"; filename=\"a.mp3\"", Data("a".utf8))
        XCTAssertThrowsError(try MultipartFormData.parse(body([file, file]), boundary: boundary)) {
            XCTAssertEqual($0 as? MultipartFormData.ParseError, .duplicateFile)
        }
    }

    func testOtherFileFieldsAreSkipped() throws {
        let other = ("Content-Disposition: form-data; name=\"avatar\"; filename=\"me.png\"", Data("png".utf8))
        let form = try MultipartFormData.parse(body([other, field("model", "x")]), boundary: boundary)
        XCTAssertNil(form.file)
        XCTAssertEqual(form.field("model"), "x")
    }

    func testLimits() {
        let hugeHeader = ("Content-Disposition: form-data; name=\"x\"\r\nX-Pad: " + String(repeating: "a", count: 20_000), Data("v".utf8))
        XCTAssertThrowsError(try MultipartFormData.parse(body([hugeHeader]), boundary: boundary))

        let bigField = field("prompt", String(repeating: "a", count: MultipartFormData.maxFieldBytes + 1))
        XCTAssertThrowsError(try MultipartFormData.parse(body([bigField]), boundary: boundary)) {
            XCTAssertEqual($0 as? MultipartFormData.ParseError, .fieldTooLarge("prompt"))
        }

        let many = (0...MultipartFormData.maxParts).map { field("f\($0)", "v") }
        XCTAssertThrowsError(try MultipartFormData.parse(body(many), boundary: boundary)) {
            XCTAssertEqual($0 as? MultipartFormData.ParseError, .tooManyParts)
        }
    }

    func testMalformedBodies() {
        XCTAssertThrowsError(try MultipartFormData.parse(Data("no boundary here".utf8), boundary: boundary))
        // Часть без закрывающей границы.
        let open = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"a\"\r\n\r\nvalue".utf8)
        XCTAssertThrowsError(try MultipartFormData.parse(open, boundary: boundary))
        // Часть без имени.
        XCTAssertThrowsError(try MultipartFormData.parse(body([("Content-Disposition: form-data", Data("v".utf8))]),
                                                         boundary: boundary))
    }

    func testDispositionParameters() {
        let header = #"form-data; name="file"; filename="say \"hi\".mp3""#
        XCTAssertEqual(MultipartFormData.parameter("name", in: header), "file")
        XCTAssertEqual(MultipartFormData.parameter("filename", in: header), #"say "hi".mp3"#)
    }
}
