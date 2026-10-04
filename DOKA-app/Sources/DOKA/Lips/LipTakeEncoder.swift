import AVFoundation
import CoreImage
import Foundation
import os

/// Второй проход дубля губ: сырое полнокадровое видео → `clip.mp4` для
/// обучения. Один фиксированный кроп на весь дубль, масштаб в 512×512,
/// H.264 постоянной частоты 30 к/с по шкале WAV и AAC-дорожка из WAV
/// диктовки целиком. Звуковая дорожка обязательна: без неё препроцессинг
/// WISLIP виснет. Кадр в файле без зеркала, без rotation.
///
/// Тяжёлая работа — отвязанная задача с пониженным приоритетом; отмена
/// пробрасывается внутрь и удаляет недописанный файл (паттерн
/// `SourceAudioArchiver`).
enum LipTakeEncoder {
    struct Input {
        var rawVideo: URL
        /// Метки исходных кадров в `raw.mp4` (сек), по индексам расписания.
        var sourcePTS: [Double]
        var schedule: LipSchedule
        /// Кроп в пикселях кадра камеры, начало сверху слева.
        var crop: CGRect
        var audio: URL
        var output: URL
    }

    enum EncoderError: LocalizedError {
        case noVideoTrack
        case writerFailed(String)

        var errorDescription: String? {
            switch self {
            case .noVideoTrack: return "raw video has no video track"
            case .writerFailed(let message): return message
            }
        }
    }

    static let side = 512
    /// ~0,8 Мбит/с: лицо на неподвижном фоне, S3FD и MediaPipe в WISLIP
    /// этого хватает; объём — около 4 ГБ на месяц диктовок.
    static let videoBitRate = 800_000

    /// Без управления цветом: кроп и масштаб YUV → YUV, никаких пересчётов гаммы.
    private static let context = CIContext(options: [
        .workingColorSpace: NSNull(),
        .outputColorSpace: NSNull(),
        .cacheIntermediates: false
    ])

    static func encode(_ input: Input) async throws {
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        let worker = Task.detached(priority: .utility) {
            try await encodeWork(input, cancelled: cancelled)
        }
        try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            cancelled.withLock { $0 = true }
            worker.cancel()
        }
    }

    private static func encodeWork(_ input: Input, cancelled: OSAllocatedUnfairLock<Bool>) async throws {
        do {
            if Task.isCancelled { throw CancellationError() }
            try await write(input, cancelled: cancelled)
            if cancelled.withLock({ $0 }) { throw CancellationError() }
        } catch {
            try? FileManager.default.removeItem(at: input.output)
            if Task.isCancelled || cancelled.withLock({ $0 }) { throw CancellationError() }
            throw error
        }
    }

    private static func write(_ input: Input, cancelled: OSAllocatedUnfairLock<Bool>) async throws {
        // Ридер сырого видео — 420v, родной формат камеры.
        let asset = AVURLAsset(url: input.rawVideo)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw EncoderError.noVideoTrack
        }
        let videoReader = try AVAssetReader(asset: asset)
        let videoOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ])
        videoOutput.alwaysCopiesSampleData = false
        videoReader.add(videoOutput)

        // Ридер WAV — тот же выбор дорожки и формат, что у остального кода.
        let (audioReader, audioOutput) = try await AudioFileDecoder.makePCMReader(input.audio, float: false)

        try? FileManager.default.removeItem(at: input.output)
        let writer = try AVAssetWriter(outputURL: input.output, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: side,
            AVVideoHeightKey: side,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: videoBitRate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoMaxKeyFrameIntervalKey: 30,
                AVVideoAllowFrameReorderingKey: false,
                AVVideoExpectedSourceFrameRateKey: 30
            ]
        ])
        videoInput.expectsMediaDataInRealTime = false
        videoInput.transform = .identity
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: side,
            kCVPixelBufferHeightKey as String: side,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
        ])
        let audioInput = AVAssetWriterInput(mediaType: .audio,
                                            outputSettings: AudioStore.aacSettings(sampleRate: Double(WavWriter.sampleRate),
                                                                                   channels: AVAudioChannelCount(WavWriter.channels)))
        audioInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput), writer.canAdd(audioInput) else {
            throw EncoderError.writerFailed("cannot add writer inputs")
        }
        writer.add(videoInput)
        writer.add(audioInput)

        guard videoReader.startReading(), audioReader.startReading() else {
            throw EncoderError.writerFailed("cannot start readers")
        }
        guard writer.startWriting() else {
            throw EncoderError.writerFailed(writer.error?.localizedDescription ?? "cannot start writer")
        }
        writer.startSession(atSourceTime: .zero)

        let frames = VideoFrames(input: input, reader: videoOutput, adaptor: adaptor)
        let pipe = Pipeline(writer: writer, videoInput: videoInput, audioInput: audioInput,
                            audioOutput: audioOutput, frames: frames,
                            total: input.schedule.sourceIndex.count, cancelled: cancelled)

        // Дорожки пишутся параллельно: подряд AVAssetWriter встал бы на
        // чередовании (ждёт данных той дорожки, которую ещё не начали).
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let group = DispatchGroup()
            group.enter()
            group.enter()
            videoInput.requestMediaDataWhenReady(on: DispatchQueue(label: "com.pitenin.doka.lips.encode.video")) {
                if pipe.pumpVideo() { group.leave() }
            }
            audioInput.requestMediaDataWhenReady(on: DispatchQueue(label: "com.pitenin.doka.lips.encode.audio")) {
                if pipe.pumpAudio() { group.leave() }
            }
            group.notify(queue: .global(qos: .utility)) { continuation.resume() }
        }

        let total = input.schedule.sourceIndex.count
        let fps = Int32(LipSync.outputFps)
        if cancelled.withLock({ $0 }) {
            writer.cancelWriting()
            videoReader.cancelReading()
            audioReader.cancelReading()
            throw CancellationError()
        }
        guard writer.status == .writing, frames.failure == nil else {
            writer.cancelWriting()
            throw EncoderError.writerFailed(frames.failure ?? writer.error?.localizedDescription ?? "writer failed")
        }
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(total), timescale: fps))
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw EncoderError.writerFailed(writer.error?.localizedDescription ?? "finish failed")
        }
    }

    /// Писатель и обе дорожки для колбэков `requestMediaDataWhenReady`. Каждая
    /// дорожка трогает только своё (видео — `frames`, звук — `audioOutput`),
    /// каждая на своей последовательной очереди.
    private final class Pipeline: @unchecked Sendable {
        let writer: AVAssetWriter
        let videoInput: AVAssetWriterInput
        let audioInput: AVAssetWriterInput
        let audioOutput: AVAssetReaderTrackOutput
        let frames: VideoFrames
        let total: Int
        let cancelled: OSAllocatedUnfairLock<Bool>
        private var videoDone = false
        private var audioDone = false

        init(writer: AVAssetWriter, videoInput: AVAssetWriterInput, audioInput: AVAssetWriterInput,
             audioOutput: AVAssetReaderTrackOutput, frames: VideoFrames, total: Int,
             cancelled: OSAllocatedUnfairLock<Bool>) {
            self.writer = writer
            self.videoInput = videoInput
            self.audioInput = audioInput
            self.audioOutput = audioOutput
            self.frames = frames
            self.total = total
            self.cancelled = cancelled
        }

        private var stopped: Bool { cancelled.withLock { $0 } || writer.status != .writing }

        /// true — видео-дорожка закончилась (ровно один раз).
        func pumpVideo() -> Bool {
            let fps = Int32(LipSync.outputFps)
            while videoInput.isReadyForMoreMediaData && !videoDone {
                let k = frames.next
                let ok = k < total && !stopped && autoreleasepool {
                    frames.append(output: k, at: CMTime(value: CMTimeValue(k), timescale: fps))
                }
                if !ok {
                    videoDone = true
                    videoInput.markAsFinished()
                    return true
                }
            }
            return false
        }

        /// true — звуковая дорожка закончилась (ровно один раз).
        func pumpAudio() -> Bool {
            while audioInput.isReadyForMoreMediaData && !audioDone {
                guard !stopped, let sample = audioOutput.copyNextSampleBuffer(), audioInput.append(sample) else {
                    audioDone = true
                    audioInput.markAsFinished()
                    return true
                }
            }
            return false
        }
    }

    /// Состояние видео-дорожки второго прохода: живёт на очереди её писателя.
    private final class VideoFrames: @unchecked Sendable {
        private let input: Input
        private let reader: AVAssetReaderTrackOutput
        private let adaptor: AVAssetWriterInputPixelBufferAdaptor
        /// Номер следующего выходного кадра.
        private(set) var next = 0
        private(set) var failure: String?
        /// Выбранный исходный кадр и его метка.
        private var lastSample: CMSampleBuffer?
        private var lastPTS = -Double.infinity
        /// Следующий прочитанный, но ещё не выбранный кадр (просмотр вперёд).
        private var pending: CMSampleBuffer?
        private var pendingPTS = 0.0
        /// Готовый (кропнутый) кадр для текущего исходного индекса — повторы
        /// берут его же без повторной отрисовки.
        private var rendered: CVPixelBuffer?
        private var renderedIndex = -1

        init(input: Input, reader: AVAssetReaderTrackOutput, adaptor: AVAssetWriterInputPixelBufferAdaptor) {
            self.input = input
            self.reader = reader
            self.adaptor = adaptor
        }

        func append(output k: Int, at time: CMTime) -> Bool {
            let index = input.schedule.sourceIndex[k]
            if index != renderedIndex {
                let target = input.sourcePTS[index]
                // Берём кадр с БЛИЖАЙШЕЙ меткой: в журнале метки — наносекунды,
                // а в файле они округлены масштабом времени дорожки, и порог
                // «чуть раньше цели» при грубом масштабе перечитывал бы лишний
                // кадр (видео на кадр впереди звука).
                while peek(), lastSample == nil || abs(pendingPTS - target) <= abs(lastPTS - target) {
                    lastSample = pending
                    lastPTS = pendingPTS
                    pending = nil
                }
                guard let sample = lastSample, let source = CMSampleBufferGetImageBuffer(sample) else {
                    failure = "no source frame for output \(k)"
                    return false
                }
                guard let frame = render(source) else {
                    failure = "render failed at output \(k)"
                    return false
                }
                rendered = frame
                renderedIndex = index
            }
            guard let rendered, adaptor.append(rendered, withPresentationTime: time) else {
                failure = "append failed at output \(k)"
                return false
            }
            next = k + 1
            return true
        }

        /// Подготовить следующий кадр файла в `pending`; false — кадры кончились.
        private func peek() -> Bool {
            if pending != nil { return true }
            while let sample = reader.copyNextSampleBuffer() {
                // Служебные буферы-маркеры без кадра пропускаем.
                guard CMSampleBufferGetNumSamples(sample) > 0,
                      CMSampleBufferGetImageBuffer(sample) != nil else { continue }
                pending = sample
                pendingPTS = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
                return true
            }
            return false
        }

        private func render(_ source: CVPixelBuffer) -> CVPixelBuffer? {
            guard let pool = adaptor.pixelBufferPool else { return nil }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { return nil }
            // CIImage — с началом внизу слева; кроп задан сверху слева.
            let height = CGFloat(CVPixelBufferGetHeight(source))
            let crop = input.crop
            let ciRect = CGRect(x: crop.minX, y: height - crop.maxY, width: crop.width, height: crop.height)
            let scale = CGFloat(side) / crop.width
            let image = CIImage(cvPixelBuffer: source)
                .cropped(to: ciRect)
                .transformed(by: CGAffineTransform(translationX: -ciRect.minX, y: -ciRect.minY)
                    .concatenating(CGAffineTransform(scaleX: scale, y: scale)))
            context.render(image, to: buffer, bounds: CGRect(x: 0, y: 0, width: side, height: side),
                           colorSpace: nil)
            return buffer
        }
    }
}
