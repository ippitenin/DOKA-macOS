import Foundation
import UniformTypeIdentifiers

/// Сегмент транскрипции: фрагмент текста с тайм-кодами. `speaker` заполняется
/// только в режиме диаризации (task=diarize), иначе nil.
/// Codable — записи «Недавних транскрибаций» хранят сегменты на диске.
struct TranscriptSegment: Equatable, Codable {
    let speaker: String?
    let start: Double       // секунды
    let end: Double
    let text: String
}

/// Слово с тайм-кодами (`timestamp_granularities[]=word`). Нужны сплиттеру
/// длинных сегментов (`TranscriptSegmentSplitter`) и хранятся в
/// `TranscriptResult` — смена детализации перенарезает готовый результат
/// локально, без повторного запроса.
/// Codable — записи «Недавних транскрибаций» хранят слова на диске.
struct TranscriptWord: Equatable, Codable {
    let text: String
    let start: Double       // секунды
    let end: Double
}

/// Результат файловой транскрипции: полный текст + сегменты с тайм-кодами.
/// Из него локально строятся все форматы копирования (см. `TranscriptFormatter`).
struct TranscriptResult: Equatable {
    let fullText: String
    let language: String?
    let duration: Double?
    /// Отображаемые сегменты: `rawSegments` после локальной нарезки.
    let segments: [TranscriptSegment]
    /// Сегменты, как их отдал сервер — источник для перенарезки.
    let rawSegments: [TranscriptSegment]
    /// Пословные тайм-коды — материал перенарезки при смене детализации.
    let words: [TranscriptWord]
    /// Результат LLM-анализа (запрос с `prompt`); nil — анализ не запрашивался
    /// или сервер его не вернул.
    let llmOutput: String?
    /// Пользовательские правки, применённые к `segments` (см. `TranscriptEdits`).
    /// `var` с дефолтом — все прежние вызовы memberwise-init остаются как есть.
    var edits = TranscriptEdits()

    /// Есть ли разметка по спикерам (доступен формат «со спикерами»).
    var hasSpeakers: Bool { segments.contains { ($0.speaker?.isEmpty == false) } }

    /// Локальная перенарезка под другой уровень детализации: всегда от
    /// `rawSegments` (идемпотентна), без повторного запроса к API. Правки
    /// результата переносятся — они привязаны к исходникам, а не к нарезке.
    func withDetail(_ detail: TimestampDetail) -> TranscriptResult {
        withEdits(edits, detail: detail)
    }
}

/// Тип записи для диаризации (`diarization_setting`): подсказывает серверу
/// характер аудио и помогает точнее разделять говорящих. Ровно два значения —
/// из документации Nexara (DOCS/NEXARA/GUIDES/diarization.md): `general`
/// (дефолт, выше точность для всего, кроме телефонии) и `telephonic` (звонки
/// и записи с частыми перебиваниями, рекомендован и для Zoom). Значения
/// `meeting` в доке НЕТ — не добавлять.
enum DiarizationSetting: String, CaseIterable, Identifiable {
    case general, telephonic

    var id: String { rawValue }
    var title: String { L("transcribe.diarizeSetting.\(rawValue)") }
}

/// Разметка ролей (`roles`, только с task=diarize): вместо «speaker_N»
/// сервер подписывает говорящих осмысленными ролями.
enum RolesSpec: Equatable {
    case none                   // без разметки, метки speaker_N
    case auto                   // роли подбираются по содержанию разговора
    case custom([String])       // свой список имён (валидирует SpeakerRolesParser)
}

/// Параметры файловой транскрипции.
struct FileTranscriptionOptions {
    let language: String?   // nil — автоопределение
    let diarize: Bool       // task=diarize: разделение по спикерам
    /// Подсказка о числе говорящих (`num_speakers`): повышает качество
    /// диаризации, точное число не гарантирует. nil — авто, поле не отправляется.
    var numSpeakers: Int? = nil
    /// Тип записи. Дефолт `general` не отправляется.
    var diarizationSetting: DiarizationSetting = .general
    /// Разметка ролей. Дефолт `.none` не отправляется.
    var roles: RolesSpec = .none
    /// Инструкция LLM-анализа (`prompt`): само наличие включает анализ, ответ
    /// приходит конвертом `{transcription, llm_output}`. ТОЛЬКО для Nexara:
    /// у OpenAI-совместимых API prompt — контекстная подсказка Whisper
    /// (гейт держит контроллер).
    var llmPrompt: String? = nil
    /// Уровень детализации тайм-кодов — чисто локальная нарезка,
    /// в запрос не попадает.
    var timestampDetail: TimestampDetail = .medium
}

/// Клиент транскрипции ЗАГРУЖЕННОГО файла (отдельно от боевой диктовки).
/// В отличие от `TranscriptionClient` (который шлёт `response_format=json` и
/// возвращает голый текст), запрашивает `verbose_json` с тайм-кодами по
/// сегментам и умеет режим диаризации. Боевой путь диктовки не трогаем.
struct FileTranscriptionClient {
    enum FileTranscriptionError: LocalizedError {
        case invalidKey          // 401
        case noFunds             // 402
        case rateLimited         // 429
        case server(Int)
        case badResponse         // 2xx, но тело не разобрать
        case network(Error)
        case emptyText
        case readFailed          // файл не прочитать с диска
        case jobNotFound         // 404 при опросе: задача не найдена или результат истёк (12 ч)
        case jobFailed(String)   // async-задача завершилась на сервере со status=error

        var errorDescription: String? {
            switch self {
            case .invalidKey: return L("error.invalidKey")
            case .noFunds: return L("error.noFunds")
            case .rateLimited: return L("error.rateLimited")
            case .server(let code): return L("error.server", code)
            case .badResponse: return L("error.badResponse")
            case .network: return L("error.network")
            case .emptyText: return L("error.emptyText")
            case .readFailed: return L("transcribe.error.readFailed")
            case .jobNotFound: return L("transcribe.async.jobNotFound")
            case .jobFailed(let message): return L("transcribe.async.jobFailed", message)
            }
        }
    }

    /// Итог одного опроса async-задачи Nexara.
    enum AsyncJobPoll: Equatable {
        case inProgress
        case complete(TranscriptResult)
        case failed(String)      // серверный status=error, текст поля error
    }

    /// Отдельная сессия с увеличенными таймаутами: файлы крупнее голосовых
    /// записей (до 3 ГБ, часы аудио) — дефолтные 60 с их оборвали бы.
    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 600     // 10 мин ожидания ответа
        cfg.timeoutIntervalForResource = 7200   // 2 ч на всю передачу
        return URLSession(configuration: cfg)
    }()

    /// Транскрибирует файл синхронно: соединение открыто всё время обработки.
    /// language == nil — автоопределение.
    func transcribeRich(fileURL: URL,
                        options: FileTranscriptionOptions,
                        apiKey: String,
                        config: ProviderConfig) async throws -> TranscriptResult {
        let data = try await postMultipart(fileURL: fileURL, options: options,
                                           apiKey: apiKey, endpoint: config.endpoint,
                                           model: config.model)
        return try Self.decode(data, detail: options.timestampDetail)
    }

    // MARK: - Async-режим (Nexara)

    /// Ставит async-задачу: тот же multipart, что transcribeRich, но на
    /// `{endpoint}/async` — ответ приходит сразу, с job_id вместо результата.
    /// Обработка идёт на сервере в фоне; результат забирается опросом
    /// (waitForResult) и хранится там 12 часов.
    func submitAsync(fileURL: URL,
                     options: FileTranscriptionOptions,
                     apiKey: String,
                     config: ProviderConfig) async throws -> String {
        let data = try await postMultipart(fileURL: fileURL, options: options,
                                           apiKey: apiKey,
                                           endpoint: config.endpoint.appendingPathComponent("async"),
                                           model: config.model)
        struct SubmitResponse: Decodable {
            let jobID: String?
            enum CodingKeys: String, CodingKey { case jobID = "job_id" }
        }
        guard let decoded = try? JSONDecoder().decode(SubmitResponse.self, from: data),
              let jobID = decoded.jobID, !jobID.isEmpty else {
            NSLog("DOKA: async-сабмит без job_id: \(Self.rawPreview(data))")
            throw FileTranscriptionError.badResponse
        }
        return jobID
    }

    /// Один опрос статуса async-задачи: GET `{endpoint}/async/{job_id}`.
    /// 404 — задача не найдена или результат истёк (сервер хранит его 12 ч).
    func fetchJobStatus(jobID: String,
                        apiKey: String,
                        config: ProviderConfig,
                        detail: TimestampDetail) async throws -> AsyncJobPoll {
        let url = config.endpoint.appendingPathComponent("async").appendingPathComponent(jobID)
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw FileTranscriptionError.network(error)
        }
        if let http = response as? HTTPURLResponse, http.statusCode == 404 {
            throw FileTranscriptionError.jobNotFound
        }
        try Self.checkHTTP(response, data: data)
        return try Self.decodeAsyncStatus(data, detail: detail)
    }

    /// Опрос async-задачи до результата. Транзиентные сбои (сеть, 429, 5xx)
    /// не валят задачу — интервал растёт 4→8→16→30 с и сбрасывается при
    /// успешном ответе: опрос переживает обрыв сети и сон Mac. Фатальны сразу:
    /// неверный ключ, нет средств, задача не найдена/истекла, серверный
    /// status=error, нераспознаваемый ответ. По истечении deadline (постановка
    /// + 12 ч — срок хранения результата на сервере) — jobNotFound без
    /// запроса. Отмена Task прекращает опрос (Task.sleep бросает
    /// CancellationError).
    func waitForResult(jobID: String,
                       apiKey: String,
                       config: ProviderConfig,
                       detail: TimestampDetail,
                       deadline: Date) async throws -> TranscriptResult {
        var interval: TimeInterval = 4
        while true {
            try Task.checkCancellation()
            guard Date() < deadline else { throw FileTranscriptionError.jobNotFound }
            do {
                switch try await fetchJobStatus(jobID: jobID, apiKey: apiKey,
                                                config: config, detail: detail) {
                case .inProgress:
                    interval = 4
                case .complete(let result):
                    return result
                case .failed(let message):
                    throw FileTranscriptionError.jobFailed(message)
                }
            } catch let error as FileTranscriptionError {
                switch error {
                case .invalidKey, .noFunds, .jobNotFound, .jobFailed, .badResponse, .emptyText, .readFailed:
                    throw error
                case .network, .rateLimited, .server:
                    interval = min(interval * 2, 30)
                }
            }
            try await Task.sleep(for: .seconds(interval))
        }
    }

    /// Общий POST multipart-тела для sync- и async-путей: собирает поля,
    /// пишет тело во временный файл и отправляет потоково
    /// (upload(for:fromFile:)) — склейка тела в Data держала бы в памяти
    /// два размера файла разом, при лимите 3 ГБ это неприемлемо.
    private func postMultipart(fileURL: URL,
                               options: FileTranscriptionOptions,
                               apiKey: String,
                               endpoint: URL,
                               model: String) async throws -> Data {
        let fields = Self.makeFields(options: options, model: model)
        let boundary = "doka-\(UUID().uuidString)"
        let bodyURL: URL
        do {
            bodyURL = try Self.writeMultipartBody(fileURL: fileURL, fields: fields, boundary: boundary)
        } catch {
            throw FileTranscriptionError.readFailed
        }
        defer { try? FileManager.default.removeItem(at: bodyURL) }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.upload(for: request, fromFile: bodyURL)
        } catch {
            throw FileTranscriptionError.network(error)
        }
        try Self.checkHTTP(response, data: data)
        return data
    }

    /// Поля multipart-запроса — общие для sync- и async-эндпоинтов
    /// (async принимает те же параметры, проверено живыми вызовами).
    private static func makeFields(options: FileTranscriptionOptions,
                                   model: String) -> [(name: String, value: String)] {
        var fields: [(name: String, value: String)] = [
            ("model", model),
            ("response_format", "verbose_json"),
            ("task", options.diarize ? "diarize" : "transcribe"),
            // Пословные тайм-коды. В обоих режимах сегменты приходят вместе
            // со словами (проверено живыми запросами), а по словам
            // TranscriptSegmentSplitter локально режет длинные сегменты
            // диаризации (один спикер может говорить минутами).
            ("timestamp_granularities[]", "word")
        ]
        if let language = options.language, language != "auto", !language.isEmpty {
            fields.append(("language", language))
        }
        // Nexara-специфичные параметры качества диаризации: только в режиме
        // diarize и только не-дефолтные значения. Чужим OpenAI-совместимым
        // серверам эти поля неизвестны — гейт по builtin-сервису держит
        // контроллер, клиент лишь не шлёт лишнего.
        if options.diarize {
            if let numSpeakers = options.numSpeakers {
                fields.append(("num_speakers", String(numSpeakers)))
            }
            if options.diarizationSetting != .general {
                fields.append(("diarization_setting", options.diarizationSetting.rawValue))
            }
            switch options.roles {
            case .none:
                break
            case .auto:
                fields.append(("roles", "auto"))
            case .custom(let names):
                // JSON-массив имён: только через JSONEncoder — ручная
                // конкатенация не экранирует кавычки/юникод.
                if let data = try? JSONEncoder().encode(names),
                   let json = String(data: data, encoding: .utf8) {
                    fields.append(("roles", json))
                }
            }
        }
        if let prompt = options.llmPrompt, !prompt.isEmpty {
            fields.append(("prompt", prompt))
        }
        return fields
    }

    /// Маппинг HTTP-статуса на ошибки клиента — общий для всех запросов.
    private static func checkHTTP(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw FileTranscriptionError.server(0)
        }
        switch http.statusCode {
        case 200..<300:
            break
        case 401:
            throw FileTranscriptionError.invalidKey
        case 402:
            throw FileTranscriptionError.noFunds
        case 429:
            throw FileTranscriptionError.rateLimited
        default:
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            NSLog("DOKA: файловая транскрипция HTTP \(http.statusCode): \(bodyText.prefix(500))")
            throw FileTranscriptionError.server(http.statusCode)
        }
    }

    /// Пишет multipart-тело во временный файл: преамбула с полями, содержимое
    /// файла кусками по 1 МБ, эпилог. Потребление памяти не зависит от
    /// размера файла. Временный файл удаляет вызывающий (defer).
    /// Internal (не private) — проверяется scratchpad-harness'ом.
    static func writeMultipartBody(fileURL: URL,
                                   fields: [(name: String, value: String)],
                                   boundary: String) throws -> URL {
        let bodyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("doka-upload-\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: bodyURL.path, contents: nil) else {
            throw FileTranscriptionError.readFailed
        }
        let output = try FileHandle(forWritingTo: bodyURL)
        defer { try? output.close() }

        var head = ""
        for field in fields {
            head += "--\(boundary)\r\n"
            head += "Content-Disposition: form-data; name=\"\(field.name)\"\r\n\r\n"
            head += "\(field.value)\r\n"
        }
        head += "--\(boundary)\r\n"
        head += "Content-Disposition: form-data; name=\"file\"; filename=\"\(fileURL.lastPathComponent)\"\r\n"
        head += "Content-Type: \(mimeType(for: fileURL))\r\n\r\n"
        try output.write(contentsOf: Data(head.utf8))

        let input = try FileHandle(forReadingFrom: fileURL)
        defer { try? input.close() }
        while let chunk = try input.read(upToCount: 1_048_576), !chunk.isEmpty {
            try output.write(contentsOf: chunk)
        }

        try output.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
        return bodyURL
    }

    // MARK: - Декодирование

    /// Универсальная форма: одна структура покрывает и `verbose_json`, и
    /// diarize-JSON (у diarize в сегменте появляется `speaker`). Опираемся на
    /// форму ответа, а не на запрошенный формат — diarize игнорирует
    /// `response_format` и всегда отдаёт свой JSON.
    private struct VerboseResponse: Decodable {
        struct Segment: Decodable {
            let start: Double?
            let end: Double?
            let text: String?
            let speaker: String?
        }
        struct Word: Decodable {
            let word: String?
            let start: Double?
            let end: Double?
        }
        let text: String?
        let language: String?
        let duration: Double?
        let segments: [Segment]?
        let words: [Word]?
    }

    /// Двухшаговый разбор: запрос с `prompt` меняет форму ответа на конверт
    /// `{"transcription": {…verbose_json…}, "llm_output": …}` — тогда
    /// транскрипция достаётся из поддерева. Иначе — прежний плоский путь
    /// (обратная совместимость; кастомные сервисы конверт не отдают).
    /// Internal (не private) — проверяется scratchpad-harness'ом на фикстурах.
    static func decode(_ data: Data, detail: TimestampDetail) throws -> TranscriptResult {
        if let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let transcription = envelope["transcription"] as? [String: Any] {
            let llmOutput = llmOutputString(envelope["llm_output"])
            if llmOutput == nil {
                NSLog("DOKA: файловая транскрипция: анализ запрошен, llm_output пуст: \(Self.rawPreview(data))")
            }
            guard let inner = try? JSONSerialization.data(withJSONObject: transcription) else {
                throw FileTranscriptionError.badResponse
            }
            return try decodeVerbose(inner, detail: detail, llmOutput: llmOutput)
        }
        return try decodeVerbose(data, detail: detail, llmOutput: nil)
    }

    /// Разбор тела опроса async-задачи: конверт `{job_id, status, created_at,
    /// completed_at, result, error}`. При complete поддерево `result` уходит в
    /// существующий decode — тот умеет и плоский verbose_json, и llm-конверт
    /// `{transcription, llm_output}` (async отдаёт те же формы, что sync, —
    /// проверено живыми вызовами). Internal (не private) — проверяется
    /// scratchpad-harness'ом на фикстурах.
    static func decodeAsyncStatus(_ data: Data, detail: TimestampDetail) throws -> AsyncJobPoll {
        guard let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = envelope["status"] as? String else {
            NSLog("DOKA: не удалось разобрать статус async-задачи: \(Self.rawPreview(data))")
            throw FileTranscriptionError.badResponse
        }
        switch status {
        case "in_progress":
            return .inProgress
        case "complete":
            guard let result = envelope["result"],
                  JSONSerialization.isValidJSONObject(result),
                  let inner = try? JSONSerialization.data(withJSONObject: result) else {
                NSLog("DOKA: async-задача complete без result: \(Self.rawPreview(data))")
                throw FileTranscriptionError.badResponse
            }
            return .complete(try decode(inner, detail: detail))
        case "error":
            // Форма поля error не документирована (строка либо объект) —
            // строкификация та же, что у llm_output.
            let message = llmOutputString(envelope["error"]) ?? L("error.badResponse")
            return .failed(message)
        default:
            NSLog("DOKA: неизвестный статус async-задачи «\(status)»: \(Self.rawPreview(data))")
            throw FileTranscriptionError.badResponse
        }
    }

    /// `llm_output`: строка — как есть; объект/массив (режим json_schema) —
    /// обратно в читаемый JSON; пусто или мусор — nil.
    private static func llmOutputString(_ value: Any?) -> String? {
        switch value {
        case let text as String:
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case let object as [String: Any]:
            return prettyJSON(object)
        case let array as [Any]:
            return prettyJSON(array)
        default:
            return nil
        }
    }

    private static func prettyJSON(_ object: Any) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }

    private static func decodeVerbose(_ data: Data,
                                      detail: TimestampDetail,
                                      llmOutput: String?) throws -> TranscriptResult {
        guard let decoded = try? JSONDecoder().decode(VerboseResponse.self, from: data) else {
            NSLog("DOKA: не удалось разобрать ответ файловой транскрипции: \(String(data: data, encoding: .utf8)?.prefix(300) ?? "<бинарные данные>")")
            throw FileTranscriptionError.badResponse
        }

        let segments: [TranscriptSegment] = (decoded.segments ?? []).compactMap { seg in
            let text = (seg.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let speaker = seg.speaker?.trimmingCharacters(in: .whitespaces)
            return TranscriptSegment(
                speaker: (speaker?.isEmpty == false) ? speaker : nil,
                start: seg.start ?? 0,
                end: seg.end ?? 0,
                text: text
            )
        }

        let topText = decoded.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let fullText = topText.isEmpty ? segments.map(\.text).joined(separator: " ") : topText
        guard !fullText.isEmpty else { throw FileTranscriptionError.emptyText }

        // Диагностика деградаций сервера: ответ разобрался, но формой не тот.
        // Без этого сбой Nexara выглядит как «молчаливые» нули в интерфейсе.
        if segments.isEmpty && !topText.isEmpty {
            NSLog("DOKA: файловая транскрипция: ответ без сегментов: \(Self.rawPreview(data))")
        } else if !segments.isEmpty && segments.allSatisfy({ $0.start == 0 && $0.end == 0 }) {
            NSLog("DOKA: файловая транскрипция: сегменты без тайм-кодов: \(Self.rawPreview(data))")
        }

        // Пословные тайм-коды: чистим мусор; по ним withDetail режет длинные
        // сегменты по предложениям. Без words сплиттер вернёт сегменты как есть.
        let words: [TranscriptWord] = (decoded.words ?? []).compactMap { word in
            let text = (word.word ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty,
                  let start = word.start, let end = word.end,
                  start.isFinite, end.isFinite, start >= 0, end >= start else { return nil }
            return TranscriptWord(text: text, start: start, end: end)
        }.sorted { $0.start < $1.start }

        return TranscriptResult(
            fullText: fullText,
            language: decoded.language,
            duration: decoded.duration,
            segments: segments,
            rawSegments: segments,
            words: words,
            llmOutput: llmOutput
        ).withDetail(detail)
    }

    /// Усечённое тело ответа для диагностических логов (как при HTTP-ошибке).
    private static func rawPreview(_ data: Data) -> String {
        String(String(data: data, encoding: .utf8)?.prefix(500) ?? "<бинарные данные>")
    }

    // MARK: - MIME

    /// MIME-тип по расширению файла. Сначала — явный белый список Nexara
    /// (источник правды): системный `UTType` для части расширений возвращает
    /// тип ВНЕ белого списка (например, .wav → `audio/vnd.wave`, .asf →
    /// `video/x-ms-asf`, .avi → `video/avi`), а сервер проверяет MIME части
    /// файла и отклоняет неизвестный. UTType — лишь фолбэк для расширений вне
    /// таблицы, иначе generic.
    private static func mimeType(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        if let mime = mimeFallback[ext] {
            return mime
        }
        return UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
    }

    private static let mimeFallback: [String: String] = [
        "wav": "audio/wav", "mp3": "audio/mpeg", "m4a": "audio/x-m4a",
        "flac": "audio/flac", "ogg": "audio/ogg", "opus": "audio/opus",
        "aiff": "audio/aiff", "asf": "audio/asf",
        "mp4": "video/mp4", "mov": "video/quicktime",
        "avi": "video/x-msvideo", "mkv": "video/x-matroska"
    ]
}
