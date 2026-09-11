import Foundation

// Модели библиотеки файловых транскрибаций. Всё, что лежит на диске, декодируется
// устойчиво: новые поля — только опциональные или с ручным `decodeIfPresent`,
// потому что ошибка декода одной записи не должна стоить пользователю библиотеки.

/// Компактная форма машинного результата для диска: без производного
/// `segments` — отображаемая нарезка восстанавливается `withDetail` при
/// открытии записи, хранить её значит удваивать JSON. Не мутируется: это
/// «исходник» — база для перенарезки (и для правок в следующих фазах).
struct StoredTranscript: Codable, Equatable {
    let fullText: String
    let language: String?
    let duration: Double?
    let rawSegments: [TranscriptSegment]
    let words: [TranscriptWord]
    /// Только для чтения записей v1: анализ Nexara раньше жил здесь. В v2
    /// источник правды анализа — `TranscriptBody.analyses`, новые тела пишут nil.
    let llmOutput: String?

    init(_ result: TranscriptResult) {
        fullText = result.fullText
        language = result.language
        duration = result.duration
        rawSegments = result.rawSegments
        words = result.words
        llmOutput = result.llmOutput
    }

    init(fullText: String, language: String?, duration: Double?,
         rawSegments: [TranscriptSegment], words: [TranscriptWord], llmOutput: String?) {
        self.fullText = fullText
        self.language = language
        self.duration = duration
        self.rawSegments = rawSegments
        self.words = words
        self.llmOutput = llmOutput
    }

    /// Копия без анализа — так машинный результат кладётся в тело v2.
    var withoutLLMOutput: StoredTranscript {
        StoredTranscript(fullText: fullText, language: language, duration: duration,
                         rawSegments: rawSegments, words: words, llmOutput: nil)
    }

    /// Результат с нарезкой под запрошенную детализацию — тем же путём
    /// `withDetail`, что и живой ответ сервера.
    func toResult(detail: TimestampDetail, llmOutput: String? = nil) -> TranscriptResult {
        TranscriptResult(fullText: fullText, language: language, duration: duration,
                         segments: rawSegments, rawSegments: rawSegments, words: words,
                         llmOutput: llmOutput).withDetail(detail)
    }
}

/// Почему запись завершилась ошибкой — нужно «Повторить», чтобы решить,
/// можно ли забрать результат с сервера без повторной оплаты.
enum FailureKind: String, Codable, Equatable {
    case network        // сеть, 429, 5xx — транзиентное
    case jobNotFound    // задача Nexara не найдена или результат истёк
    case jobFailed      // сервер завершил задачу со status=error
    case interrupted    // sync-запрос умер вместе с процессом
    case expired        // async-задача старше срока жизни результата
    case auth           // нет ключа / неверный ключ / сервис не настроен
    case noFunds
    case local          // локальный движок или декодер
    case other

    /// Неизвестное значение (запись из будущей версии) — `.other`, а не
    /// ошибка декода всей записи.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = FailureKind(rawValue: raw) ?? .other
    }

    /// Классификация ошибки распознавания файла.
    static func classify(_ error: Error) -> FailureKind {
        if let fileError = error as? FileTranscriptionClient.FileTranscriptionError {
            switch fileError {
            case .invalidKey: return .auth
            case .noFunds: return .noFunds
            case .rateLimited, .server, .network: return .network
            case .jobNotFound: return .jobNotFound
            case .jobFailed: return .jobFailed
            case .badResponse, .emptyText, .readFailed: return .other
            }
        }
        if let clientError = error as? TranscriptionClient.ClientError {
            switch clientError {
            case .notConfigured, .noAPIKey: return .auth
            default: return .other
            }
        }
        if error is AudioFileDecoder.DecoderError { return .local }
        return .other
    }
}

/// Производная сводка тела — строке библиотеки не нужно читать тело с диска.
struct RecordSummary: Codable, Equatable {
    var wordCount: Int
    var speakerCount: Int
    var analysisCount: Int
    /// Первые символы текста для строки списка.
    var preview: String

    static let previewLength = 160

    static func make(from body: TranscriptBody) -> RecordSummary {
        let text = body.plainText
        let speakers = Set(body.transcript.rawSegments.compactMap { segment -> String? in
            guard let speaker = segment.speaker, !speaker.isEmpty else { return nil }
            return speaker
        })
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return RecordSummary(wordCount: text.dokaWordCount,
                             speakerCount: speakers.count,
                             analysisCount: body.analyses.count,
                             preview: String(collapsed.prefix(previewLength)))
    }
}

/// Одна запись библиотеки. Запись со статусом `inProgress` и `jobID` —
/// одновременно элемент списка и точка восстановления async-задачи после
/// перезапуска приложения. В v2 хранится в `<id>/meta.json` (источник правды)
/// и в индексе (кэш).
struct FileTranscriptRecord: Codable, Identifiable, Equatable {
    enum Status: Codable, Equatable {
        case inProgress
        case done
        case error(String)       // локализованный текст для показа
        case cancelled           // отменена пользователем: задачу на сервере
                                 // остановить нельзя, но результат не забираем
    }

    let id: UUID
    let fileName: String         // имя исходного файла (и у повторов из архива)
    var date: Date               // момент создания записи — группировка в списке
    var status: Status
    /// Только v1: результат жил прямо в журнале. v2 держит тело в отдельном
    /// файле и сюда не пишет (nil не кодируется).
    var result: StoredTranscript?
    var provider: String         // SettingsStore.providerTagForHistory
    var language: String?
    var duration: Double?
    var jobID: String?           // async-задача Nexara; nil — sync/локальный

    // v2 — все опциональные: записи v1 декодируются как есть.
    var title: String?           // заголовок пользователя; nil — имя файла
    var audioFileName: String?   // архив звука в папке записи; nil — нет/стёрт/выкл
    var sourcePath: String?      // путь исходника — фолбэк «Повторить», пока файл на месте
    var params: FileTranscriptionParams?
    var parentID: UUID?          // «Распознать заново»: из какой записи
    var submittedAt: Date?       // постановка задачи — от неё дедлайн 12 ч опроса
    var failure: FailureKind?
    var summary: RecordSummary?
    var updatedAt: Date?

    /// Заголовок для показа: свой или имя файла без расширения.
    var displayTitle: String {
        if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title
        }
        return (fileName as NSString).deletingPathExtension
    }

    var isDone: Bool {
        if case .done = status { return true }
        return false
    }
}

/// Анализ записи — отчёт ИИ поверх расшифровки. Сейчас только анализ Nexara
/// из того же запроса; локальные анализы добавит фаза локального ИИ.
struct StoredAnalysis: Codable, Equatable, Identifiable {
    enum Source: Codable, Equatable {
        case nexara
        case local(modelID: String)
    }

    let id: UUID
    let createdAt: Date
    var title: String            // имя шаблона/пресета на момент создания
    var templateID: String?      // "nexara.<preset>" | "builtin.<id>" | uuid своего шаблона
    var source: Source
    var markdown: String         // СЫРОЙ ответ модели
    var responseLanguage: String?
    var inputFingerprint: String?    // для пометки «расшифровку изменили после анализа»
    var truncated: Bool
    var generationSeconds: Double?

    init(id: UUID = UUID(), createdAt: Date = Date(), title: String, templateID: String?,
         source: Source, markdown: String, responseLanguage: String? = nil,
         inputFingerprint: String? = nil, truncated: Bool = false,
         generationSeconds: Double? = nil) {
        self.id = id
        self.createdAt = createdAt
        self.title = title
        self.templateID = templateID
        self.source = source
        self.markdown = markdown
        self.responseLanguage = responseLanguage
        self.inputFingerprint = inputFingerprint
        self.truncated = truncated
        self.generationSeconds = generationSeconds
    }

    private enum CodingKeys: String, CodingKey {
        case id, createdAt, title, templateID, source, markdown, responseLanguage,
             inputFingerprint, truncated, generationSeconds
    }

    /// Устойчивый декодер: обязателен только сам текст анализа.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? .distantPast
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        templateID = try c.decodeIfPresent(String.self, forKey: .templateID)
        source = (try? c.decodeIfPresent(Source.self, forKey: .source)) ?? .nexara
        markdown = try c.decode(String.self, forKey: .markdown)
        responseLanguage = try c.decodeIfPresent(String.self, forKey: .responseLanguage)
        inputFingerprint = try c.decodeIfPresent(String.self, forKey: .inputFingerprint)
        truncated = try c.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
        generationSeconds = try c.decodeIfPresent(Double.self, forKey: .generationSeconds)
    }

    var isNexara: Bool { source == .nexara }
}

/// Тело записи: машинный результат (не мутируется) + то, что пользователь с
/// ним сделал. Лежит в `<id>/transcript.json`, грузится лениво при открытии.
struct TranscriptBody: Codable, Equatable {
    static let currentSchema = 1

    var schema: Int
    var transcript: StoredTranscript
    var analyses: [StoredAnalysis]

    init(transcript: StoredTranscript, analyses: [StoredAnalysis] = []) {
        schema = Self.currentSchema
        self.transcript = transcript
        self.analyses = analyses
    }

    private enum CodingKeys: String, CodingKey {
        case schema, transcript, analyses
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decodeIfPresent(Int.self, forKey: .schema) ?? Self.currentSchema
        transcript = try c.decode(StoredTranscript.self, forKey: .transcript)
        // Битый анализ не должен стоить расшифровки.
        analyses = (try? c.decodeIfPresent([StoredAnalysis].self, forKey: .analyses)) ?? []
    }

    /// Результат для показа. `llmOutput` берётся из анализов (первый анализ
    /// Nexara), а не из машинного результата: удалённый анализ не всплывёт.
    func makeResult(detail: TimestampDetail) -> TranscriptResult {
        transcript.toResult(detail: detail,
                            llmOutput: analyses.first(where: \.isNexara)?.markdown)
    }

    /// Плоский текст для поиска и сводки — от исходных сегментов, не зависит
    /// от детализации.
    var plainText: String {
        TranscriptFormatter.plainText(makeResult(detail: .server))
    }
}
