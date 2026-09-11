import AVFoundation
import Foundation

/// Архив исходного звука файловой транскрибации: звуковая дорожка файла
/// (аудио или видео) → AAC/m4a 16 кГц mono 24 кбит/с. Библиотека хранит его
/// для плеера и повторного распознавания: сам исходник может оказаться
/// гигабайтным видео, быть перемещён или лежать на съёмном диске, а архив
/// речи весит ≈ 11 МБ на час записи.
///
/// У видео архивируется ТОЛЬКО звук — картинка библиотеке не нужна
/// (дорожку выбирает общий `AudioFileDecoder.makePCMReader`). 16 кГц mono —
/// ровно тот формат, который получают движки распознавания, поэтому повторный
/// прогон по архиву ничего не теряет относительно первого.
///
/// Путь назначения выбирает вызывающий: у библиотеки своя папка, ОТДЕЛЬНАЯ от
/// `audio/` диктовки — там `AudioStore.pruneOrphans` удаляет всё, чего нет в
/// истории диктовок, и снёс бы архивы транскрибаций.
enum SourceAudioArchiver {
    /// Формат выхода ридера — тот же, что у WAV для движков.
    private static let sampleRate = Double(WavWriter.sampleRate)
    private static let channels = AVAudioChannelCount(WavWriter.channels)

    /// Кодирует звуковую дорожку source (аудио или видео) в AAC m4a 16 кГц mono 24 кбит/с по пути destination.
    /// Возвращает длительность. При любой ошибке/отмене удаляет недописанный destination и бросает.
    static func archive(source: URL, to destination: URL) async throws -> TimeInterval {
        // Кодирование — долгая CPU-работа (час записи — секунды), главному потоку
        // и интерактивным задачам она мешать не должна: отвязанная задача
        // с пониженным приоритетом, отмена внешней задачи пробрасывается внутрь.
        let worker = Task.detached(priority: .utility) {
            try await archiveWork(source: source, destination: destination)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private static func archiveWork(source: URL, destination: URL) async throws -> TimeInterval {
        do {
            let (reader, output) = try await AudioFileDecoder.makePCMReader(source, float: true)
            let frames = try encode(reader: reader, output: output, to: destination)
            return TimeInterval(frames) / sampleRate
        } catch {
            // Недописанный m4a не должен притворяться готовым архивом.
            try? FileManager.default.removeItem(at: destination)
            // `makePCMReader` глотает ошибку загрузки дорожек (`try?`), поэтому
            // отмена во время неё выглядела бы как «нет звуковой дорожки».
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    /// Перекачивает PCM из ридера в m4a, возвращает число записанных кадров.
    /// Синхронная: ожиданий внутри нет, а синхронность позволяет обернуть
    /// запись в `autoreleasepool` (см. ниже).
    private static func encode(reader: AVAssetReader,
                               output: AVAssetReaderTrackOutput,
                               to destination: URL) throws -> AVAudioFramePosition {
        // Файл закрывается ТОЛЬКО освобождением объекта: `AVAudioFile.close()`
        // появился лишь в macOS 15, а deployment target — 14. Поэтому AVAudioFile
        // живёт внутри `autoreleasepool` и гарантированно освобождается (m4a
        // дописан, заголовок на месте) ДО возврата — вызывающий сразу может
        // открыть архив на чтение или удалить его при ошибке.
        let written: AVAudioFramePosition = try autoreleasepool {
            let file = try AVAudioFile(forWriting: destination,
                                       settings: AudioStore.aacSettings(sampleRate: sampleRate,
                                                                        channels: channels),
                                       commonFormat: .pcmFormatFloat32,
                                       interleaved: false)
            // Формат обработки файла совпадает с выходом ридера
            // (Float32 non-interleaved 16 кГц mono) — AVAudioFile сам
            // кодирует PCM-буферы в AAC при записи.
            let format = file.processingFormat

            guard reader.startReading() else { throw AudioFileDecoder.DecoderError.readFailed }
            var total: AVAudioFramePosition = 0
            while let sample = output.copyNextSampleBuffer() {
                guard !Task.isCancelled else {
                    reader.cancelReading()
                    throw CancellationError()
                }
                let frames = CMSampleBufferGetNumSamples(sample)
                guard frames > 0,
                      let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                                    frameCapacity: AVAudioFrameCount(frames))
                else { continue }
                // frameLength выставляется ДО копирования: он же задаёт
                // mDataByteSize буферов, а при нуле копировать некуда.
                buffer.frameLength = AVAudioFrameCount(frames)
                let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
                    sample, at: 0, frameCount: Int32(frames),
                    into: buffer.mutableAudioBufferList)
                guard status == noErr else {
                    reader.cancelReading()
                    throw AudioFileDecoder.DecoderError.readFailed
                }
                try file.write(from: buffer)
                total += AVAudioFramePosition(frames)
            }
            return total
        }

        if reader.status == .cancelled { throw CancellationError() }
        // Пустой результат (0 кадров) — такая же ошибка чтения, как у `decodeToWav`.
        guard reader.status == .completed, written > 0 else {
            throw AudioFileDecoder.DecoderError.readFailed
        }
        return written
    }
}
