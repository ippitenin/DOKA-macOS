import XCTest
@testable import DOKA

/// Решение до приёма тела загрузки (`OpenAIPreflight`) и ответы в формате
/// OpenAI (`OpenAIResponses`, `OpenAIError`).
@MainActor
final class OpenAIPreflightTests: XCTestCase {
    private func inputs(permission: Bool = true, busy: Bool = false,
                        type: String? = "multipart/form-data; boundary=abc",
                        length: Int = 1_000, free: Int64? = 100_000_000_000) -> OpenAIPreflight.Inputs {
        .init(permissionOn: permission, busy: busy, contentType: type, contentLength: length, freeDiskBytes: free)
    }

    private func status(_ decision: OpenAIPreflight.Decision) -> Int? {
        if case .reject(let error) = decision { return error.status }
        return nil
    }

    func testAcceptsNormalUpload() {
        XCTAssertEqual(OpenAIPreflight.decide(inputs()), .accept(boundary: "abc"))
    }

    /// Каждый отказ — до приёма тела, по порядку важности.
    func testRejections() {
        XCTAssertEqual(status(OpenAIPreflight.decide(inputs(permission: false))), 403)
        XCTAssertEqual(status(OpenAIPreflight.decide(inputs(busy: true))), 429)
        XCTAssertEqual(status(OpenAIPreflight.decide(inputs(type: "application/json"))), 415)
        XCTAssertEqual(status(OpenAIPreflight.decide(inputs(type: nil))), 415)
        XCTAssertEqual(status(OpenAIPreflight.decide(inputs(length: 0))), 400)
        XCTAssertEqual(status(OpenAIPreflight.decide(inputs(length: OpenAIPreflight.maxUploadBytes + 1))), 413)
        XCTAssertEqual(status(OpenAIPreflight.decide(inputs(length: 500_000_000, free: 1_500_000_000))), 507)
        // Свободное место неизвестно — не блокируем.
        XCTAssertEqual(OpenAIPreflight.decide(inputs(free: nil)), .accept(boundary: "abc"))
    }

    /// Выключенное разрешение главнее занятости: программа узнаёт, где включить.
    func testPermissionMessageNamesToggle() {
        guard case .reject(let error) = OpenAIPreflight.decide(inputs(permission: false, busy: true)) else {
            return XCTFail("ожидался отказ")
        }
        XCTAssertEqual(error.message, AgentPermission.openAIAPI.denialMessage)
        XCTAssertFalse(AgentPermission.openAIAPI.isOnByDefault)
    }

    func testErrorShapeMatchesOpenAI() throws {
        let response = OpenAIError.invalid("bad", param: "file").response
        XCTAssertEqual(response.status, 400)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        let error = try XCTUnwrap(object["error"] as? [String: Any])
        XCTAssertEqual(error["message"] as? String, "bad")
        XCTAssertEqual(error["type"] as? String, "invalid_request_error")
        XCTAssertEqual(error["param"] as? String, "file")
        XCTAssertNotNil(error["code"])
    }

    private let result = TranscriptResult(
        fullText: "Привет. Как дела?", language: "ru", duration: 3.5,
        segments: [TranscriptSegment(speaker: nil, start: 0, end: 1.5, text: "Привет."),
                   TranscriptSegment(speaker: nil, start: 1.5, end: 3.5, text: "Как дела?")],
        rawSegments: [], words: [TranscriptWord(text: "Привет.", start: 0, end: 1.5)], llmOutput: nil)

    func testResponseFormats() throws {
        let json = OpenAIResponses.transcription(result, format: "json", includeWords: false)
        let jsonObject = try XCTUnwrap(JSONSerialization.jsonObject(with: json.body) as? [String: Any])
        XCTAssertEqual(jsonObject["text"] as? String, TranscriptFormatter.plainText(result))

        let text = OpenAIResponses.transcription(result, format: "text", includeWords: false)
        XCTAssertTrue(text.headers["Content-Type"]?.hasPrefix("text/plain") == true)
        XCTAssertEqual(String(data: text.body, encoding: .utf8), TranscriptFormatter.plainText(result))

        let verbose = OpenAIResponses.transcription(result, format: "verbose_json", includeWords: true)
        let verboseObject = try XCTUnwrap(JSONSerialization.jsonObject(with: verbose.body) as? [String: Any])
        XCTAssertEqual(verboseObject["task"] as? String, "transcribe")
        XCTAssertEqual((verboseObject["segments"] as? [[String: Any]])?.count, 2)
        XCTAssertEqual((verboseObject["words"] as? [[String: Any]])?.first?["word"] as? String, "Привет.")
        let noWords = OpenAIResponses.transcription(result, format: "verbose_json", includeWords: false)
        XCTAssertNil((try JSONSerialization.jsonObject(with: noWords.body) as? [String: Any])?["words"])

        let srt = OpenAIResponses.transcription(result, format: "srt", includeWords: false)
        XCTAssertEqual(String(data: srt.body, encoding: .utf8), TranscriptFormatter.srt(result))
        let vtt = OpenAIResponses.transcription(result, format: "vtt", includeWords: false)
        XCTAssertEqual(vtt.headers["Content-Type"], "text/vtt; charset=utf-8")
    }

    func testFileExtensionMapping() {
        XCTAssertEqual(OpenAITranscriptionAPI.fileExtension(fileName: "a.MPGA", contentType: nil), "mp3")
        XCTAssertEqual(OpenAITranscriptionAPI.fileExtension(fileName: "a.m4a", contentType: "audio/wav"), "m4a")
        XCTAssertEqual(OpenAITranscriptionAPI.fileExtension(fileName: "blob", contentType: "audio/wav; codecs=1"), "wav")
        XCTAssertEqual(OpenAITranscriptionAPI.fileExtension(fileName: nil, contentType: "audio/mpeg"), "mp3")
        XCTAssertNil(OpenAITranscriptionAPI.fileExtension(fileName: nil, contentType: "audio/webm"))
        // webm есть в OpenAI, но не в белом списке DOKA — API ответит 400.
        XCTAssertFalse(FileTranscriptionController.allExtensions.contains("webm"))
    }
}
