import AVFoundation
import CoreVideo
import Foundation

/// Один дубль камеры: сырое полнокадровое видео `raw.mp4` и журнал кадров
/// и лица (`capture.json`). Кропа здесь нет — его делает второй проход по
/// всему дублю сразу (`LipTakeEncoder`), поэтому отменённые диктовки
/// дорогой обработки не проходят вовсе.
///
/// Всё состояние — ТОЛЬКО на очереди `queue` (видео-очередь камеры): кадры,
/// результаты Vision и финализация приходят туда же, гонок нет.
final class LipTakeRecorder {
    let take: LipTake
    /// Кадры раньше этого хост-времени — остаток прошлого дубля в конвейере
    /// камеры, а не этот дубль.
    let acceptFromHost: Double
    private let queue: DispatchQueue

    var camera = ""
    var effects = LipCaptureLog.Effects.none

    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var firstPTS: CMTime?
    private var width = 0
    private var height = 0
    private var frames: [LipCaptureLog.Frame] = []
    private var faces: [LipCaptureLog.Face] = []
    private var dropped = 0
    private var failed = false

    private var finishing = false
    private var finished = false
    private var discarded = false

    /// Сырое видео: аппаратный HEVC с запасом по битрейту — файл временный,
    /// его увидит только второй проход, и потери при перекодировании должны
    /// быть минимальны.
    private static let rawBitRate = 6_000_000

    init(take: LipTake, acceptFromHost: Double, queue: DispatchQueue) {
        self.take = take
        self.acceptFromHost = acceptFromHost
        self.queue = queue
    }

    var frameCount: Int { frames.count }
    var faceCount: Int { faces.count }
    var isDiscarded: Bool { discarded }
    var firstFrameHost: Double? { frames.first?.host }
    var lastFrameHost: Double? { frames.last?.host }

    // MARK: - Кадры

    func append(_ sampleBuffer: CMSampleBuffer, host: Double) {
        guard !finishing, !discarded, !failed else { return }
        if writer == nil, !startWriter(with: sampleBuffer) {
            failed = true
            return
        }
        guard let writer, let input, writer.status == .writing else {
            failed = true
            return
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let first = firstPTS ?? pts
        firstPTS = first
        let relative = CMTimeSubtract(pts, first)
        // Метки сдвигаются к нулю: в файле нет edit list, и читатель второго
        // прохода отдаёт ровно эти метки.
        var timing = CMSampleTimingInfo(duration: CMSampleBufferGetDuration(sampleBuffer),
                                        presentationTimeStamp: relative,
                                        decodeTimeStamp: .invalid)
        var retimed: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sampleBuffer,
                                              sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                              sampleBufferOut: &retimed)
        guard let retimed, input.isReadyForMoreMediaData, input.append(retimed) else {
            dropped += 1
            return
        }
        let luma = CMSampleBufferGetImageBuffer(sampleBuffer).map(Self.meanLuma) ?? 0
        frames.append(.init(t: CMTimeGetSeconds(relative), host: host, luma: luma))
    }

    func noteDropped() {
        guard !finishing, writer != nil else { return }
        dropped += 1
    }

    func addFace(_ sample: LipFaceSample, host: Double) {
        guard !finishing else { return }
        let box = sample.box.map { [Double($0.minX), Double($0.minY), Double($0.width), Double($0.height)] }
        faces.append(.init(host: host, box: box, count: sample.count))
    }

    /// Камеру отключили или забрали посреди дубля.
    func markFailed() {
        failed = true
    }

    // MARK: - Финал

    /// Дописать файл и журнал. `completion(ok)` — на `queue`, один раз.
    func finish(completion: @escaping (Bool) -> Void) {
        guard !finishing else { return }
        finishing = true
        guard let writer, let input, writer.status == .writing, !frames.isEmpty else {
            writer?.cancelWriting()
            complete(ok: false, completion: completion)
            return
        }
        input.markAsFinished()
        writer.finishWriting { [self] in
            queue.async { [self] in
                let ok = writer.status == .completed
                if !ok {
                    NSLog("DOKA: губы — сырое видео не дописалось: %@",
                          writer.error?.localizedDescription ?? "?")
                }
                complete(ok: ok, completion: completion)
            }
        }
    }

    /// Выбросить дубль: Esc, тишина, ошибка распознавания. Если файл ещё
    /// дописывается — удалит финализация.
    func discard() {
        discarded = true
        if !finishing {
            finishing = true
            writer?.cancelWriting()
            Self.removeFolder(take)
        } else if finished {
            Self.removeFolder(take)
        }
    }

    private func complete(ok: Bool, completion: @escaping (Bool) -> Void) {
        finished = true
        if discarded {
            Self.removeFolder(take)
            completion(false)
            return
        }
        // Журнал пишется и при сбое: решение «камера не справилась» принимает
        // обработчик, и причина попадает в статистику, а не теряется молча.
        let log = LipCaptureLog(frameWidth: width, frameHeight: height, camera: camera,
                                frames: frames, faces: faces, droppedFrames: dropped,
                                failed: failed || !ok, effects: effects)
        do {
            let data = try JSONEncoder().encode(log)
            try data.write(to: take.captureLogURL, options: .atomic)
        } catch {
            NSLog("DOKA: губы — журнал захвата не записан: %@", error.localizedDescription)
        }
        completion(ok && !failed)
    }

    private static func removeFolder(_ take: LipTake) {
        try? FileManager.default.removeItem(at: take.folder)
    }

    // MARK: - Писатель

    private func startWriter(with sampleBuffer: CMSampleBuffer) -> Bool {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer) else { return false }
        let dims = CMVideoFormatDescriptionGetDimensions(format)
        width = Int(dims.width)
        height = Int(dims.height)
        do {
            let writer = try AVAssetWriter(outputURL: take.rawVideoURL, fileType: .mp4)
            var settings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.hevc,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: Self.rawBitRate,
                    AVVideoMaxKeyFrameIntervalKey: 30,
                    AVVideoAllowFrameReorderingKey: false,
                    AVVideoExpectedSourceFrameRateKey: 30
                ]
            ]
            if !writer.canApply(outputSettings: settings, forMediaType: .video) {
                settings[AVVideoCodecKey] = AVVideoCodecType.h264
            }
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings,
                                           sourceFormatHint: format)
            input.expectsMediaDataInRealTime = true
            // Точный масштаб времени дорожки: по умолчанию писатель берёт 1/600,
            // и метки кадров в файле расходятся с журналом почти на миллисекунду.
            input.mediaTimeScale = 90_000
            guard writer.canAdd(input) else { return false }
            writer.add(input)
            guard writer.startWriting() else {
                NSLog("DOKA: губы — писатель не стартовал: %@", writer.error?.localizedDescription ?? "?")
                return false
            }
            writer.startSession(atSourceTime: .zero)
            self.writer = writer
            self.input = input
            return true
        } catch {
            NSLog("DOKA: губы — писатель не создан: %@", error.localizedDescription)
            return false
        }
    }

    /// Средняя яркость кадра (0…255) по сетке 32×18 точек плоскости Y.
    private static func meanLuma(_ pixelBuffer: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        let planar = CVPixelBufferIsPlanar(pixelBuffer)
        guard let base = planar ? CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)
                                : CVPixelBufferGetBaseAddress(pixelBuffer) else { return 0 }
        let width = planar ? CVPixelBufferGetWidthOfPlane(pixelBuffer, 0) : CVPixelBufferGetWidth(pixelBuffer)
        let height = planar ? CVPixelBufferGetHeightOfPlane(pixelBuffer, 0) : CVPixelBufferGetHeight(pixelBuffer)
        let rowBytes = planar ? CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
                              : CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard width > 0, height > 0 else { return 0 }
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var sum = 0
        let columns = 32, rows = 18
        for r in 0..<rows {
            let y = (r * height + height / 2) / rows
            for c in 0..<columns {
                let x = (c * width + width / 2) / columns
                sum += Int(bytes[y * rowBytes + x])
            }
        }
        return Double(sum) / Double(columns * rows)
    }
}
