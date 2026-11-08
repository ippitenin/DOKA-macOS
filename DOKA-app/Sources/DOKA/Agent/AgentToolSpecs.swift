import Foundation

/// Описания инструментов для `tools/list` и инструкция сервера. Английский —
/// это протокол для модели агента, не интерфейс (см. `AgentToolSpec`).
extension AgentTools {
    static let serverInstructions = """
    DOKA is a macOS dictation and transcription app running on this Mac. \
    To transcribe an audio or video file, call transcribe_file with an absolute path, \
    then call get_transcript with the returned id and wait_seconds until status is "done". \
    DOKA transcribes one file at a time with the service the user selected. \
    Personal data (transcript library, dictation history, dictionary, AI analysis) is protected \
    by toggles the user controls in DOKA. When a tool answers that access is turned off, \
    tell the user exactly what the message says and do not retry.
    """

    private static func object(_ properties: [String: [String: Any]], required: [String] = []) -> [String: Any] {
        var schema: [String: Any] = ["type": "object", "properties": properties]
        if !required.isEmpty { schema["required"] = required }
        return schema
    }

    private static let idProperty: [String: Any] = [
        "type": "string", "description": "Transcript record id (UUID) from transcribe_file or list_transcripts."
    ]
    private static let waitProperty: [String: Any] = [
        "type": "number", "minimum": 0, "maximum": maxWaitSeconds,
        "description": "Seconds to wait for completion inside this call (max 50). Call again if still in progress."
    ]

    static let specs: [AgentToolSpec] = [
        AgentToolSpec(
            name: Tool.dokaStatus.rawValue,
            description: "DOKA version, the active transcription service, which permissions the user enabled, and whether DOKA is busy.",
            inputSchema: object([:])),
        AgentToolSpec(
            name: Tool.transcribeFile.rawValue,
            description: "Start transcribing a local audio or video file (wav, mp3, m4a, flac, ogg, opus, aiff, mp4, mov, avi, mkv; up to 3 GB) with the user's active service. Returns a record id immediately; fetch the text with get_transcript. Requires the 'Transcribe files' permission.",
            inputSchema: object([
                "path": ["type": "string", "description": "Absolute path to the file (~ is expanded)."],
                "language": ["type": "string", "description": "ISO 639-1 code such as 'ru' or 'en', or 'auto'. Defaults to the user's dictation language."],
                "diarize": ["type": "boolean", "description": "Split the transcript by speakers. Slower; default false."],
                "num_speakers": ["type": "integer", "minimum": 1, "maximum": 10, "description": "Expected number of speakers when diarize is true."]
            ], required: ["path"])),
        AgentToolSpec(
            name: Tool.getTranscript.rawValue,
            description: "Status and text of a transcript record. Transcripts started by the agent are always readable; other library records need the 'Read library' permission.",
            inputSchema: object([
                "id": idProperty,
                "format": ["type": "string", "enum": ["plain", "timestamps", "speakers", "srt", "vtt"], "description": "Text format; default plain."],
                "wait_seconds": waitProperty,
                "include_analyses": ["type": "boolean", "description": "Include saved AI analyses (Markdown)."]
            ], required: ["id"])),
        AgentToolSpec(
            name: Tool.cancelTranscription.rawValue,
            description: "Cancel a transcription that is still in progress.",
            inputSchema: object(["id": idProperty], required: ["id"])),
        AgentToolSpec(
            name: Tool.listTranscripts.rawValue,
            description: "List transcript records, newest first, optionally filtered by a full-text query. Without the 'Read library' permission only records created by the agent are listed.",
            inputSchema: object([
                "query": ["type": "string", "description": "Words to search in titles and transcript text."],
                "limit": ["type": "integer", "minimum": 1, "maximum": 100, "description": "Default 20."]
            ])),
        AgentToolSpec(
            name: Tool.renameTranscript.rawValue,
            description: "Rename a transcript record (empty title restores the file name). Records not created by the agent need the 'Change library' permission.",
            inputSchema: object(["id": idProperty, "title": ["type": "string"]], required: ["id", "title"])),
        AgentToolSpec(
            name: Tool.deleteTranscript.rawValue,
            description: "Permanently delete a transcript record with its audio and analyses. Records not created by the agent need the 'Change library' permission. Ask the user before deleting.",
            inputSchema: object(["id": idProperty], required: ["id"])),
        AgentToolSpec(
            name: Tool.listAnalysisTemplates.rawValue,
            description: "AI analysis templates available in DOKA (summary, action items and the user's own). Requires the 'AI analysis' permission.",
            inputSchema: object([:])),
        AgentToolSpec(
            name: Tool.analyzeTranscript.rawValue,
            description: "Run DOKA's on-device AI analysis of a transcript with a template or a custom prompt and save it to the record. Runs on this Mac and can take minutes: call again with the same id to keep waiting. Requires the 'AI analysis' permission; for records the agent did not create, also 'Read library' and 'Change library' (the analysis is saved to the record).",
            inputSchema: object([
                "id": idProperty,
                "template_id": ["type": "string", "description": "Template id from list_analysis_templates."],
                "prompt": ["type": "string", "description": "Custom instruction, used when template_id is not given."],
                "response_language": ["type": "string", "description": "ISO 639-1 code of the answer language; default is the transcript language."],
                "wait_seconds": waitProperty
            ], required: ["id"])),
        AgentToolSpec(
            name: Tool.getDictationHistory.rawValue,
            description: "Recent dictations (text the user dictated into other apps), newest first. Requires the 'Dictation history' permission.",
            inputSchema: object([
                "limit": ["type": "integer", "minimum": 1, "maximum": 200, "description": "Default 20."],
                "since": ["type": "string", "description": "ISO 8601 date or date-time; only newer dictations."],
                "query": ["type": "string", "description": "Only dictations containing this text."]
            ])),
        AgentToolSpec(
            name: Tool.getDictationStats.rawValue,
            description: "Dictation statistics from the DOKA dashboard: words, sessions, speaking and typing speed, time saved, last 30 days. Requires the 'Dictation history' permission.",
            inputSchema: object([:])),
        AgentToolSpec(
            name: Tool.listDictionary.rawValue,
            description: "The user's replacement dictionary (rules applied to dictated text). Requires the 'Read dictionary' permission.",
            inputSchema: object([:])),
        AgentToolSpec(
            name: Tool.addDictionaryRule.rawValue,
            description: "Add a replacement rule: dictated 'from' becomes 'to' (whole words, word forms included). It changes what the user dictates into other apps, so add only rules the user asked for. Requires the 'Change dictionary' permission.",
            inputSchema: object([
                "from": ["type": "string"], "to": ["type": "string"]
            ], required: ["from", "to"])),
        AgentToolSpec(
            name: Tool.removeDictionaryRule.rawValue,
            description: "Remove a replacement rule by id from list_dictionary. Requires the 'Change dictionary' permission.",
            inputSchema: object(["id": ["type": "string", "description": "Rule id (UUID)."]], required: ["id"]))
    ]
}
