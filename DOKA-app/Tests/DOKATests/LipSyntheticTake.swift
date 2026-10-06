import AVFoundation
import CoreVideo
import Foundation
@testable import DOKA

/// Синтетический дубль губ — общий для тестов кодировщика и хранилища:
/// сырое видео камеры, WAV записи и журнал `capture.json`, согласованные
/// между собой по хост-времени.
enum LipSyntheticTake {
    struct WriteError: Error, CustomStringConvertible {
        let description: String
    }

    /// Хост-время старта WAV в журнале по умолчанию.
    static let hostStart = 100.0
    /// Камера просыпается через столько после старта WAV.
    static let cameraDelay = 0.3

    /// Сырое видео 1280×720 H.264: кадры по меткам `times`, цвет растёт с
    /// номером кадра (`gray` подменяет его), `topWhiteRows` — верхние строки
    /// белые, остальное чёрное.
    static func writeRawVideo(to url: URL, times: [Double], topWhiteRows: Int? = nil,
                              gray: ((Int) -> Int)? = nil, timeScale: CMTimeScale? = nil) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 1280, AVVideoHeightKey: 720
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 1280, kCVPixelBufferHeightKey as String: 720
        ])
        if let timeScale { input.mediaTimeScale = timeScale }
        writer.add(input)
        guard writer.startWriting() else { throw WriteError(description: "startWriting: \(String(describing: writer.error))") }
        writer.startSession(atSourceTime: .zero)
        for (i, t) in times.enumerated() {
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.005) }
            var buffer: CVPixelBuffer?
            guard let pool = adaptor.pixelBufferPool else { throw WriteError(description: "нет пула буферов") }
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let pixel = buffer else { throw WriteError(description: "нет буфера кадра \(i)") }
            CVPixelBufferLockBaseAddress(pixel, [])
            let base = CVPixelBufferGetBaseAddress(pixel)!
            if let rows = topWhiteRows {
                let rowBytes = CVPixelBufferGetBytesPerRow(pixel)
                memset(base, 0, CVPixelBufferGetDataSize(pixel))
                memset(base, 255, rows * rowBytes)
            } else {
                memset(base, Int32(gray?(i) ?? (i * 2 % 256)), CVPixelBufferGetDataSize(pixel))
            }
            CVPixelBufferUnlockBaseAddress(pixel, [])
            guard adaptor.append(pixel, withPresentationTime: CMTime(seconds: t, preferredTimescale: 1_000_000_000)) else {
                throw WriteError(description: "кадр \(i) не записан: \(String(describing: writer.error))")
            }
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        guard done.wait(timeout: .now() + 20) == .success, writer.status == .completed else {
            throw WriteError(description: "finishWriting: \(writer.status.rawValue) \(String(describing: writer.error))")
        }
    }

    /// WAV 16 кГц mono: тон 440 Гц на `seconds` секунд.
    static func writeWav(to url: URL, seconds: Double) throws {
        let writer = try WavWriter(url: url)
        let rate = Double(WavWriter.sampleRate)
        var samples = [Int16](repeating: 0, count: Int(seconds * rate))
        for i in samples.indices { samples[i] = Int16(sin(Double(i) * 2 * .pi * 440 / rate) * 8000) }
        writer.append(samples.withUnsafeBufferPointer { Data(buffer: $0) })
        try writer.finalize()
    }

    /// Журнал камеры: `frames` кадров 30 к/с с хост-времени
    /// `hostStart + cameraDelay`, лицо 300 px через кадр (как Vision на ритме
    /// журнала). Метки кадров `t` — это метки в `raw.mp4`.
    static func log(frames: Int = 80) -> LipCaptureLog {
        let cameraHost = hostStart + cameraDelay
        let entries = (0..<frames).map { i in
            LipCaptureLog.Frame(t: Double(i) / 30, host: cameraHost + Double(i) / 30, luma: 100)
        }
        let faces = stride(from: 0, to: frames, by: 2).map { i in
            LipCaptureLog.Face(host: cameraHost + Double(i) / 30, box: [490, 210, 300, 300], count: 1)
        }
        return LipCaptureLog(frameWidth: 1280, frameHeight: 720, camera: "FaceTime HD Camera",
                             frames: entries, faces: faces, droppedFrames: 0, failed: false,
                             effects: .none)
    }
}
