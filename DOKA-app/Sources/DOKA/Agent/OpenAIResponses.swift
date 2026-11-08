import Foundation

/// Решение до приёма тела загрузки `POST /v1/audio/transcriptions`. Чистая
/// функция: всё, что можно отказать, отказывается до того, как программа
/// залила хоть байт, — и диск не забить параллельными загрузками.
enum OpenAIPreflight {
    /// Звук до 1 ГБ: программы шлют фразы и записи встреч, а не архивы.
    static let maxUploadBytes = 1_000_000_000
    /// Сверх двойного размера загрузки (тело + вырезанный файл) на диске
    /// должно оставаться столько.
    static let diskReserveBytes: Int64 = 1_000_000_000

    struct Inputs {
        var permissionOn: Bool
        var busy: Bool
        var contentType: String?
        var contentLength: Int
        var freeDiskBytes: Int64?
    }

    enum Decision: Equatable {
        case accept(boundary: String)
        case reject(OpenAIError)
    }

    static func decide(_ inputs: Inputs) -> Decision {
        guard inputs.permissionOn else {
            return .reject(OpenAIError(status: 403, type: "permission_error", code: "api_disabled",
                                       message: AgentPermission.openAIAPI.denialMessage))
        }
        guard !inputs.busy else {
            return .reject(OpenAIError(status: 429, type: "rate_limit_error", code: "busy",
                                       message: L("agent.api.busy")))
        }
        guard let boundary = MultipartFormData.boundary(fromContentType: inputs.contentType) else {
            return .reject(OpenAIError(status: 415, type: "invalid_request_error", code: "unsupported_media_type",
                                       message: "Content-Type must be multipart/form-data with a boundary"))
        }
        guard inputs.contentLength > 0 else {
            return .reject(OpenAIError(status: 400, type: "invalid_request_error", code: "empty_body",
                                       message: "Request body is empty"))
        }
        guard inputs.contentLength <= maxUploadBytes else {
            return .reject(OpenAIError(status: 413, type: "invalid_request_error", code: "file_too_large",
                                       message: L("agent.api.tooLarge")))
        }
        let needed = Int64(inputs.contentLength) * 2 + diskReserveBytes
        if let free = inputs.freeDiskBytes, free < needed {
            return .reject(OpenAIError(status: 507, type: "server_error", code: "insufficient_storage",
                                       message: L("agent.api.noSpace")))
        }
        return .accept(boundary: boundary)
    }
}

/// Ошибка в формате OpenAI: `{"error": {"message", "type", "param", "code"}}`.
struct OpenAIError: Error, Equatable {
    let status: Int
    let type: String
    let code: String
    let message: String
    var param: String? = nil

    var response: HTTPResponse {
        var error: [String: Any] = ["message": message, "type": type, "code": code]
        error["param"] = param ?? NSNull()
        return OpenAIResponses.jsonResponse(["error": error], status: status)
    }

    static func invalid(_ message: String, param: String? = nil) -> OpenAIError {
        OpenAIError(status: 400, type: "invalid_request_error", code: "invalid_request", message: message, param: param)
    }
}

/// Тела ответов `POST /v1/audio/transcriptions` по `response_format`.
enum OpenAIResponses {
    static let formats = ["json", "text", "verbose_json", "srt", "vtt"]

    static func transcription(_ result: TranscriptResult, format: String, includeWords: Bool) -> HTTPResponse {
        let text = TranscriptFormatter.plainText(result)
        switch format {
        case "text":
            return .text(text, status: 200)
        case "srt":
            return .text(TranscriptFormatter.srt(result), status: 200)
        case "vtt":
            var response = HTTPResponse.text(TranscriptFormatter.vtt(result), status: 200)
            response.headers["Content-Type"] = "text/vtt; charset=utf-8"
            return response
        case "verbose_json":
            var object: [String: Any] = [
                "task": "transcribe",
                "language": result.language ?? NSNull(),
                "duration": result.duration ?? NSNull(),
                "text": text,
                "segments": result.segments.enumerated().map { index, segment -> [String: Any] in
                    ["id": index, "seek": 0, "start": segment.start, "end": segment.end, "text": segment.text]
                }
            ]
            if includeWords {
                object["words"] = result.words.map { ["word": $0.text, "start": $0.start, "end": $0.end] }
            }
            return jsonResponse(object, status: 200)
        default:
            return jsonResponse(["text": text], status: 200)
        }
    }

    static func models(serviceTitle: String) -> HTTPResponse {
        jsonResponse(["object": "list", "data": [[
            "id": "doka", "object": "model", "created": 0, "owned_by": "doka",
            "description": "Transcribes with the service selected in DOKA: \(serviceTitle)"
        ] as [String: Any]]], status: 200)
    }

    static func jsonResponse(_ object: Any, status: Int) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]))
            ?? Data(#"{"error":{"message":"internal error","type":"server_error","code":"internal","param":null}}"#.utf8)
        return HTTPResponse.json(data, status: status)
    }
}
