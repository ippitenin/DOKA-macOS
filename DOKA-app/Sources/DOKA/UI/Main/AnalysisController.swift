import Combine
import Foundation

/// Локальный ИИ-анализ записи: один анализ на приложение, состояние живёт в
/// синглтоне. Как `FileTranscriptionController`: секции пересоздаются
/// (`.id(section)`), и `@State` внутри вью анализ бы не пережил.
@MainActor
final class AnalysisController: ObservableObject {
    static let shared = AnalysisController()

    /// Стадия работы — то, что видно в полосе прогресса.
    enum Stage: Equatable {
        case loadingModel              // загрузка модели и компиляция кернелов
        case reading(Double)           // разбор расшифровки, доля 0…1
        case part(Int, of: Int, Double)   // конспект части длинной записи
        case combining                 // сведение конспектов
        case writing                   // модель пишет отчёт
    }

    struct Run: Equatable {
        let recordID: UUID
        let title: String
        var stage: Stage
        /// Текст, написанный к этому моменту (показывается живьём).
        var partial: String
    }

    enum Phase: Equatable {
        case idle
        case running(Run)
        case failed(recordID: UUID, message: String)
    }

    /// Почему анализ нельзя запустить прямо сейчас.
    enum Availability: Equatable {
        case ok
        case modelMissing
        case busyTranscribing      // идёт ЛОКАЛЬНОЕ распознавание — конкуренция за ANE/GPU
        case busyOtherRecord       // анализ уже идёт, но у другой записи
        case emptyTranscript
        case notReady              // запись ещё не готова или тела нет
        case frozen                // библиотека заморожена переносом «Папки данных»

        var isRunnable: Bool { self == .ok }
    }

    /// Что именно просим у модели.
    struct Request: Equatable {
        enum Kind: Equatable {
            case template(AnalysisTemplate)
            case custom(String)
        }
        let kind: Kind
        /// ISO-код языка ответа; nil — «как в записи».
        let responseLanguage: String?
    }

    @Published private(set) var phase: Phase = .idle

    private var task: Task<Void, Never>?
    /// Троттлинг живого текста: без него SwiftUI и разбор Markdown работали бы
    /// на каждый токен.
    private static let partialInterval: TimeInterval = 0.12

    private init() {}

    var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    var runningRecordID: UUID? {
        if case .running(let run) = phase { return run.recordID }
        return nil
    }

    // MARK: - Доступность

    func availability(for record: FileTranscriptRecord?) -> Availability {
        guard let record, record.isDone else { return .notReady }
        guard LocalModelStore.shared.isDownloaded(.llm) else { return .modelMissing }
        guard !TranscriptHistoryStore.shared.isFrozen else { return .frozen }
        if let running = runningRecordID, running != record.id { return .busyOtherRecord }
        // Конкурируем за один и тот же ускоритель только с ЛОКАЛЬНЫМ
        // распознаванием; сетевое и диктовка анализу не мешают.
        //
        // Смотрим на маршрут ИДУЩЕГО прогона, а не на глобальный providerID:
        // запуск из библиотеки идёт по снимку params.providerID, и глобальная
        // настройка к нему отношения не имеет. Прежняя проверка ошибалась в обе
        // стороны — пропускала анализ поверх локального распознавания (Qwen на
        // Metal против Parakeet на ANE) и блокировала его при сетевом.
        if FileTranscriptionController.shared.runningUsesLocalEngine {
            return .busyTranscribing
        }
        if let summary = record.summary, summary.wordCount == 0 { return .emptyTranscript }
        return .ok
    }

    // MARK: - Запуск

    /// Запускает анализ записи. Возвращает false, если запуск невозможен —
    /// причину вызывающий уже знает из `availability`.
    @discardableResult
    func start(recordID: UUID, request: Request) -> Bool {
        let store = TranscriptHistoryStore.shared
        guard let record = store.record(recordID), availability(for: record).isRunnable else {
            return false
        }
        task?.cancel()
        let title = record.displayTitle
        phase = .running(Run(recordID: recordID, title: title, stage: .loadingModel, partial: ""))
        task = Task { [weak self] in
            await self?.run(recordID: recordID, title: title, request: request)
        }
        return true
    }

    /// Отмена пользователем: ничего не сохраняется.
    func cancel() {
        task?.cancel()
        task = nil
        phase = .idle
    }

    /// Отмена «сверху» (удаление модели, старт диктовки на маке с малой ОЗУ):
    /// в отличие от `cancel()` оставляет в панели объяснение.
    func cancelIfRunning(message: String? = nil) {
        guard case .running(let run) = phase else { return }
        task?.cancel()
        task = nil
        phase = message.map { .failed(recordID: run.recordID, message: $0) } ?? .idle
    }

    /// Фазу этой записи в исходное: панель перестаёт показывать ошибку.
    func dismiss(recordID: UUID) {
        if case .failed(let id, _) = phase, id == recordID { phase = .idle }
        if case .running(let run) = phase, run.recordID == recordID { cancel() }
    }

    // MARK: - Конвейер

    private func run(recordID: UUID, title: String, request: Request) async {
        let store = TranscriptHistoryStore.shared
        do {
            guard let body = await store.loadBody(recordID) else {
                throw AnalysisError.message(L("transcribe.recordMissing"))
            }
            try Task.checkCancellation()

            let input = Self.makeInput(title: title, body: body)
            guard !input.isEmpty else { throw AnalysisError.message(L("analysis.error.empty")) }

            let engine = try await LocalEngineManager.shared.llmEngine()
            // Аренда на весь конвейер: без неё таймер простоя (3 мин) выгрузил
            // бы модель посреди map-reduce, и следующий проход упал бы
            // «модель не загружена» после минут работы.
            LocalEngineManager.shared.beginLLMUse()
            defer { LocalEngineManager.shared.endLLMUse() }
            try Task.checkCancellation()

            let languageName = Self.languageName(request: request, body: body,
                                                 record: store.record(recordID))
            let banCJK = !Self.isCJKLanguage(Self.languageCode(request: request, body: body,
                                                              record: store.record(recordID)))
            let template: AnalysisTemplateBody = {
                switch request.kind {
                case .template(let value): return .sections(value)
                case .custom(let prompt): return .custom(prompt: prompt)
                }
            }()

            let context = await engine.contextTokens
            let lineTokens = try await engine.countTokens(input.lines.map(\.rendered))
            try Task.checkCancellation()

            let started = Date()
            let result = try await produce(engine: engine, input: input, lineTokens: lineTokens,
                                           context: context, template: template,
                                           languageName: languageName, banCJK: banCJK,
                                           recordID: recordID)
            try Task.checkCancellation()

            let markdown = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !markdown.isEmpty else { throw AnalysisError.message(L("analysis.error.empty")) }

            let analysis = StoredAnalysis(
                title: Self.analysisTitle(request),
                templateID: Self.templateID(request),
                source: .local(modelID: LLMModelSpec.current.id),
                markdown: markdown,
                responseLanguage: Self.languageCode(request: request, body: body,
                                                    record: store.record(recordID)),
                inputFingerprint: input.fingerprint,
                truncated: result.truncated,
                generationSeconds: Date().timeIntervalSince(started))
            // Сохранить может не получиться: запись удалили, пока шёл анализ,
            // либо библиотеку заморозил перенос «Папки данных». Раньше
            // результат просто игнорировался, и отчёт после 10–15 минут работы
            // модели исчезал без единого слова. Теперь молчим только если
            // сохранять действительно некуда (запись удалена).
            let saved = await store.addAnalysis(analysis, to: recordID)
            guard !Task.isCancelled else { return }
            if !saved, store.record(recordID) != nil {
                phase = .failed(recordID: recordID, message: L("analysis.error.notSaved"))
                return
            }
            phase = .idle
        } catch is CancellationError {
            // Отмена уже перевела фазу — здесь ничего не трогаем.
        } catch {
            guard !Task.isCancelled else { return }
            phase = .failed(recordID: recordID, message: Self.message(for: error))
        }
    }

    /// Один проход или map-reduce — решает план чанкера.
    private func produce(engine: LocalLLMEngine, input: TranscriptLLMInput, lineTokens: [Int],
                         context: Int, template: AnalysisTemplateBody, languageName: String,
                         banCJK: Bool, recordID: UUID) async throws -> LLMGenerationResult {
        let overhead = Self.promptOverhead(template: template, input: input)
        let finalBudget = LLMChunker.Budget(context: context, promptOverhead: overhead,
                                            outputReserve: LLMChunker.finalOutputReserve)
        // Не «> 0», а осмысленный минимум: шаблон из двенадцати разделов с
        // длинными инструкциями на маке с окном 8k может съесть почти всё, и
        // анализ по тремстам токенам расшифровки — это не отчёт.
        guard finalBudget.input >= Self.minimumInputBudget else {
            throw AnalysisError.message(L("analysis.error.contextTooSmall"))
        }

        // Всё влезает — один проход.
        if lineTokens.reduce(0, +) <= finalBudget.input {
            let messages = AnalysisPromptBuilder.final(template: template, input: input,
                                                       lines: nil, notes: nil,
                                                       languageName: languageName)
            return try await generate(engine: engine, messages: messages, banCJK: banCJK,
                                      maxTokens: LLMChunker.finalOutputReserve,
                                      recordID: recordID, streamsText: true,
                                      readingStage: { .reading($0) })
        }

        // ── map: конспект каждой части.
        let mapBudget = LLMChunker.Budget(context: context, promptOverhead: overhead,
                                          outputReserve: LLMChunker.mapOutputReserve)
        guard mapBudget.input >= Self.minimumInputBudget else {
            throw AnalysisError.message(L("analysis.error.contextTooSmall"))
        }
        let parts = LLMChunker.plan(lineTokens: lineTokens, budget: mapBudget.input)
        guard !parts.isEmpty else { throw AnalysisError.message(L("analysis.error.empty")) }
        // План обязан покрывать ВЕСЬ вход и целиком укладываться в бюджет:
        // усечённый план молча проанализировал бы кусок расшифровки вместо всей.
        guard parts.count <= LLMChunker.maxParts,
              parts.last?.upperBound == lineTokens.count,
              parts.allSatisfy({ lineTokens[$0].reduce(0, +) <= mapBudget.input }) else {
            throw AnalysisError.message(L("analysis.error.tooLong"))
        }
        // Сведение проверяется ЗАРАНЕЕ: бюджет сведения меньше на шапки
        // конспектов, и узнать о его нехватке после всех map-проходов —
        // значит выбросить десятки минут работы.
        let reduceBudget = LLMChunker.Budget(
            context: context,
            promptOverhead: overhead + Self.notesOverhead(parts: parts.count),
            outputReserve: LLMChunker.finalOutputReserve)
        guard reduceBudget.input >= parts.count * LLMChunker.mapOutputReserve else {
            throw AnalysisError.message(L("analysis.error.tooLong"))
        }

        var notes: [AnalysisPromptBuilder.NotePart] = []
        for (index, range) in parts.enumerated() {
            try Task.checkCancellation()
            let lines = input.lines[range]
            let messages = AnalysisPromptBuilder.map(template: template, lines: lines,
                                                     part: index + 1, of: parts.count,
                                                     languageName: languageName)
            let note = try await generate(engine: engine, messages: messages, banCJK: banCJK,
                                          maxTokens: LLMChunker.mapOutputReserve,
                                          recordID: recordID, streamsText: false,
                                          readingStage: { .part(index + 1, of: parts.count, $0) })
            notes.append(AnalysisPromptBuilder.NotePart(
                index: index + 1, total: parts.count,
                start: lines.first?.start ?? 0, end: lines.last?.end ?? 0,
                text: note.text))
        }

        // ── reduce: сведение конспектов в отчёт. Глубже одного уровня не
        // идём: два уровня сведения — это пересказ пересказа.
        update(recordID: recordID) { $0.stage = .combining }
        let noteTokens = try await engine.countTokens(notes.map(\.text))
        guard let groups = LLMChunker.reduceGroups(noteTokens: noteTokens, budget: reduceBudget.input),
              groups.count == 1 else {
            throw AnalysisError.message(L("analysis.error.tooLong"))
        }
        let messages = AnalysisPromptBuilder.final(template: template, input: input,
                                                   lines: nil, notes: notes,
                                                   languageName: languageName)
        return try await generate(engine: engine, messages: messages, banCJK: banCJK,
                                  maxTokens: LLMChunker.finalOutputReserve,
                                  recordID: recordID, streamsText: true,
                                  readingStage: { .reading($0) })
    }

    /// Один запрос к модели с обновлением стадии и живым текстом.
    private func generate(engine: LocalLLMEngine, messages: [LLMMessage], banCJK: Bool,
                          maxTokens: Int, recordID: UUID, streamsText: Bool,
                          readingStage: @escaping (Double) -> Stage) async throws -> LLMGenerationResult {
        let options = LLMGenerationOptions(maxTokens: maxTokens,
                                           sampling: LLMModelSpec.current.sampling,
                                           banCJK: banCJK)
        var text = ""
        var lastPublished = Date.distantPast
        var finished: LLMGenerationResult?

        for try await event in engine.stream(messages, options: options) {
            switch event {
            case .prefill(let fraction):
                update(recordID: recordID) { $0.stage = readingStage(fraction) }
            case .text(let piece):
                guard streamsText else { continue }
                text += piece
                // Не чаще раза в 120 мс: разбор Markdown на каждый токен
                // съел бы больше, чем сама генерация.
                guard Date().timeIntervalSince(lastPublished) >= Self.partialInterval else { continue }
                lastPublished = Date()
                update(recordID: recordID) { run in
                    run.stage = .writing
                    run.partial = text
                }
            case .finished(let result):
                finished = result
            }
        }
        guard let finished else { throw AnalysisError.message(L("analysis.error.empty")) }
        if streamsText {
            update(recordID: recordID) { run in
                run.stage = .writing
                run.partial = finished.text
            }
        }
        return finished
    }

    /// Обновление фазы, только если идёт анализ ТОЙ ЖЕ записи: отменённый
    /// анализ не должен воскресать запоздавшим событием движка.
    private func update(recordID: UUID, _ change: (inout Run) -> Void) {
        guard case .running(var run) = phase, run.recordID == recordID else { return }
        change(&run)
        phase = .running(run)
    }

    // MARK: - Вспомогательное

    private enum AnalysisError: LocalizedError {
        case message(String)
        var errorDescription: String? {
            switch self { case .message(let text): return text }
        }
    }

    private static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    /// Вход модели: правки применены, словарь замен — если он включён
    /// (тот же выходной слой, что у показа и экспорта). Отпечаток при этом
    /// считается от текста без словаря.
    static func makeInput(title: String, body: TranscriptBody) -> TranscriptLLMInput {
        let source = body.makeResult(detail: TranscriptLLMInput.detail)
        let settings = SettingsStore.shared
        guard settings.applyDictionaryToFiles, !settings.replacements.isEmpty else {
            return TranscriptLLMInput.build(title: title, result: source)
        }
        let lensed = TranscriptOutput.applyingDictionary(source, rules: settings.replacements)
        return TranscriptLLMInput.build(title: title, result: lensed, fingerprintSource: source)
    }

    /// Оценка накладных расходов промпта в токенах: системное сообщение,
    /// шапка и описания разделов. Считаем по символам (грубо, зато без
    /// обращения к движку) и с запасом — недооценка стоила бы переполнения
    /// контекста, переоценка — лишь чуть более мелкой нарезки.
    private static func promptOverhead(template: AnalysisTemplateBody,
                                       input: TranscriptLLMInput) -> Int {
        let messages = AnalysisPromptBuilder.final(template: template, input: input,
                                                   lines: input.lines.prefix(0),
                                                   notes: nil, languageName: "Русский")
        let characters = messages.reduce(0) { $0 + $1.content.count }
        // ~2 символа на токен для кириллицы плюс постоянный запас на шаблон чата.
        return characters / 2 + 128
    }

    /// Ниже этого числа токенов входа отчёт не имеет смысла.
    private static let minimumInputBudget = 512

    /// Надбавка к накладным расходам для шага сведения: заголовок блока
    /// конспектов плюс шапка «Часть N из M (м:сс–м:сс):» на каждую часть.
    /// Без неё бюджет сведения завышен, и на полутора десятках частей запас
    /// `Budget.safety` съедается целиком — движок отдаёт contextOverflow уже
    /// ПОСЛЕ всех map-проходов.
    private static func notesOverhead(parts: Int) -> Int {
        guard parts > 0 else { return 0 }
        let header = L("analysis.prompt.notesHeader").count
        let part = L("analysis.prompt.notePart", 88, 88, "88:88", "88:88").count + 2
        return (header + part * parts) / 2 + 32
    }

    private static func analysisTitle(_ request: Request) -> String {
        switch request.kind {
        case .template(let template): return template.name
        case .custom: return L("analysis.customPrompt")
        }
    }

    private static func templateID(_ request: Request) -> String? {
        switch request.kind {
        case .template(let template): return template.id
        case .custom: return nil
        }
    }

    /// Код языка ответа: явный выбор, иначе язык записи, иначе язык интерфейса.
    static func languageCode(request: Request, body: TranscriptBody?,
                             record: FileTranscriptRecord?) -> String {
        if let explicit = request.responseLanguage, !explicit.isEmpty, explicit != "auto" {
            return explicit
        }
        let detected = body?.transcript.language ?? record?.language
        if let detected, !detected.isEmpty, detected != "auto" { return detected }
        return interfaceLanguageCode
    }

    static func languageName(request: Request, body: TranscriptBody?,
                             record: FileTranscriptRecord?) -> String {
        let code = languageCode(request: request, body: body, record: record)
        if let known = TranscriptionLanguage.all.first(where: { $0.id == code }) { return known.title }
        // Неизвестный сервису код (модель распознала экзотический язык) —
        // отдаём системное название, оно понятнее модели, чем «xx».
        return Locale.current.localizedString(forLanguageCode: code) ?? code
    }

    static var interfaceLanguageCode: String {
        switch SettingsStore.shared.appLanguage {
        case .ru: return "ru"
        case .en: return "en"
        case .system:
            return Bundle.module.preferredLocalizations.first ?? "en"
        }
    }

    private static func isCJKLanguage(_ code: String) -> Bool {
        ["zh", "ja", "ko"].contains(code.lowercased().prefix(2).description)
    }
}
