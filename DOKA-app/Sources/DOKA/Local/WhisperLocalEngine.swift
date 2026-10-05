import Foundation
import WhisperKit

/// Whisper large-v3-turbo поверх WhisperKit (CoreML: ANE/GPU/CPU).
/// Импорт WhisperKit намеренно ограничен этим файлом — у пакета свои
/// `TranscriptionResult`/`TranscriptionSegment`, не путать с типами DOKA.
@MainActor
final class WhisperLocalEngine: LocalTranscriptionEngine {
    let model = LocalModel.whisper
    private var whisperKit: WhisperKit?

    func load() async throws {
        guard whisperKit == nil else { return }
        let config = WhisperKitConfig(
            model: LocalModel.whisperKitVariant,
            downloadBase: LocalModelStore.whisperBase,
            modelFolder: LocalModelStore.whisperModelFolder.path,
            verbose: false,
            logLevel: .error,
            prewarm: true,
            load: true,
            download: false
        )
        whisperKit = try await WhisperKit(config)
    }

    /// Общий вызов декодера для диктовки и файла. Возврат false из колбэка
    /// просит декодер остановиться — Esc не ждёт конца инференса; результат
    /// отменённой задачи отбрасывается вызывающим.
    private func run(wavURL: URL, language: String?,
                     wordTimestamps: Bool) async throws -> [TranscriptionResult] {
        guard let whisperKit else { throw LocalEngineError.modelMissing }
        let options = DecodingOptions(
            task: .transcribe,
            language: language,          // nil — автоопределение
            // Без этого флага «Авто» НЕ автоопределение: при включённом
            // префилле (по умолчанию) WhisperKit подставляет английский, и
            // русская речь выходила английским ПЕРЕВОДОМ — и в диктовке с
            // языком «Авто», и в файле. Проверено на 0.18 и 1.1: с флагом
            // русская фраза даёт русский текст и `language == "ru"`.
            detectLanguage: language == nil,
            skipSpecialTokens: true,
            wordTimestamps: wordTimestamps,
            chunkingStrategy: .vad
        )
        let results = try await whisperKit.transcribe(
            audioPath: wavURL.path,
            decodeOptions: options,
            callback: { _ in Task.isCancelled ? false : nil }
        )
        try Task.checkCancellation()
        return results
    }

    func transcribeDictation(wavURL: URL, language: String?) async throws -> String {
        // Пословные тайм-коды диктовке не нужны — лишнее DTW-выравнивание.
        let results = try await run(wavURL: wavURL, language: language, wordTimestamps: false)
        let text = results.map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw TranscriptionClient.ClientError.emptyText }
        return text
    }

    func transcribeFile(wavURL: URL, language: String?) async throws -> LocalFileTranscription {
        // Слова нужны перенарезке детализации.
        let results = try await run(wavURL: wavURL, language: language, wordTimestamps: true)

        var segments: [TranscriptSegment] = []
        var words: [TranscriptWord] = []
        for result in results {
            for segment in result.segments {
                let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                segments.append(TranscriptSegment(speaker: nil,
                                                  start: Double(segment.start),
                                                  end: Double(segment.end),
                                                  text: text))
                for word in segment.words ?? [] {
                    let wordText = word.word.trimmingCharacters(in: .whitespaces)
                    guard !wordText.isEmpty else { continue }
                    words.append(TranscriptWord(text: wordText,
                                                start: Double(word.start),
                                                end: Double(word.end)))
                }
            }
        }
        let fullText = segments.map(\.text).joined(separator: " ")
        guard !fullText.isEmpty else { throw TranscriptionClient.ClientError.emptyText }
        return LocalFileTranscription(fullText: fullText,
                                      language: results.first?.language,
                                      segments: segments,
                                      words: words)
    }

    func unload() {
        whisperKit = nil
    }
}
