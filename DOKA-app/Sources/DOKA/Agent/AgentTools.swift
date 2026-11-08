import Foundation

/// Инструменты MCP поверх существующего кода DOKA — нового пайплайна нет:
/// распознавание идёт через `FileTranscriptionController.start` (все его
/// гейты: файл за раз, аренда модели, заморозка библиотеки), анализ — через
/// `AnalysisController`, данные — из тех же сторов, что у интерфейса.
///
/// Разрешения проверяются ДО обращения к сторам (`requiredPermission`), доступ
/// к записи — по `AgentAccessPolicy`. Каждый вызов попадает в журнал.
@MainActor
final class AgentTools: AgentToolProvider {
    enum Tool: String, CaseIterable {
        case dokaStatus = "doka_status"
        case transcribeFile = "transcribe_file"
        case getTranscript = "get_transcript"
        case cancelTranscription = "cancel_transcription"
        case listTranscripts = "list_transcripts"
        case renameTranscript = "rename_transcript"
        case deleteTranscript = "delete_transcript"
        case listAnalysisTemplates = "list_analysis_templates"
        case analyzeTranscript = "analyze_transcript"
        case getDictationHistory = "get_dictation_history"
        case getDictationStats = "get_dictation_stats"
        case listDictionary = "list_dictionary"
        case addDictionaryRule = "add_dictionary_rule"
        case removeDictionaryRule = "remove_dictionary_rule"
    }

    /// Разрешение, без которого инструмент не работает вовсе. nil — проверка
    /// по записи (свои записи агента или библиотека) либо без разрешения.
    static func requiredPermission(for tool: Tool) -> AgentPermission? {
        switch tool {
        case .dokaStatus, .getTranscript, .cancelTranscription, .listTranscripts,
             .renameTranscript, .deleteTranscript:
            return nil
        case .transcribeFile: return .transcribeFiles
        case .listAnalysisTemplates, .analyzeTranscript: return .analysis
        case .getDictationHistory, .getDictationStats: return .dictationHistory
        case .listDictionary: return .dictionary
        case .addDictionaryRule, .removeDictionaryRule: return .dictionaryWrite
        }
    }

    /// Самое долгое ожидание внутри одного вызова: клиенты MCP рвут запрос
    /// через ~60 с, поэтому дольше агент ждёт повторными вызовами.
    static let maxWaitSeconds: Double = 50

    private let access: AgentAccessSettings
    private let log: AgentActivityLog
    /// Когда агент запустил анализ записи — чтобы отличить новый анализ от
    /// прежних при повторном вызове с ожиданием.
    private var analysisStarts: [UUID: Date] = [:]

    init(access: AgentAccessSettings, log: AgentActivityLog) {
        self.access = access
        self.log = log
    }

    var specs: [AgentToolSpec] { Self.specs }

    func call(_ name: String, arguments: [String: Any]) async -> AgentToolResult? {
        guard let tool = Tool(rawValue: name) else { return nil }
        let result: AgentToolResult
        if let permission = Self.requiredPermission(for: tool), !access.isAllowed(permission) {
            result = .denied(permission)
        } else {
            do {
                result = try await run(tool, Arguments(arguments))
            } catch let error as ArgumentError {
                result = .error(error.message)
            } catch {
                result = .error(error.localizedDescription)
            }
        }
        log.add(tool: name, result: result)
        return result
    }

    private func run(_ tool: Tool, _ args: Arguments) async throws -> AgentToolResult {
        switch tool {
        case .dokaStatus: return status()
        case .transcribeFile: return try transcribeFile(args)
        case .getTranscript: return try await getTranscript(args)
        case .cancelTranscription: return try cancelTranscription(args)
        case .listTranscripts: return try await listTranscripts(args)
        case .renameTranscript: return try renameTranscript(args)
        case .deleteTranscript: return try deleteTranscript(args)
        case .listAnalysisTemplates: return listAnalysisTemplates()
        case .analyzeTranscript: return try await analyzeTranscript(args)
        case .getDictationHistory: return try getDictationHistory(args)
        case .getDictationStats: return getDictationStats()
        case .listDictionary: return listDictionary()
        case .addDictionaryRule: return try addDictionaryRule(args)
        case .removeDictionaryRule: return try removeDictionaryRule(args)
        }
    }

    // MARK: - Сторы

    private var settings: SettingsStore { .shared }
    private var library: TranscriptHistoryStore { .shared }
    private var files: FileTranscriptionController { .shared }
    private var analysis: AnalysisController { .shared }

    // MARK: - Статус

    private func status() -> AgentToolResult {
        let providerID = settings.providerID
        var permissions: [String: Bool] = [:]
        for permission in AgentPermission.allCases {
            permissions[permission.rawValue] = access.isAllowed(permission)
        }
        return .json([
            "app": "DOKA",
            "version": AppVersion.short,
            "service": [
                "id": providerID,
                "title": serviceTitle(providerID: providerID),
                "local": settings.isLocalService,
                // Читает Keychain — здесь можно: это действие, а не тело вью.
                "ready": settings.isServiceReady
            ] as [String: Any],
            "permissions": permissions,
            "busy": [
                "transcribing": files.isTranscribing,
                "analysis": analysis.isRunning
            ],
            "library_frozen": library.isFrozen,
            "supported_extensions": FileTranscriptionController.allExtensions
        ])
    }

    // MARK: - Распознавание

    private func transcribeFile(_ args: Arguments) throws -> AgentToolResult {
        let rawPath = try args.requiredString("path")
        let path = (rawPath as NSString).expandingTildeInPath
        guard path.hasPrefix("/") else { throw ArgumentError("path must be absolute") }
        // Свои файлы DOKA (архивы записей, аудио истории, клипы губ, временные
        // WAV диктовок) — мимо: иначе это обход «Читать библиотеку» и «Истории».
        let resolved: String
        switch AgentPathPolicy.check(path: path, protectedRoots: AgentPathPolicy.dokaRoots,
                                     protectedPrefixDirectory: FileManager.default.temporaryDirectory) {
        case .allowed(let real): resolved = real
        case .missing: return .error(L("agent.error.fileMissing", path))
        case .notRegularFile: return .error(L("agent.error.notAFile", path))
        case .protected: return .error(L("agent.error.dokaFile"))
        }
        let url = URL(fileURLWithPath: resolved)
        if let message = FileTranscriptionController.validationError(for: url) { return .error(message) }

        let language = try args.optionalString("language") ?? settings.language
        guard TranscriptionLanguage.all.contains(where: { $0.id == language }) else {
            throw ArgumentError("unsupported language '\(language)'; use 'auto' or an ISO 639-1 code DOKA supports")
        }
        let speakers = try args.optionalInt("num_speakers")
        if let speakers, !(1...10).contains(speakers) { throw ArgumentError("num_speakers must be 1…10") }

        // Снимок как у страницы, но без ролей и анализа: анализ — отдельным
        // инструментом. Сервис — активный: агент его не выбирает.
        let params = FileTranscriptionParams(
            providerID: settings.providerID,
            language: language,
            diarize: try args.optionalBool("diarize") ?? false,
            numSpeakers: speakers,
            diarizationSetting: DiarizationSetting.general.rawValue,
            rolesMode: RolesMode.off.rawValue,
            rolesText: "",
            llmPreset: LLMAnalysisPreset.off.rawValue,
            llmCustomPrompt: "",
            llmLocal: true)
        switch files.start(source: url, displayName: url.lastPathComponent, params: params,
                           target: .agent(sourcePath: resolved)) {
        case .started(let id):
            return .json([
                "id": id.uuidString,
                "status": "in_progress",
                "service": serviceTitle(providerID: params.providerID),
                "next": "Call get_transcript with this id and wait_seconds (up to 50) until status is done."
            ])
        case .busy:
            return .error(L("agent.error.busy"))
        case .rejected(let message):
            return .error(message)
        }
    }

    private func getTranscript(_ args: Arguments) async throws -> AgentToolResult {
        let id = try args.requiredUUID("id")
        guard let record = library.record(id) else { return .error(L("transcribe.recordMissing")) }
        if let missing = AgentAccessPolicy.missingForRead(createdByAgent: record.createdByAgent == true,
                                                          permissions: access.permissions) {
            return .denied(missing)
        }
        let format = try args.optionalString("format") ?? "plain"
        guard Self.formats.contains(format) else {
            throw ArgumentError("format must be one of: \(Self.formats.joined(separator: ", "))")
        }
        await wait(seconds: try args.optionalDouble("wait_seconds") ?? 0) { [library] in
            library.record(id)?.status == .inProgress
        }
        guard let current = library.record(id) else { return .error(L("transcribe.recordMissing")) }
        var object = recordJSON(current)
        guard current.isDone else {
            if current.status == .inProgress {
                if files.runningRecordID == id, let note = files.progressNote { object["progress"] = note }
                object["next"] = "Still running. Call get_transcript again with wait_seconds."
            }
            return .json(object)
        }
        guard let body = await library.loadBody(id) else { return .error(L("transcribe.recordMissing")) }
        // Тот же выход, что у «Скопировать» и «Сохранить как…»: правки
        // пользователя и (если включено) словарь замен.
        let detail: TimestampDetail = format == "plain" ? .server : .medium
        let result = TranscriptOutput.prepare(body.makeResult(detail: detail))
        object["format"] = format
        object["text"] = Self.render(result, format: format)
        if try args.optionalBool("include_analyses") ?? false {
            object["analyses"] = body.analyses.map(analysisJSON)
        } else if !body.analyses.isEmpty {
            object["analyses_available"] = body.analyses.count
        }
        return .json(object)
    }

    private static let formats = ["plain", "timestamps", "speakers", "srt", "vtt"]
    /// Правило словаря от агента — слово или короткая фраза, не абзац.
    static let maxRuleLength = 100

    private static func render(_ result: TranscriptResult, format: String) -> String {
        switch format {
        case "timestamps": return TranscriptFormatter.textWithTimestamps(result)
        case "speakers": return TranscriptFormatter.bySpeaker(result)
        case "srt": return TranscriptFormatter.srt(result)
        case "vtt": return TranscriptFormatter.vtt(result)
        default: return TranscriptFormatter.plainText(result)
        }
    }

    private func cancelTranscription(_ args: Arguments) throws -> AgentToolResult {
        let id = try args.requiredUUID("id")
        guard let record = library.record(id) else { return .error(L("transcribe.recordMissing")) }
        if let missing = AgentAccessPolicy.missingForModify(createdByAgent: record.createdByAgent == true,
                                                            permissions: access.permissions) {
            return .denied(missing)
        }
        guard record.status == .inProgress else { return .error(L("agent.error.notRunning")) }
        if files.runningRecordID == id {
            files.cancelTranscription()
        } else {
            // Добор задачи Nexara после перезапуска идёт мимо контроллера.
            library.cancelRecovery(id)
        }
        return .json(["id": id.uuidString, "status": "cancelled"])
    }

    // MARK: - Библиотека

    private func listTranscripts(_ args: Arguments) async throws -> AgentToolResult {
        let canReadAll = access.isAllowed(.libraryRead)
        // Без доступа к библиотеке агент видит только свои записи — если ему
        // разрешено распознавать; иначе показывать нечего.
        guard canReadAll || access.isAllowed(.transcribeFiles) else { return .denied(.libraryRead) }
        let limit = min(max(try args.optionalInt("limit") ?? 20, 1), 100)
        var records = library.records.filter { canReadAll || $0.createdByAgent == true }
        var snippets: [UUID: String] = [:]
        if let query = try args.optionalString("query")?.trimmingCharacters(in: .whitespacesAndNewlines),
           !query.isEmpty {
            snippets = await library.searchFullText(query)
            records = records.filter {
                snippets[$0.id] != nil || $0.displayTitle.localizedCaseInsensitiveContains(query)
            }
        }
        var object: [String: Any] = [
            "records": records.prefix(limit).map { record -> [String: Any] in
                var item = recordJSON(record)
                if let snippet = snippets[record.id] { item["match"] = snippet }
                return item
            },
            "total": records.count
        ]
        if !canReadAll { object["note"] = L("agent.note.ownOnly") }
        return .json(object)
    }

    private func renameTranscript(_ args: Arguments) throws -> AgentToolResult {
        let id = try args.requiredUUID("id")
        let title = try args.requiredString("title")
        guard let record = library.record(id) else { return .error(L("transcribe.recordMissing")) }
        if let missing = AgentAccessPolicy.missingForModify(createdByAgent: record.createdByAgent == true,
                                                            permissions: access.permissions) {
            return .denied(missing)
        }
        guard !library.isFrozen else { return .error(L("transcribe.error.restartRequired")) }
        library.rename(id, title: title)
        return .json(recordJSON(library.record(id) ?? record))
    }

    private func deleteTranscript(_ args: Arguments) throws -> AgentToolResult {
        let id = try args.requiredUUID("id")
        guard let record = library.record(id) else { return .error(L("transcribe.recordMissing")) }
        if let missing = AgentAccessPolicy.missingForModify(createdByAgent: record.createdByAgent == true,
                                                            permissions: access.permissions) {
            return .denied(missing)
        }
        guard !library.isFrozen else { return .error(L("transcribe.error.restartRequired")) }
        guard files.runningRecordID != id, analysis.runningRecordID != id else {
            return .error(L("agent.error.recordBusy"))
        }
        library.delete(id)
        return .json(["id": id.uuidString, "deleted": true])
    }

    // MARK: - Анализ

    private func listAnalysisTemplates() -> AgentToolResult {
        .json(["templates": settings.allAnalysisTemplates.map { template -> [String: Any] in
            ["id": template.id, "name": template.name, "description": template.description,
             "builtin": template.isBuiltin]
        }])
    }

    private func analyzeTranscript(_ args: Arguments) async throws -> AgentToolResult {
        let id = try args.requiredUUID("id")
        guard let record = library.record(id) else { return .error(L("transcribe.recordMissing")) }
        // Анализ и читает запись, и СОХРАНЯЕТСЯ в неё: у записи человека нужны
        // и чтение, и изменение библиотеки.
        let ownRecord = record.createdByAgent == true
        if let missing = AgentAccessPolicy.missingForRead(createdByAgent: ownRecord, permissions: access.permissions)
            ?? AgentAccessPolicy.missingForModify(createdByAgent: ownRecord, permissions: access.permissions) {
            return .denied(missing)
        }
        // Анализ этой записи уже идёт (запущен агентом раньше или человеком) —
        // только ждём, второй не запускаем.
        if analysis.runningRecordID != id {
            let kind: AnalysisController.Request.Kind
            if let templateID = try args.optionalString("template_id") {
                guard let template = settings.allAnalysisTemplates.first(where: { $0.id == templateID }) else {
                    throw ArgumentError("unknown template_id; call list_analysis_templates")
                }
                kind = .template(template)
            } else if let prompt = try args.optionalString("prompt")?
                        .trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty {
                kind = .custom(prompt)
            } else {
                throw ArgumentError("pass template_id or prompt")
            }
            let availability = analysis.availability(for: record)
            if let message = availability.message { return .error(message) }
            let language = try args.optionalString("response_language")
            guard analysis.start(recordID: id, request: .init(kind: kind, responseLanguage: language)) else {
                return .error(L("agent.error.analysisNotStarted"))
            }
            analysisStarts[id] = Date()
        }
        await wait(seconds: try args.optionalDouble("wait_seconds") ?? 30) { [analysis] in
            analysis.runningRecordID == id
        }
        if analysis.runningRecordID == id {
            return .json(["id": id.uuidString, "status": "in_progress",
                          "next": "Analysis runs on this Mac and can take minutes. Call analyze_transcript again with the same id and wait_seconds."])
        }
        if case .failed(let failedID, let message) = analysis.phase, failedID == id {
            return .error(message)
        }
        let started = analysisStarts.removeValue(forKey: id) ?? .distantPast
        guard let body = await library.loadBody(id),
              let latest = body.analyses.last(where: { $0.createdAt >= started.addingTimeInterval(-1) }) else {
            return .error(L("agent.error.analysisCancelled"))
        }
        return .json(["id": id.uuidString, "status": "done", "analysis": analysisJSON(latest)])
    }

    // MARK: - Диктовка

    private func getDictationHistory(_ args: Arguments) throws -> AgentToolResult {
        let limit = min(max(try args.optionalInt("limit") ?? 20, 1), 200)
        var records = HistoryStore.shared.records.sorted { $0.date > $1.date }
        if let since = try args.optionalString("since") {
            guard let date = Self.parseDate(since) else {
                throw ArgumentError("since must be an ISO 8601 date, e.g. 2026-11-01 or 2026-11-01T09:00:00Z")
            }
            records = records.filter { $0.date >= date }
        }
        if let query = try args.optionalString("query")?.trimmingCharacters(in: .whitespacesAndNewlines),
           !query.isEmpty {
            records = records.filter { $0.text.localizedCaseInsensitiveContains(query) }
        }
        return .json([
            "records": records.prefix(limit).map { record -> [String: Any] in
                var item: [String: Any] = [
                    "id": record.id.uuidString,
                    "date": Self.iso(record.date),
                    "text": record.text,
                    "duration_seconds": Self.round1(record.duration),
                    "language": record.language
                ]
                if let provider = record.provider { item["service"] = Self.serviceTitle(tag: provider) }
                if let raw = record.rawText { item["text_before_ai_cleanup"] = raw }
                return item
            },
            "total": records.count
        ])
    }

    private func getDictationStats() -> AgentToolResult {
        let snapshot = StatsStore.shared.snapshot
        let metrics = DashboardMetrics(snapshot: snapshot, typingSpeedWPM: settings.typingSpeedWPM)
        var object: [String: Any] = [
            "total_words": metrics.totalWords,
            "total_sessions": metrics.totalSessions,
            "total_duration_seconds": Self.round1(metrics.totalDuration),
            "speech_words_per_minute": Self.round1(metrics.speechWPM),
            "last_30_days": StatsStore.shared.recentDays(30).map {
                ["date": Self.day($0.date), "words": $0.bucket.words, "sessions": $0.bucket.sessions] as [String: Any]
            }
        ]
        if let first = snapshot.firstUseDate { object["first_use"] = Self.iso(first) }
        if let typing = metrics.typingWPM { object["typing_words_per_minute"] = Self.round1(typing) }
        if let multiplier = metrics.speedMultiplier { object["speed_multiplier"] = Self.round1(multiplier) }
        if let saved = metrics.timeSaved { object["time_saved_seconds"] = Self.round1(saved) }
        return .json(object)
    }

    // MARK: - Словарь

    private func listDictionary() -> AgentToolResult {
        .json(["rules": settings.replacements.map(ruleJSON)])
    }

    private func addDictionaryRule(_ args: Arguments) throws -> AgentToolResult {
        let from = try args.requiredString("from").trimmingCharacters(in: .whitespacesAndNewlines)
        let to = try args.requiredString("to").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !from.isEmpty else { throw ArgumentError("from must not be empty") }
        guard from.count <= Self.maxRuleLength, to.count <= Self.maxRuleLength else {
            throw ArgumentError("from and to must be at most \(Self.maxRuleLength) characters")
        }
        if settings.replacements.contains(where: { $0.from.caseInsensitiveCompare(from) == .orderedSame }) {
            return .error(L("agent.error.ruleExists", from))
        }
        let rule = ReplacementRule(from: from, to: to)
        settings.replacements.append(rule)
        return .json(ruleJSON(rule))
    }

    private func removeDictionaryRule(_ args: Arguments) throws -> AgentToolResult {
        let id = try args.requiredUUID("id")
        guard settings.replacements.contains(where: { $0.id == id }) else {
            return .error(L("agent.error.ruleMissing"))
        }
        settings.replacements.removeAll { $0.id == id }
        return .json(["id": id.uuidString, "deleted": true])
    }

    // MARK: - Помощники

    /// Ждать, пока условие истинно, но не дольше `seconds` (≤ 50 с). Главный
    /// поток не блокируется: опрос раз в полсекунды.
    private func wait(seconds: Double, while condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(min(max(seconds, 0), Self.maxWaitSeconds))
        while condition(), Date() < deadline, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    private func recordJSON(_ record: FileTranscriptRecord) -> [String: Any] {
        var item: [String: Any] = [
            "id": record.id.uuidString,
            "title": record.displayTitle,
            "file_name": record.fileName,
            "created_at": Self.iso(record.date),
            "service": Self.serviceTitle(tag: record.provider),
            "created_by_agent": record.createdByAgent == true
        ]
        switch record.status {
        case .inProgress: item["status"] = "in_progress"
        case .done: item["status"] = "done"
        case .cancelled: item["status"] = "cancelled"
        case .error(let message):
            item["status"] = "error"
            item["error"] = message
        }
        if let duration = record.duration { item["duration_seconds"] = Self.round1(duration) }
        if let language = record.language { item["language"] = language }
        if let summary = record.summary {
            item["words"] = summary.wordCount
            item["speakers"] = summary.speakerCount
            item["analyses"] = summary.analysisCount
        }
        return item
    }

    private func analysisJSON(_ analysis: StoredAnalysis) -> [String: Any] {
        ["id": analysis.id.uuidString, "title": analysis.title,
         "created_at": Self.iso(analysis.createdAt), "markdown": analysis.markdown]
    }

    private func ruleJSON(_ rule: ReplacementRule) -> [String: Any] {
        ["id": rule.id.uuidString, "from": rule.from, "to": rule.to, "enabled": rule.enabled]
    }

    private func serviceTitle(providerID: String) -> String {
        if let local = LocalModel.from(providerID: providerID) { return local.title }
        return Self.serviceTitle(tag: settings.providerTag(for: providerID))
    }

    /// Метка сервиса записи → название: встроенный хранится rawValue,
    /// остальные — своим именем (как в «Истории» и «Библиотеке»).
    private static func serviceTitle(tag: String) -> String {
        TranscriptionProvider(rawValue: tag)?.title ?? tag
    }

    private static func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static func parseDate(_ text: String) -> Date? {
        let full = ISO8601DateFormatter()
        if let date = full.date(from: text) { return date }
        let dayOnly = ISO8601DateFormatter()
        dayOnly.formatOptions = [.withFullDate]
        dayOnly.timeZone = .current
        return dayOnly.date(from: text)
    }

    private static func round1(_ value: Double) -> Double {
        (value * 10).rounded() / 10
    }
}

// MARK: - Аргументы

/// Ошибка аргументов — агент исправляет вызов сам, поэтому текст английский.
struct ArgumentError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

/// Типизированное чтение аргументов вызова.
struct Arguments {
    private let raw: [String: Any]
    init(_ raw: [String: Any]) { self.raw = raw }

    func optionalString(_ key: String) throws -> String? {
        guard let value = raw[key], !(value is NSNull) else { return nil }
        guard let string = value as? String else { throw ArgumentError("\(key) must be a string") }
        return string
    }

    func requiredString(_ key: String) throws -> String {
        guard let value = try optionalString(key) else { throw ArgumentError("missing required argument \(key)") }
        return value
    }

    func requiredUUID(_ key: String) throws -> UUID {
        guard let value = UUID(uuidString: try requiredString(key)) else {
            throw ArgumentError("\(key) must be a record id (UUID)")
        }
        return value
    }

    func optionalBool(_ key: String) throws -> Bool? {
        guard let value = raw[key], !(value is NSNull) else { return nil }
        // JSONSerialization отдаёт true/false как NSNumber; числа 0/1 не
        // принимаем — это почти наверняка ошибка вызова.
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            throw ArgumentError("\(key) must be a boolean")
        }
        return number.boolValue
    }

    func optionalDouble(_ key: String) throws -> Double? {
        guard let value = raw[key], !(value is NSNull) else { return nil }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
            throw ArgumentError("\(key) must be a number")
        }
        return number.doubleValue
    }

    /// Целое в разумных пределах. `Int(Double)` за пределами Int — аварийная
    /// остановка процесса: `{"limit": 1e300}` ронял бы DOKA одним запросом.
    func optionalInt(_ key: String) throws -> Int? {
        guard let value = try optionalDouble(key) else { return nil }
        // `magnitude`, а не `abs`: abs(Int.min) — тоже аварийная остановка.
        guard let integer = Int(exactly: value), integer.magnitude <= UInt(Self.maxInteger) else {
            throw ArgumentError("\(key) must be an integer between -\(Self.maxInteger) and \(Self.maxInteger)")
        }
        return integer
    }

    static let maxInteger = 1_000_000
}
