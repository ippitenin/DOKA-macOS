import PDFKit
import XCTest
@testable import DOKA

/// Живой smoke локальных моделей на СИНТЕТИЧЕСКОЙ речи: то, что раньше
/// проверялось только руками после обновления зависимостей. По умолчанию
/// выключен — нужны скачанные модели и минуты работы:
///
///     DOKA_SMOKE=1 swift test --scratch-path /tmp/doka-build --filter LiveSmokeTests
///
/// Речь синтезирует `say` (Milena — русский, Eddy — английский), дальше звук
/// идёт настоящим `AudioFileDecoder.decodeToWav` — тем же входом, что у файлов
/// в приложении. Модели берутся из `Application Support/DOKA/Models` по путям
/// `LocalModelStore` (синглтон не создаётся: у него на старте чистка папки
/// моделей); нет модели — тест пропускается с причиной. Языковая модель —
/// `DOKA_SMOKE_LLM` (путь к GGUF) или файл из папки моделей. В библиотеку,
/// историю и настройки тесты ничего не пишут: собирается та же цепочка, что
/// в `FileTranscriptionController`, но без стора.
///
/// Файлы (звук, отчёт, PDF) остаются в `$TMPDIR/doka-smoke` для осмотра —
/// путь печатается в лог строкой «SMOKE».
@MainActor
final class LiveSmokeTests: XCTestCase {

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DOKA_SMOKE"] == "1",
                          "живой smoke выключен: DOKA_SMOKE=1")
    }

    // MARK: - Whisper: язык «Авто»

    /// «Авто» — это автоопределение, а не английский по умолчанию: русская
    /// речь остаётся русской (а не английским переводом), английская —
    /// английской. Регрессия #26.
    func testWhisperAutoLanguageKeepsSpeechLanguage() async throws {
        try requireModel(LocalModelStore.whisperModelFolder.appendingPathComponent("AudioEncoder.mlmodelc"),
                         "Whisper Large v3 Turbo")
        let russian = try await speech(Self.russianPhrase, voice: "Milena", name: "whisper-ru")
        let english = try await speech(Self.englishPhrase, voice: "Eddy", name: "whisper-en")
        let engine = WhisperLocalEngine()
        try await measure("Whisper: загрузка") { try await engine.load() }
        defer { engine.unload() }

        let dictationAuto = try await engine.transcribeDictation(wavURL: russian.url, language: nil)
        log("Whisper диктовка, «Авто», русская речь: \(dictationAuto)")
        XCTAssertGreaterThan(Self.cyrillicShare(dictationAuto), 0.8, dictationAuto)

        let fileAuto = try await engine.transcribeFile(wavURL: russian.url, language: nil)
        log("Whisper файл, «Авто»: язык \(fileAuto.language ?? "—"), \(fileAuto.fullText)")
        XCTAssertEqual(fileAuto.language, "ru")
        XCTAssertGreaterThan(Self.cyrillicShare(fileAuto.fullText), 0.8, fileAuto.fullText)
        XCTAssertFalse(fileAuto.segments.isEmpty)

        let dictationRu = try await engine.transcribeDictation(wavURL: russian.url, language: "ru")
        log("Whisper диктовка, «Русский»: \(dictationRu)")
        XCTAssertGreaterThan(Self.cyrillicShare(dictationRu), 0.8, dictationRu)

        let englishAuto = try await engine.transcribeFile(wavURL: english.url, language: nil)
        log("Whisper файл, «Авто», английская речь: язык \(englishAuto.language ?? "—"), \(englishAuto.fullText)")
        XCTAssertEqual(englishAuto.language, "en")
        XCTAssertLessThan(Self.cyrillicShare(englishAuto.fullText), 0.2, englishAuto.fullText)
    }

    // MARK: - Parakeet: слова и предложения

    /// Пословные тайм-коды Parakeet — настоящие слова (а не весь файл одним
    /// «словом»), поэтому запись режется по предложениям. Регрессия #28.
    func testParakeetWordsAndSentenceSplitting() async throws {
        try requireParakeet()
        let audio = try await speech(Self.longRussianText, voice: "Milena", name: "parakeet-long")
        let engine = ParakeetLocalEngine()
        try await measure("Parakeet: загрузка") { try await engine.load() }
        defer { engine.unload() }

        let dictation = try await engine.transcribeDictation(wavURL: audio.url, language: nil)
        XCTAssertGreaterThan(Self.cyrillicShare(dictation), 0.8, dictation)

        let file = try await engine.transcribeFile(wavURL: audio.url, language: nil)
        let spoken = Self.longRussianText.split(whereSeparator: \.isWhitespace).count
        log("Parakeet: \(file.words.count) слов (сказано \(spoken)), длительность \(Int(audio.duration)) с")
        XCTAssertEqual(Double(file.words.count), Double(spoken), accuracy: Double(spoken) * 0.3)
        XCTAssertFalse(file.words.contains { $0.text.contains { $0.isWhitespace } },
                       "слова склеены: \(file.words.prefix(5).map(\.text))")
        XCTAssertTrue(zip(file.words, file.words.dropFirst()).allSatisfy { $0.start <= $1.start },
                      "тайм-коды слов не по порядку")

        let result = Self.result(file, duration: audio.duration, segments: file.segments)
        for detail in [TimestampDetail.coarse, .medium, .fine] {
            let segments = result.withDetail(detail).segments
            log("Parakeet, детализация \(detail.rawValue): \(segments.count) сегм.")
        }
        let fine = result.withDetail(.fine).segments
        XCTAssertGreaterThanOrEqual(fine.count, 3, "запись не нарезалась по предложениям")
        XCTAssertTrue(fine.allSatisfy { $0.end - $0.start <= TranscriptSegmentSplitter.Config.fine.hardBreakDuration + 1 })
    }

    // MARK: - Parakeet + локальная диаризация

    /// Диалог двух голосов: диаризатор находит двоих и в «Авто», и с
    /// подсказкой; реплики одного голоса — у одного спикера; спикеры
    /// переживают все детализации и доходят до экспортов.
    func testParakeetWithLocalDiarization() async throws {
        let dialog = try await Self.dialog()
        let result = dialog.result
        let speakers = Set(result.segments.compactMap(\.speaker))
        log("Диаризация: \(speakers.sorted()) — " + result.segments.map {
            "\($0.speaker ?? "?") [\(TranscriptFormatter.clock($0.start))] \($0.text)"
        }.joined(separator: " | "))
        XCTAssertEqual(speakers.count, 2)

        // Реплики одного голоса — у одного спикера, у двух голосов — разные.
        var byVoice: [String: Set<String>] = [:]
        for turn in dialog.turns {
            let middle = (turn.start + turn.end) / 2
            let span = dialog.autoSpans.first { $0.start <= middle && middle <= $0.end }
            byVoice[turn.voice, default: []].insert(span?.speaker ?? "нет")
        }
        log("Голос → спикер: \(byVoice)")
        XCTAssertEqual(byVoice["Milena"]?.count, 1)
        XCTAssertEqual(byVoice["Eddy"]?.count, 1)
        XCTAssertNotEqual(byVoice["Milena"], byVoice["Eddy"])
        XCTAssertEqual(Set(dialog.hintedSpans.map(\.speaker)).count, 2, "подсказка «2 спикера»")

        for detail in TimestampDetail.allCases {
            let shown = result.withDetail(detail)
            XCTAssertEqual(Set(shown.segments.compactMap(\.speaker)), speakers, "детализация \(detail.rawValue)")
        }
        let bySpeaker = TranscriptFormatter.bySpeaker(result)
        for speaker in speakers {
            XCTAssertTrue(bySpeaker.contains(SpeakerName.displayName(for: speaker)), "нет \(speaker) в «по спикерам»")
        }
        XCTAssertTrue(TranscriptFormatter.srt(result).contains("-->"))
        XCTAssertTrue(TranscriptFormatter.vtt(result).hasPrefix("WEBVTT"))
        log("По спикерам:\n\(bySpeaker)")
    }

    // MARK: - ИИ-анализ → PDF

    /// Расшифровка диалога → анализ локальной моделью по импортированному
    /// шаблону Memento (с таблицами) → PDF. Плюс короткий прогон частями.
    func testLocalAnalysisToPDF() async throws {
        let modelURL = ProcessInfo.processInfo.environment["DOKA_SMOKE_LLM"]
            .map { URL(fileURLWithPath: $0) } ?? LocalModelStore.llmFile
        try requireModel(modelURL, "языковая модель (DOKA_SMOKE_LLM)")
        let dialog = try await Self.dialog()
        let template = Self.mementoTemplate("project_sync.json") ?? BuiltinAnalysisTemplate.meetingMinutes.template
        log("Шаблон анализа: \(template.name), разделов \(template.sections.count), "
            + "таблиц \(template.sections.filter { $0.format == .table }.count)")

        // «Подготовка модели…» — первая загрузка (компиляция Metal-кернелов
        // под чип, если их ещё нет в кэше шейдеров), вторая — уже из кэша.
        let engine = LocalLLMEngine()
        try await measure("ИИ-анализ: первая загрузка") { try await engine.load(fileURL: modelURL) }
        await engine.unload()
        try await measure("ИИ-анализ: повторная загрузка") { try await engine.load(fileURL: modelURL) }
        let context = await engine.contextTokens
        log("Окно контекста: \(context)")
        XCTAssertGreaterThanOrEqual(context, LLMModelSpec.lowMemoryContext)

        let input = TranscriptLLMInput.build(title: "Синтетическая планёрка",
                                             result: dialog.result.withDetail(TranscriptLLMInput.detail))
        let messages = AnalysisPromptBuilder.final(template: .sections(template), input: input,
                                                   lines: nil, notes: nil, languageName: "русский")
        let report = try await generate(engine, messages, maxTokens: LLMChunker.finalOutputReserve,
                                        label: "один проход")
        await engine.unload()

        let markdown = report.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let blocks = LightMarkdown.parse(markdown)
        XCTAssertFalse(markdown.isEmpty)
        XCTAssertTrue(blocks.contains { if case .heading = $0 { return true } else { return false } },
                      "в отчёте нет заголовков")
        XCTAssertFalse(markdown.unicodeScalars.contains { Self.isCJK($0) }, "в отчёте CJK")
        XCTAssertGreaterThan(Self.cyrillicShare(markdown), 0.5)
        let links = TimestampLinker.linkify(markdown, duration: dialog.result.duration)
            .components(separatedBy: TimestampLinker.scheme + ":").count - 1
        log("Тайм-кодов-ссылок в отчёте: \(links)")
        let reportURL = try Self.workFolder().appendingPathComponent("analysis.md")
        try markdown.write(to: reportURL, atomically: true, encoding: .utf8)
        log("Отчёт: \(reportURL.path)")

        // PDF — как «Сохранить как… → PDF» у анализа.
        let header = AnalysisPDF.Header(title: "Синтетическая планёрка", subtitle: template.name,
                                        meta: ["Запись: синтетика", "Анализ: \(LLMModelSpec.current.displayName)"])
        let pdfURL = try Self.workFolder().appendingPathComponent("analysis.pdf")
        try? FileManager.default.removeItem(at: pdfURL)
        XCTAssertTrue(AnalysisPDF.write(AnalysisPDF.document(markdown: markdown, header: header),
                                        title: header.title, to: pdfURL))
        let pdf = try XCTUnwrap(PDFDocument(url: pdfURL))
        let page = try XCTUnwrap(pdf.page(at: 0))
        let size = page.bounds(for: .mediaBox).size
        XCTAssertEqual(size.width, AnalysisPDF.paperSize.width, accuracy: 1)
        XCTAssertEqual(size.height, AnalysisPDF.paperSize.height, accuracy: 1)
        let text = pdf.string ?? ""
        XCTAssertTrue(text.contains("Синтетическая планёрка"), "заголовок не извлекается из PDF")
        XCTAssertFalse(text.contains("ĸ"), "кириллическая «к» извлекается как «ĸ»")
        log("PDF: \(pdf.pageCount) стр., \(pdfURL.path)")

        // Путь частями: окно 4k и расшифровка, повторённая несколько раз,
        // не влезают в один проход — конспекты частей и сведение.
        try await longRecordingInParts(modelURL: modelURL, dialog: dialog.result)
    }

    // MARK: - «Угадать имена» вживую

    /// Подсказка имён настоящей моделью по готовой расшифровке (без звука):
    /// представление, обращения с ответом следующей репликой, упомянутый
    /// третий человек (его имя никому давать нельзя) и спикер, на которого
    /// разметка разрезала одного человека посреди фразы.
    func testSpeakerNameSuggestions() async throws {
        let modelURL = ProcessInfo.processInfo.environment["DOKA_SMOKE_LLM"]
            .map { URL(fileURLWithPath: $0) } ?? LocalModelStore.llmFile
        try requireModel(modelURL, "языковая модель (DOKA_SMOKE_LLM)")
        let turns: [(String, Double, String)] = [
            ("speaker_0", 0, "Добрый день, коллеги. Меня зовут Анна, я руководитель проекта. Сегодня обсуждаем релиз."),
            ("speaker_0", 6, "Игорь, расскажешь, что со сборкой?"),
            ("speaker_1", 10, "Да, Анна. Сборка готова, тесты зелёные с четверга. Осталось дождаться"),
            ("speaker_3", 15, "финальных текстов от редакции, и тогда можно выпускать."),
            ("speaker_2", 20, "А Марина в курсе? Она обещала прислать отчёт по аналитике."),
            ("speaker_0", 25, "Да, Марина пришлёт отчёт в пятницу. Сергей, а у тебя что по оплате?"),
            ("speaker_2", 30, "По оплате пока не готово, нужно ещё три дня."),
            ("speaker_1", 35, "Тогда релиз переносим на понедельник."),
            ("speaker_0", 40, "Договорились. Игорь, Сергей, спасибо."),
        ]
        let segments = turns.map { TranscriptSegment(speaker: $0.0, start: $0.1, end: $0.1 + 4.5, text: $0.2) }
        let result = TranscriptResult(fullText: "", language: "ru", duration: 45, segments: segments,
                                      rawSegments: segments, words: [], llmOutput: nil)
            .withEdits(TranscriptEdits(), detail: .server)
        let prepared = try XCTUnwrap(SpeakerNameSuggester.prepare(result: result, roster: result.speakerRoster))

        let engine = LocalLLMEngine()
        try await engine.load(fileURL: modelURL)
        let options = LLMGenerationOptions(maxTokens: SpeakerNameSuggester.answerTokens,
                                           sampling: .greedy, banCJK: true)
        let answer = try await engine.generate(SpeakerNameSuggester.messages(for: prepared),
                                               options: options, emit: { _ in })
        // Выгрузка — до конца теста: освобождение Metal-ресурсов на выходе
        // процесса роняет xctest ассертом ggml.
        await engine.unload()
        log(String(format: "Имена спикеров: промпт %d ток., ответ %d ток., %.1f с", answer.promptTokens,
                   answer.generatedTokens, answer.seconds))
        log("Ответ модели: \(answer.text)")

        let suggestions = SpeakerNameSuggester.parse(answer.text, prepared: prepared)
        let names = Dictionary(uniqueKeysWithValues: suggestions.names.map { ($0.speakerID, $0.name) })
        log("Имена: \(names), объединения: \(suggestions.merges.map { "\($0.sourceID)→\($0.targetID)" })")
        XCTAssertTrue(["Анна", "Аня"].contains(names["speaker_0"] ?? ""), "ведущая представилась сама")
        XCTAssertEqual(names["speaker_1"], "Игорь", "к нему обратились, он ответил следующей репликой")
        XCTAssertEqual(names["speaker_2"], "Сергей", "обращение в конце реплики — тому, кто ответил")
        XCTAssertFalse(names.values.contains("Марина"), "Марину только упоминают — её имя никому не дают")
        XCTAssertEqual(suggestions.merges.map { [$0.sourceID, $0.targetID] }, [["speaker_3", "speaker_1"]],
                       "разрез фразы «…дождаться / финальных…» — один человек")
    }

    // MARK: - Шаблоны Memento вживую

    /// Все шаблоны установленного Memento импортируются без отказов.
    func testInstalledMementoTemplatesImport() throws {
        let folder = Self.mementoFolder
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?
            .filter { $0.hasSuffix(".json") }.sorted() ?? []
        try XCTSkipIf(names.isEmpty, "Memento не установлен")
        let files = names.map {
            AnalysisTemplateTransfer.ImportFile(fileName: $0,
                                                data: try? Data(contentsOf: folder.appendingPathComponent($0)))
        }
        let outcome = AnalysisTemplateTransfer.importFiles(files, existingNames: BuiltinAnalysisTemplate.all.map(\.name))
        log("Memento: импортировано \(outcome.templates.count) из \(names.count): "
            + outcome.templates.map { "\($0.name) (\($0.sections.count))" }.joined(separator: ", "))
        XCTAssertEqual(outcome.failures, [], "\(outcome.failures)")
        XCTAssertEqual(outcome.templates.count, names.count)
        XCTAssertTrue(outcome.templates.allSatisfy { $0.validationError == nil })
    }

    // MARK: - Синтетический диалог (общий для диаризации и анализа)

    struct Turn {
        let voice: String
        let text: String
        var start: Double = 0
        var end: Double = 0
    }

    struct Dialog {
        let turns: [Turn]
        let result: TranscriptResult
        let autoSpans: [SpeakerSpan]
        let hintedSpans: [SpeakerSpan]
    }

    private static var cachedDialog: Dialog?

    /// Планёрка двух голосов: реплики склеены в один WAV с паузами, дальше —
    /// Parakeet, локальный диаризатор и сшивка `SpeakerAssignment`, как в
    /// `FileTranscriptionController` при включённом разделении по спикерам.
    private static func dialog() async throws -> Dialog {
        if let cachedDialog { return cachedDialog }
        try requireParakeet()
        try requireModel(LocalModelStore.diarizerModelFolder, "диаризатор")

        var turns = dialogScript
        let wavURL = try workFolder().appendingPathComponent("dialog.wav")
        let writer = try WavWriter(url: wavURL)
        let pause = Data(count: WavWriter.bytesPerSecond * 7 / 10)   // 0,7 с тишины
        for index in turns.indices {
            let turn = try await speech(turns[index].text, voice: turns[index].voice, name: "dialog-\(index)")
            let pcm = try Data(contentsOf: turn.url).dropFirst(WavWriter.header(dataSize: 0).count)
            writer.append(pause)
            turns[index].start = writer.duration
            writer.append(Data(pcm))
            turns[index].end = writer.duration
        }
        writer.append(pause)
        try writer.finalize()
        let duration = writer.duration

        let engine = ParakeetLocalEngine()
        try await engine.load()
        defer { engine.unload() }
        let file = try await engine.transcribeFile(wavURL: wavURL, language: nil)

        let diarizer = LocalDiarizer()
        try await diarizer.load()
        let autoSpans = try await diarizer.diarize(wavURL: wavURL, numSpeakers: nil, progress: { _ in })
        let hintedSpans = try await diarizer.diarize(wavURL: wavURL, numSpeakers: 2, progress: { _ in })
        let segments = SpeakerAssignment.apply(spans: autoSpans, words: file.words, segments: file.segments)

        let dialog = Dialog(turns: turns,
                            result: result(file, duration: duration, segments: segments),
                            autoSpans: autoSpans, hintedSpans: hintedSpans)
        cachedDialog = dialog
        return dialog
    }

    /// Результат файла тем же путём, что у контроллера: сегменты (со
    /// спикерами) и слова, нарезка — `withDetail`.
    private static func result(_ file: LocalFileTranscription, duration: Double,
                               segments: [TranscriptSegment]) -> TranscriptResult {
        TranscriptResult(fullText: file.fullText, language: file.language, duration: duration,
                         segments: segments, rawSegments: segments, words: file.words, llmOutput: nil)
    }

    // MARK: - Анализ частями

    private func longRecordingInParts(modelURL: URL, dialog: TranscriptResult) async throws {
        let base = LLMModelSpec.current
        let small = LLMModelSpec(id: base.id, displayName: base.displayName, fileName: base.fileName,
                                 url: base.url, bytes: base.bytes, sha256: base.sha256, maxContext: 4096,
                                 assistantPrefill: base.assistantPrefill, sampling: base.sampling)
        let engine = LocalLLMEngine(spec: small)
        try await engine.load(fileURL: modelURL)

        // «Длинная запись» — расшифровка, повторённая со сдвигом времени
        // столько раз, чтобы вход в полтора раза превысил бюджет части.
        func repeated(_ copies: Int) -> TranscriptLLMInput {
            let length = (dialog.duration ?? dialog.segments.last?.end ?? 0) + 1
            var segments: [TranscriptSegment] = []
            for copy in 0..<copies {
                let shift = Double(copy) * length
                segments += dialog.segments.map {
                    TranscriptSegment(speaker: $0.speaker, start: $0.start + shift, end: $0.end + shift, text: $0.text)
                }
            }
            let long = TranscriptResult(fullText: segments.map(\.text).joined(separator: " "), language: "ru",
                                        duration: length * Double(copies), segments: segments,
                                        rawSegments: segments, words: [], llmOutput: nil)
            return TranscriptLLMInput.build(title: "Длинная планёрка", result: long)
        }
        let context = await engine.contextTokens
        let overhead = 600   // системный промпт и шапка с запасом
        let mapBudget = LLMChunker.Budget(context: context, promptOverhead: overhead,
                                          outputReserve: LLMChunker.mapOutputReserve)
        let oneCopy = try await engine.countTokens(repeated(1).lines.map(\.rendered)).reduce(0, +)
        let input = repeated(min(40, mapBudget.input * 3 / 2 / max(oneCopy, 1) + 1))
        let template = AnalysisTemplateBody.custom(prompt: "Кратко перечисли договорённости и задачи с ответственными.")
        let lineTokens = try await engine.countTokens(input.lines.map(\.rendered))
        let parts = LLMChunker.plan(lineTokens: lineTokens, budget: mapBudget.input)
        log("Частями: окно \(context), вход \(lineTokens.reduce(0, +)) ток., частей \(parts.count)")
        XCTAssertGreaterThanOrEqual(parts.count, 2, "вход должен был не влезть в один проход")
        XCTAssertEqual(parts.last?.upperBound, lineTokens.count, "план частей покрывает не весь вход")

        var notes: [AnalysisPromptBuilder.NotePart] = []
        for (index, range) in parts.enumerated() {
            let lines = input.lines[range]
            let note = try await generate(engine, AnalysisPromptBuilder.map(template: template, lines: lines,
                                                                            part: index + 1, of: parts.count,
                                                                            languageName: "русский"),
                                          maxTokens: LLMChunker.mapOutputReserve,
                                          label: "часть \(index + 1)/\(parts.count)")
            XCTAssertFalse(note.text.isEmpty)
            notes.append(.init(index: index + 1, total: parts.count,
                               start: lines.first?.start ?? 0, end: lines.last?.end ?? 0, text: note.text))
        }
        let final = try await generate(engine, AnalysisPromptBuilder.final(template: template, input: input,
                                                                           lines: nil, notes: notes,
                                                                           languageName: "русский"),
                                       maxTokens: LLMChunker.finalOutputReserve, label: "сведение")
        await engine.unload()
        XCTAssertFalse(final.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertFalse(final.text.unicodeScalars.contains { Self.isCJK($0) }, "в сведении CJK")
        try final.text.write(to: Self.workFolder().appendingPathComponent("analysis-parts.md"),
                             atomically: true, encoding: .utf8)
    }

    private func generate(_ engine: LocalLLMEngine, _ messages: [LLMMessage], maxTokens: Int,
                          label: String) async throws -> LLMGenerationResult {
        let options = LLMGenerationOptions(maxTokens: maxTokens, sampling: LLMModelSpec.current.sampling,
                                           banCJK: true)
        var finished: LLMGenerationResult?
        for try await event in engine.stream(messages, options: options) {
            if case .finished(let result) = event { finished = result }
        }
        let result = try XCTUnwrap(finished, "\(label): генерация не завершилась")
        log(String(format: "ИИ-анализ, %@: промпт %d ток., ответ %d ток., %.1f с%@", label,
                   result.promptTokens, result.generatedTokens, result.seconds,
                   result.truncated ? ", ОБОРВАН" : ""))
        return result
    }

    // MARK: - Синтез речи и окружение

    /// Фраза голосом `say` → настоящий декодер файлов → WAV 16 кГц моно.
    private static func speech(_ text: String, voice: String, name: String) async throws
        -> (url: URL, duration: TimeInterval) {
        let aiff = try workFolder().appendingPathComponent("\(name).aiff")
        try? FileManager.default.removeItem(at: aiff)
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-v", voice, "-o", aiff.path, text]
        try say.run()
        say.waitUntilExit()
        guard say.terminationStatus == 0 else {
            throw XCTSkip("say -v \(voice) не сработал (\(say.terminationStatus))")
        }
        let decoded = try await AudioFileDecoder.decodeToWav(aiff)
        let wav = try workFolder().appendingPathComponent("\(name).wav")
        try? FileManager.default.removeItem(at: wav)
        try FileManager.default.moveItem(at: decoded.url, to: wav)
        return (wav, decoded.duration)
    }

    private func speech(_ text: String, voice: String, name: String) async throws
        -> (url: URL, duration: TimeInterval) {
        try await Self.speech(text, voice: voice, name: name)
    }

    private static func workFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("doka-smoke", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static func requireModel(_ url: URL, _ name: String) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("нет модели «\(name)»: \(url.path)")
        }
    }

    private func requireModel(_ url: URL, _ name: String) throws {
        try Self.requireModel(url, name)
    }

    private static func requireParakeet() throws {
        try requireModel(LocalModelStore.parakeetFolder, "Parakeet TDT 0.6B v3")
    }

    private func requireParakeet() throws { try Self.requireParakeet() }

    private func measure(_ label: String, _ work: () async throws -> Void) async throws {
        let started = Date()
        try await work()
        log(String(format: "%@: %.1f с", label, Date().timeIntervalSince(started)))
    }

    private func log(_ text: String) {
        FileHandle.standardError.write(Data(("SMOKE " + text + "\n").utf8))
    }

    private static let mementoFolder = URL(fileURLWithPath: "/Applications/Memento.app/Contents/Resources/templates")

    private static func mementoTemplate(_ fileName: String) -> AnalysisTemplate? {
        let file = AnalysisTemplateTransfer.ImportFile(
            fileName: fileName, data: try? Data(contentsOf: mementoFolder.appendingPathComponent(fileName)))
        return AnalysisTemplateTransfer.importFiles([file], existingNames: []).templates.first
    }

    // MARK: - Текст

    /// Доля кириллицы среди букв.
    private static func cyrillicShare(_ text: String) -> Double {
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard !letters.isEmpty else { return 0 }
        let cyrillic = letters.filter { (0x0400...0x04FF).contains($0.value) }
        return Double(cyrillic.count) / Double(letters.count)
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        (0x3040...0x30FF).contains(scalar.value) || (0x3400...0x9FFF).contains(scalar.value)
            || (0xAC00...0xD7AF).contains(scalar.value)
    }

    private static let russianPhrase =
        "Сегодня мы обсуждаем запуск нового приложения для голосовой диктовки на компьютере."
    private static let englishPhrase =
        "Today we are discussing the launch of a new voice dictation app for the computer."

    private static let longRussianText = """
        Доброе утро, коллеги. Сегодня у нас короткая встреча по выпуску новой версии. \
        Сначала обсудим, что уже готово. Потом решим, кто отвечает за тестирование. \
        Сборка для внутренней проверки будет готова к среде. Документацию обновим до пятницы. \
        Если найдём ошибки, перенесём выпуск на следующую неделю. На этом всё, спасибо.
        """

    private static let dialogScript: [Turn] = [
        Turn(voice: "Milena", text: "Доброе утро. Обсуждаем выпуск новой версии приложения. Сборка будет готова к среде."),
        Turn(voice: "Eddy", text: "Good morning. I will prepare the release notes and update the website by Thursday."),
        Turn(voice: "Milena", text: "Хорошо. Тестирование беру на себя, отчёт пришлю в четверг вечером."),
        Turn(voice: "Eddy", text: "Great. If we find critical bugs, we move the release to next Monday."),
        Turn(voice: "Milena", text: "Договорились. Тогда следующая встреча в пятницу утром.")
    ]
}
