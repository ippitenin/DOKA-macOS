import Foundation
import AVFoundation

/// Извлечение звуковой дорожки из аудио/видеофайла в WAV 16 кГц mono Int16
/// (формат `WavWriter`) — единый вход локальных движков: нормализует и
/// mp3/m4a/flac, и видеоконтейнеры mp4/mov, которые сами движки не читают.
/// Сервер Nexara декодирует видео на своей стороне — локально это наша работа.
enum AudioFileDecoder {
    enum DecoderError: LocalizedError {
        case noAudioTrack
        case readFailed

        var errorDescription: String? {
            switch self {
            case .noAudioTrack: return L("transcribe.local.noAudioTrack")
            case .readFailed: return L("transcribe.error.readFailed")
            }
        }
    }

    /// Декодирует файл во временный WAV; вызывающий удаляет файл сам.
    /// Работа идёт в отвязанной задаче (не блокирует главный поток),
    /// отмена внешней задачи пробрасывается внутрь.
    static func decodeToWav(_ sourceURL: URL) async throws -> (url: URL, duration: TimeInterval) {
        let worker = Task.detached(priority: .userInitiated) {
            try await decodeWork(sourceURL)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    /// Ридер PCM по ПЕРВОЙ звуковой дорожке файла: у видео берётся только звук,
    /// картинка не декодируется вовсе. Выход всегда 16 кГц mono
    /// (`WavWriter.sampleRate/channels`) — ресэмплинг и сведение каналов делает
    /// AVFoundation. `float == false` — Int16 interleaved little-endian, ровно
    /// тело WAV диктовки (`decodeToWav`); `float == true` — Float32
    /// non-interleaved, формат `AVAudioPCMBuffer` для кодирования в AAC
    /// (`SourceAudioArchiver`). Общий хелпер, чтобы оба пути одинаково выбирали
    /// дорожку и одинаково падали. `startReading()` зовёт вызывающий.
    static func makePCMReader(_ url: URL, float: Bool) async throws
        -> (reader: AVAssetReader, output: AVAssetReaderTrackOutput) {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first else {
            throw DecoderError.noAudioTrack
        }

        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: WavWriter.sampleRate,
            AVNumberOfChannelsKey: WavWriter.channels,
            AVLinearPCMBitDepthKey: float ? 32 : WavWriter.bitsPerSample,
            AVLinearPCMIsFloatKey: float,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: float
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw DecoderError.readFailed }
        reader.add(output)
        return (reader, output)
    }

    private static func decodeWork(_ sourceURL: URL) async throws -> (url: URL, duration: TimeInterval) {
        let (reader, output) = try await makePCMReader(sourceURL, float: false)

        let wavURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("doka-local-\(UUID().uuidString).wav")
        let writer = try WavWriter(url: wavURL)

        guard reader.startReading() else {
            writer.cancelAndDelete()
            throw DecoderError.readFailed
        }
        while let sample = output.copyNextSampleBuffer() {
            guard !Task.isCancelled else {
                reader.cancelReading()
                writer.cancelAndDelete()
                throw CancellationError()
            }
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            var length = 0
            var pointer: UnsafeMutablePointer<Int8>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                              totalLengthOut: &length,
                                              dataPointerOut: &pointer) == kCMBlockBufferNoErr,
                  let pointer else { continue }
            writer.append(Data(bytes: pointer, count: length))
        }
        guard reader.status == .completed, writer.dataBytes > 0 else {
            writer.cancelAndDelete()
            if reader.status == .cancelled { throw CancellationError() }
            throw DecoderError.readFailed
        }
        let duration = writer.duration
        try writer.finalize()
        return (wavURL, duration)
    }
}
