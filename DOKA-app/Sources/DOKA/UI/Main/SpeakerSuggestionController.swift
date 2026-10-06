import Combine
import Foundation

/// «Угадать имена»: языковая модель на этом Mac ищет в разговоре настоящие
/// имена спикеров и спикеров-дубликатов (`SpeakerNameSuggester`). Синглтон,
/// как `AnalysisController`: секции пересоздаются (`.id(section)`), и `@State`
/// подсказки бы не пережили. Ничего не применяет сам — только предлагает;
/// предложения живут до закрытия приложения и на диск не пишутся.
@MainActor
final class SpeakerSuggestionController: ObservableObject {
    static let shared = SpeakerSuggestionController()

    enum Phase: Equatable {
        case idle
        case running(recordID: UUID)
        /// `coveredSeconds` — запись не влезла в окно модели целиком, и
        /// подсказки сделаны по началу до этой секунды; nil — по всей записи.
        case ready(recordID: UUID, suggestions: SpeakerNameSuggester.Suggestions, coveredSeconds: Double?)
        case failed(recordID: UUID, message: String)
    }

    /// Почему подсказку нельзя запустить прямо сейчас.
    enum Availability: Equatable {
        case ok
        case modelMissing
        case busyAnalysis         // модель занята анализом — один контекст на приложение
        case busyTranscribing     // ЛОКАЛЬНОЕ распознавание — конкуренция за ускоритель
        case busyOtherRecord      // подсказка уже идёт у другой записи
        case frozen               // библиотека заморожена переносом «Папки данных»
    }

    @Published private(set) var phase: Phase = .idle
    /// Запись, у которой нажали «Угадать имена» без скачанной модели: её
    /// плашка показывает ряд скачивания прямо на месте.
    @Published private(set) var modelRequestRecordID: UUID?
    private var task: Task<Void, Never>?

    private init() {}

    var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    func availability(for recordID: UUID) -> Availability {
        guard LocalModelStore.shared.isDownloaded(.llm) else { return .modelMissing }
        guard !TranscriptHistoryStore.shared.isFrozen else { return .frozen }
        if case .running(let running) = phase, running != recordID { return .busyOtherRecord }
        if AnalysisController.shared.isRunning { return .busyAnalysis }
        if FileTranscriptionController.shared.runningUsesLocalEngine { return .busyTranscribing }
        return .ok
    }

    /// Подсказки этой записи (или nil — показывать нечего).
    func phase(for recordID: UUID) -> Phase? {
        switch phase {
        case .idle: return nil
        case .running(let id), .ready(let id, _, _), .failed(let id, _):
            return id == recordID ? phase : nil
        }
    }

    // MARK: - Запуск

    func requestModel(for recordID: UUID) {
        modelRequestRecordID = recordID
    }

    func start(document: TranscriptDocument) {
        let recordID = document.recordID
        modelRequestRecordID = nil
        guard availability(for: recordID) == .ok, !isRunning,
              let source = document.source(detail: TranscriptLLMInput.detail) else { return }
        guard let prepared = SpeakerNameSuggester.prepare(result: source, roster: source.speakerRoster) else {
            phase = .ready(recordID: recordID, suggestions: .init(), coveredSeconds: nil)
            return
        }
        let banCJK = LLMGenerationOptions.banCJK(forLanguage: source.language)
        task?.cancel()
        phase = .running(recordID: recordID)
        task = Task { [weak self] in
            await self?.run(recordID: recordID, prepared: prepared, banCJK: banCJK)
        }
    }

    /// Отмена пользователем или «сверху» (удаление модели, диктовка на маке
    /// с малой ОЗУ): ничего не меняется.
    func cancel() {
        task?.cancel()
        task = nil
        if isRunning { phase = .idle }
    }

    /// Скрыть подсказки записи.
    func dismiss(recordID: UUID) {
        if modelRequestRecordID == recordID { modelRequestRecordID = nil }
        guard phase(for: recordID) != nil else { return }
        if isRunning { cancel() } else { phase = .idle }
    }

    /// Предложение применено или отклонено — убрать его из списка.
    func resolve(_ suggestionID: String, recordID: UUID) {
        guard case .ready(let id, var suggestions, let covered) = phase, id == recordID else { return }
        suggestions.names.removeAll { $0.id == suggestionID }
        suggestions.merges.removeAll { $0.id == suggestionID }
        phase = suggestions.isEmpty
            ? .idle
            : .ready(recordID: id, suggestions: suggestions, coveredSeconds: covered)
    }

    // MARK: - Конвейер

    private func run(recordID: UUID, prepared: SpeakerNameSuggester.Prepared, banCJK: Bool) async {
        do {
            let engine = try await LocalEngineManager.shared.llmEngine()
            // Аренда: таймер простоя не выгрузит модель посреди разбора.
            LocalEngineManager.shared.beginLLMUse()
            defer { LocalEngineManager.shared.endLLMUse() }
            try Task.checkCancellation()

            let counts = try await engine.countTokens(prepared.lines.map(\.rendered))
            let budget = await engine.contextTokens
                - SpeakerNameSuggester.promptOverheadTokens - SpeakerNameSuggester.answerTokens
            let fitting = SpeakerNameSuggester.fittingLineCount(tokenCounts: counts, budget: budget)
            guard fitting > 0 else { throw LLMError.contextOverflow(needed: counts.first ?? 0, available: budget) }

            let options = LLMGenerationOptions(maxTokens: SpeakerNameSuggester.answerTokens,
                                               sampling: .greedy, banCJK: banCJK)
            let result = try await engine.generate(
                SpeakerNameSuggester.messages(for: prepared, lineCount: fitting),
                options: options, emit: { _ in })
            try Task.checkCancellation()

            let suggestions = SpeakerNameSuggester.parse(result.text, prepared: prepared)
            let covered = fitting < prepared.lines.count ? prepared.lines[fitting - 1].end : nil
            // Отменили или запустили заново, пока шла генерация, — не наш итог.
            guard case .running(let id) = phase, id == recordID else { return }
            phase = .ready(recordID: recordID, suggestions: suggestions, coveredSeconds: covered)
        } catch is CancellationError {
            return
        } catch {
            guard case .running(let id) = phase, id == recordID else { return }
            phase = .failed(recordID: recordID, message: error.localizedDescription)
        }
    }
}
