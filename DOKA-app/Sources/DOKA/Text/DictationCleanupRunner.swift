import Foundation

/// Прогон ИИ-обработки диктовки на языковой модели этого Mac: когда можно,
/// прогрев на время записи, генерация с таймаутом и проверка ответа. Промпт и
/// проверка — чистый `DictationCleanup`; здесь — только модель и её занятость.
/// Зовёт `DictationController`: прогрев — на старте записи, `run` — между
/// фильтром галлюцинаций и словарём замен.
@MainActor
enum DictationCleanupRunner {
    /// Можно ли обрабатывать сейчас: включено, модель скачана и не занята
    /// анализом или подсказкой имён (контекст один, а диктовка ждать минуты
    /// не должна), а на маке с малой ОЗУ — только при сетевом распознавании:
    /// речевая и языковая модели вместе уводят его в своп.
    static func isAllowed(localRecognition: Bool) -> Bool {
        let settings = SettingsStore.shared
        guard settings.dictationCleanup, LocalModelStore.shared.isDownloaded(.llm) else { return false }
        guard !AnalysisController.shared.isRunning, !SpeakerSuggestionController.shared.isRunning else { return false }
        if localRecognition && LLMModelSpec.isLowMemoryMac { return false }
        return true
    }

    /// Модель грузится, пока человек говорит (из кэша — около секунды), и к
    /// концу распознавания уже готова.
    static func prewarmIfAllowed(localRecognition: Bool) {
        guard isAllowed(localRecognition: localRecognition) else { return }
        Task { _ = try? await LocalEngineManager.shared.llmEngine() }
    }

    /// Правка модели; nil — правки нет, вставляется сырой текст: обработка
    /// выключена или недоступна, модель ещё грузится, таймаут, ответ оборван
    /// или не прошёл проверку (`DictationCleanup.validate`). Диктовка важнее
    /// правки — ошибкой это не бывает никогда.
    static func run(_ raw: String, localRecognition: Bool, language: String?) async -> String? {
        guard isAllowed(localRecognition: localRecognition) else { return nil }
        let settings = SettingsStore.shared
        let manager = LocalEngineManager.shared
        // Модель не в памяти (первая загрузка после скачивания компилирует
        // кернелы) — эту диктовку не задерживаем, грузим к следующей.
        guard manager.isLLMLoaded else {
            Task { _ = try? await manager.llmEngine() }
            NSLog("DOKA: ИИ-обработка пропущена — модель ещё загружается")
            return nil
        }
        let wishes = settings.cleanupWishes
        let rules = settings.cleanupRules
        let glossary = DictationCleanup.glossary(from: settings.replacements)
        let words = raw.dokaWordCount
        let started = Date()
        do {
            let engine = try await manager.llmEngine()
            manager.beginLLMUse()
            defer { manager.endLLMUse() }
            let inputTokens = try await engine.countTokens([raw]).first ?? words * 2
            let options = LLMGenerationOptions(maxTokens: DictationCleanup.maxTokens(inputTokens: inputTokens),
                                               sampling: .greedy,
                                               banCJK: LLMGenerationOptions.banCJK(forLanguage: language))
            let messages = DictationCleanup.messages(text: raw, wishes: wishes, rules: rules, glossary: glossary)
            // Таймаут: генерация проверяет отмену на каждом токене, поэтому
            // по истечении времени она обрывается почти сразу.
            let result = try await withThrowingTaskGroup(of: LLMGenerationResult?.self) { group in
                group.addTask { try await engine.generate(messages, options: options, emit: { _ in }) }
                group.addTask {
                    try await Task.sleep(for: .seconds(DictationCleanup.timeout(words: words)))
                    return nil
                }
                let first = try await group.next() ?? nil
                group.cancelAll()
                return first
            }
            guard let result else {
                NSLog("DOKA: ИИ-обработка не уложилась в %.0f с — вставлен исходный текст",
                      DictationCleanup.timeout(words: words))
                return nil
            }
            guard !result.truncated else { return nil }
            switch DictationCleanup.validate(raw: raw, output: result.text, wishes: wishes) {
            case .accept(let text):
                NSLog("DOKA: ИИ-обработка %d слов за %.2f с", words, Date().timeIntervalSince(started))
                return text == raw ? nil : text
            case .reject(let reason):
                NSLog("DOKA: ИИ-обработка отклонена (%@) — вставлен исходный текст", reason.rawValue)
                return nil
            }
        } catch {
            if !(error is CancellationError) {
                NSLog("DOKA: ИИ-обработка не удалась: %@", error.localizedDescription)
            }
            return nil
        }
    }
}
