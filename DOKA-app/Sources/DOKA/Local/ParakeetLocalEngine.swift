import Foundation
import FluidAudio

/// Parakeet TDT 0.6b v3 поверх FluidAudio (CoreML: ANE/CPU).
/// Импорт FluidAudio намеренно ограничен этим файлом.
@MainActor
final class ParakeetLocalEngine: LocalTranscriptionEngine {
    let model = LocalModel.parakeet
    private var manager: AsrManager?

    func load() async throws {
        guard manager == nil else { return }
        let models = try await AsrModels.load(from: LocalModelStore.parakeetFolder)
        manager = AsrManager(config: .default, models: models)
    }

    func transcribeDictation(wavURL: URL, language: String?) async throws -> String {
        // Тот же инференс, что и у файла; лишний маппинг токенов в слова для
        // секундной диктовки копеечный — дублировать пролог ради него не стоит.
        try await transcribeFile(wavURL: wavURL, language: language).fullText
    }

    func transcribeFile(wavURL: URL, language: String?) async throws -> LocalFileTranscription {
        guard let manager else { throw LocalEngineError.modelMissing }
        // Свежее состояние декодера на каждый запуск: записи независимы.
        var decoderState = try TdtDecoderState()
        // Подсказка языка — только фильтр по письменности (v3); незнакомый
        // код тихо превращается в nil = полное автоопределение.
        let hint = language.flatMap { Language(rawValue: $0) }
        let result = try await manager.transcribe(wavURL, decoderState: &decoderState, language: hint)
        try Task.checkCancellation()

        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw TranscriptionClient.ClientError.emptyText }

        // Токены → слова: у sentencepiece «▁» помечает начало слова, пунктуация
        // приходит отдельными токенами и приклеивается к текущему слову.
        var words: [TranscriptWord] = []
        var current = ""
        var start: TimeInterval = 0
        var end: TimeInterval = 0
        func flush() {
            let trimmed = current.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                words.append(TranscriptWord(text: trimmed, start: start, end: end))
            }
            current = ""
        }
        for timing in result.tokenTimings ?? [] {
            let isWordStart = timing.token.hasPrefix("▁")
            let piece = timing.token.replacingOccurrences(of: "▁", with: "")
            if isWordStart || current.isEmpty {
                flush()
                current = piece
                start = timing.startTime
            } else {
                current += piece
            }
            end = timing.endTime
        }
        flush()

        // Parakeet не делит текст на предложения — отдаём один сегмент на всю
        // запись; красивую нарезку по предложениям делает TranscriptSegmentSplitter
        // из пословных тайм-кодов (withDetail на стороне контроллера).
        let segmentEnd = words.last?.end ?? result.duration
        let segment = TranscriptSegment(speaker: nil,
                                        start: words.first?.start ?? 0,
                                        end: segmentEnd,
                                        text: text)
        return LocalFileTranscription(fullText: text,
                                      language: nil,   // ASRResult язык не сообщает
                                      segments: [segment],
                                      words: words)
    }

    func unload() {
        manager = nil
    }
}
