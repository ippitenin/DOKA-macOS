import Foundation

/// Выходной слой расшифровки файла: «Словарь» поверх того, что пользователь
/// видит и забирает (показ, «Скопировать», «Сохранить как…»).
///
/// Результат ТЕРМИНАЛЬНЫЙ: его нельзя класть в фазу контроллера или журнал и
/// нельзя звать на нём `withDetail` — перенарезка пересобирает текст из
/// `rawSegments`/`words`, и замены пропадут. Хранится всегда сырой результат,
/// поэтому выключение тумблера мгновенно возвращает исходник.
enum TranscriptOutput {
    /// Замены в отображаемых сегментах и `fullText`. `rawSegments`, `words`,
    /// `llmOutput` и правки не трогаются; спикер и тайм-коды сегментов
    /// сохраняются. Правленый текст тоже проходит через словарь — это решение
    /// плана: словарь — линза над всем выводом.
    static func applyingDictionary(_ result: TranscriptResult,
                                   rules: [ReplacementRule]) -> TranscriptResult {
        guard rules.contains(where: { $0.enabled && !$0.from.isEmpty }) else { return result }
        let apply = { (text: String) in ReplacementEngine.apply(text, rules: rules) }
        return TranscriptResult(
            fullText: apply(result.fullText),
            language: result.language,
            duration: result.duration,
            segments: result.segments.map {
                TranscriptSegment(speaker: $0.speaker, start: $0.start, end: $0.end,
                                  text: apply($0.text))
            },
            rawSegments: result.rawSegments,
            words: result.words,
            llmOutput: result.llmOutput,
            edits: result.edits,
            segmentTargets: result.segmentTargets,
            editedFullText: result.editedFullText.map(apply)
        )
    }

    /// Единая точка выхода: применяет словарь, только если пользователь
    /// включил «Применять словарь замен» (по умолчанию выключено — изоляция
    /// пайплайна файлов от диктовки сохраняется).
    @MainActor
    static func prepare(_ result: TranscriptResult) -> TranscriptResult {
        let settings = SettingsStore.shared
        guard settings.applyDictionaryToFiles else { return result }
        return applyingDictionary(result, rules: settings.replacements)
    }
}
