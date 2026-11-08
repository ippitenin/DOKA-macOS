import Foundation

/// OpenAI-совместимый `POST /v1/audio/transcriptions` для любых программ
/// (как локальный сервер TypeWhisper): программа присылает звук — получает
/// текст. Распознаёт активный сервис DOKA; программа его не выбирает.
///
/// Решение владельца 8.11.2026: НИЧЕГО не сохраняется — ни библиотека, ни
/// история, ни статистика, ни архив звука. Временные файлы — в приватной
/// папке `TMPDIR/doka-api-<uuid>` (0700) и удаляются при любом исходе; префикс
/// `doka-` закрыт для MCP `transcribe_file` (`AgentPathPolicy`).
///
/// Одна загрузка/распознавание за раз (`isBusy`): занятость проверяется ДО
/// приёма тела, иначе параллельные загрузки по гигабайту забили бы диск.
@MainActor
final class OpenAITranscriptionAPI {
    static let shared = OpenAITranscriptionAPI()

    nonisolated static let tempPrefix = "doka-api-"

    /// Принята загрузка или идёт распознавание.
    private(set) var isBusy = false
    /// Идёт локальное распознавание — модель занята (страница, библиотека и
    /// ИИ-анализ сверяются с этим флагом, как с `runningUsesLocalEngine`).
    private(set) var isRunningLocal = false
    private var workDirectory: URL?

    private init() {}

    // MARK: - До приёма тела

    func preflight(_ head: HTTPHead, permissionOn: Bool) -> LocalAPIServer.Decision {
        let decision = OpenAIPreflight.decide(.init(
            permissionOn: permissionOn,
            busy: isBusy,
            contentType: head.header("content-type"),
            contentLength: head.contentLength,
            freeDiskBytes: Self.freeDiskBytes()))
        switch decision {
        case .reject(let error):
            return .reject(error.response)
        case .accept:
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(Self.tempPrefix + UUID().uuidString, isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                        attributes: [.posixPermissions: 0o700])
            } catch {
                return .reject(OpenAIError(status: 500, type: "server_error", code: "temp_dir",
                                           message: "Could not create a temporary folder").response)
            }
            isBusy = true
            workDirectory = directory
            return .accept(.file(directory.appendingPathComponent("body")), onAbort: {
                Task { @MainActor in OpenAITranscriptionAPI.shared.release() }
            })
        }
    }

    /// Освободить: снять занятость и стереть временную папку.
    func release() {
        isBusy = false
        if let directory = workDirectory {
            try? FileManager.default.removeItem(at: directory)
        }
        workDirectory = nil
    }

    /// Забытые после аварийного выхода папки загрузок — стереть (на старте).
    nonisolated static func sweepLeftovers() {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory
        guard let items = try? fm.contentsOfDirectory(at: temp, includingPropertiesForKeys: nil) else { return }
        for item in items where item.lastPathComponent.hasPrefix(tempPrefix) {
            try? fm.removeItem(at: item)
        }
    }

    private static func freeDiskBytes() -> Int64? {
        let values = try? FileManager.default.temporaryDirectory
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    // MARK: - Запрос

    func handle(_ request: HTTPRequest) async -> (HTTPResponse, AgentActivityLog.Outcome) {
        defer { release() }
        do {
            let response = try await transcribeUpload(request)
            return (response, .done)
        } catch let error as OpenAIError {
            return (error.response, error.status == 403 ? .denied : .failed)
        } catch {
            let wrapped = OpenAIError(status: 500, type: "server_error", code: "transcription_failed",
                                      message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            return (wrapped.response, .failed)
        }
    }

    private func transcribeUpload(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard let bodyURL = request.bodyFile, let directory = workDirectory,
              let boundary = MultipartFormData.boundary(fromContentType: request.header("content-type")) else {
            throw OpenAIError.invalid("Expected a multipart/form-data upload")
        }
        // Тело — отображением в память: гигабайт не копируется.
        let body = try Data(contentsOf: bodyURL, options: .alwaysMapped)
        let form: MultipartFormData.Form
        do {
            form = try MultipartFormData.parse(body, boundary: boundary)
        } catch {
            throw OpenAIError.invalid("Malformed multipart body: \(error)")
        }
        guard let file = form.file, !file.range.isEmpty else {
            throw OpenAIError.invalid("Missing the audio file in the 'file' field", param: "file")
        }
        let format = form.field("response_format") ?? "json"
        guard OpenAIResponses.formats.contains(format) else {
            throw OpenAIError.invalid("response_format must be one of: \(OpenAIResponses.formats.joined(separator: ", "))",
                                      param: "response_format")
        }
        let language = form.field("language").flatMap { $0.isEmpty ? nil : $0.lowercased() } ?? "auto"
        guard TranscriptionLanguage.all.contains(where: { $0.id == language }) else {
            throw OpenAIError.invalid("Unsupported language '\(language)'", param: "language")
        }
        guard let ext = Self.fileExtension(fileName: file.fileName, contentType: file.contentType),
              FileTranscriptionController.allExtensions.contains(ext) else {
            throw OpenAIError(status: 400, type: "invalid_request_error", code: "unsupported_format",
                              message: L("agent.api.badFormat", FileTranscriptionController.allExtensions.joined(separator: ", ")),
                              param: "file")
        }
        let granularities = (form.fields["timestamp_granularities[]"] ?? []) + (form.fields["timestamp_granularities"] ?? [])

        // Вырезать файл кусками по 4 МБ и сразу отпустить тело.
        let audioURL = directory.appendingPathComponent("audio.\(ext)")
        guard FileManager.default.createFile(atPath: audioURL.path, contents: nil,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw OpenAIError(status: 500, type: "server_error", code: "temp_file", message: "Could not write a temporary file")
        }
        let output = try FileHandle(forWritingTo: audioURL)
        var offset = file.range.lowerBound
        let chunk = 4 * 1024 * 1024
        while offset < file.range.upperBound {
            let next = min(offset + chunk, file.range.upperBound)
            try output.write(contentsOf: body[(body.startIndex + offset)..<(body.startIndex + next)])
            offset = next
        }
        try output.close()
        try? FileManager.default.removeItem(at: bodyURL)

        let result = try await transcribe(audioURL, language: language)
        // Детальные форматы режутся по предложениям, как «Сохранить как…»;
        // правки и словарь — тот же выходной слой, что у страницы.
        let shaped = ["json", "text"].contains(format) ? result : result.withDetail(.medium)
        let prepared = TranscriptOutput.prepare(shaped)
        return OpenAIResponses.transcription(prepared, format: format, includeWords: granularities.contains("word"))
    }

    /// Распознать активным сервисом без библиотеки. Гейты локальной модели —
    /// общие со страницей (`FileTranscriptionController.localStartRefusal`).
    private func transcribe(_ url: URL, language: String) async throws -> TranscriptResult {
        let settings = SettingsStore.shared
        let providerID = settings.providerID
        let route: ServiceRoute
        do {
            route = try settings.resolveRoute(providerID: providerID)
        } catch {
            throw OpenAIError(status: 503, type: "server_error", code: "service_not_ready",
                              message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
        if let refusal = FileTranscriptionController.localStartRefusal(route: route) {
            throw OpenAIError(status: 503, type: "server_error", code: "engine_busy", message: refusal)
        }
        let params = FileTranscriptionParams(
            providerID: providerID, language: language, diarize: false, numSpeakers: nil,
            diarizationSetting: DiarizationSetting.general.rawValue, rolesMode: RolesMode.off.rawValue,
            rolesText: "", llmPreset: LLMAnalysisPreset.off.rawValue, llmCustomPrompt: "", llmLocal: true)
        let options = params.makeOptions(detail: .server)
        switch route {
        case .local(let model):
            let engines = LocalEngineManager.shared
            isRunningLocal = true
            engines.beginSpeechUse(.fileSpeech)
            defer {
                engines.endSpeechUse(.fileSpeech)
                isRunningLocal = false
            }
            async let engineLoading = engines.engine(for: model)
            let decoded = try await AudioFileDecoder.decodeToWav(url)
            defer { try? FileManager.default.removeItem(at: decoded.url) }
            let engine = try await engineLoading
            let local = try await engine.transcribeFile(wavURL: decoded.url, language: options.language)
            engines.touch()
            return TranscriptResult(fullText: local.fullText,
                                    language: local.language ?? options.language,
                                    duration: decoded.duration,
                                    segments: local.segments,
                                    rawSegments: local.segments,
                                    words: local.words,
                                    llmOutput: nil)
        case .remote(let apiKey, let config):
            return try await FileTranscriptionClient().transcribeRich(fileURL: url, options: options,
                                                                      apiKey: apiKey, config: config)
        }
    }

    /// Расширение по имени файла или по `Content-Type` части. Синонимы OpenAI
    /// (`mpga`, `mpeg`) — к нашему белому списку.
    nonisolated static func fileExtension(fileName: String?, contentType: String?) -> String? {
        if let name = fileName {
            let ext = (name as NSString).pathExtension.lowercased()
            if !ext.isEmpty {
                switch ext {
                case "mpga", "mpeg": return "mp3"
                case "aif": return "aiff"
                default: return ext
                }
            }
        }
        let type = contentType?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased()
        switch type {
        case "audio/mpeg", "audio/mp3", "audio/mpga": return "mp3"
        case "audio/wav", "audio/x-wav", "audio/wave", "audio/vnd.wave": return "wav"
        case "audio/mp4", "audio/m4a", "audio/x-m4a": return "m4a"
        case "audio/flac", "audio/x-flac": return "flac"
        case "audio/ogg": return "ogg"
        case "audio/opus": return "opus"
        case "audio/aiff", "audio/x-aiff": return "aiff"
        case "video/mp4": return "mp4"
        case "video/quicktime": return "mov"
        default: return nil
        }
    }
}
