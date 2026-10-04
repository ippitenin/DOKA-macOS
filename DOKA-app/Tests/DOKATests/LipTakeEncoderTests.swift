import AVFoundation
import CoreVideo
import XCTest
@testable import DOKA

/// Второй проход дубля губ: кроп → 512×512 H.264 постоянной частоты + AAC.
///
/// Зачем: это то, что ест WISLIP. Без звуковой дорожки их препроцессинг
/// виснет, переменная частота кадров ломает его ресемплинг, а лишние или
/// недостающие кадры рассинхронизируют губы со звуком. Фикстуры
/// синтетические: сырое видео с выпавшими кадрами и WAV из `WavWriter`.
final class LipTakeEncoderTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("doka-lip-encoder-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    /// Сырое видео 1280×720: кадры по меткам `times`, цвет растёт с номером кадра.
    private func makeRawVideo(times: [Double], topWhiteRows: Int? = nil) throws -> URL {
        let url = folder.appendingPathComponent("raw.mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 1280, AVVideoHeightKey: 720
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 1280, kCVPixelBufferHeightKey as String: 720
        ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for (i, t) in times.enumerated() {
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.005) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            let pixel = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pixel, [])
            let base = CVPixelBufferGetBaseAddress(pixel)!
            if let rows = topWhiteRows {
                // Верхние `rows` строк белые, остальное чёрное.
                let rowBytes = CVPixelBufferGetBytesPerRow(pixel)
                memset(base, 0, CVPixelBufferGetDataSize(pixel))
                memset(base, 255, rows * rowBytes)
            } else {
                memset(base, Int32(i * 2 % 256), CVPixelBufferGetDataSize(pixel))
            }
            CVPixelBufferUnlockBaseAddress(pixel, [])
            XCTAssertTrue(adaptor.append(pixel, withPresentationTime: CMTime(seconds: t, preferredTimescale: 600)))
        }
        input.markAsFinished()
        let done = expectation(description: "raw")
        writer.finishWriting { done.fulfill() }
        wait(for: [done], timeout: 20)
        XCTAssertEqual(writer.status, .completed)
        return url
    }

    private func makeWav(seconds: Double) throws -> URL {
        let url = folder.appendingPathComponent("audio.wav")
        let writer = try WavWriter(url: url)
        let rate = Double(WavWriter.sampleRate)
        var samples = [Int16](repeating: 0, count: Int(seconds * rate))
        for i in samples.indices { samples[i] = Int16(sin(Double(i) * 2 * .pi * 440 / rate) * 8000) }
        writer.append(samples.withUnsafeBufferPointer { Data(buffer: $0) })
        try writer.finalize()
        return url
    }

    /// 3 с звука, видео 30 к/с с двумя выпавшими кадрами и опоздавшей на
    /// 0,2 с камерой: на выходе ровно 90 кадров 512×512 и AAC на всю длину.
    func testEncodesConstantRateClipWithAudio() async throws {
        var times = (0..<84).map { 0.2 + Double($0) / 30 }
        times.removeSubrange(30...31)
        let raw = try makeRawVideo(times: times)
        let wav = try makeWav(seconds: 3.0)
        let schedule = try XCTUnwrap(LipSync.schedule(times: times, duration: 3.0))
        let output = folder.appendingPathComponent("clip.mp4.part")

        try await LipTakeEncoder.encode(.init(rawVideo: raw, sourcePTS: times, schedule: schedule,
                                              crop: CGRect(x: 384, y: 104, width: 512, height: 512),
                                              audio: wav, output: output))

        // У `.part` нет расширения mp4 — тип файла задаём явно.
        let asset = AVURLAsset(url: output, options: [AVURLAssetOverrideMIMETypeKey: "video/mp4"])
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let video = try XCTUnwrap(videoTracks.first)
        let size = try await video.load(.naturalSize)
        let rate = try await video.load(.nominalFrameRate)
        let transform = try await video.load(.preferredTransform)
        XCTAssertEqual(size, CGSize(width: 512, height: 512))
        XCTAssertEqual(rate, 30, accuracy: 0.5)
        XCTAssertEqual(transform, .identity)

        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: video, outputSettings: nil)
        reader.add(out)
        XCTAssertTrue(reader.startReading())
        var frames = 0
        // Ридер без декодирования отдаёт и служебные пустые буферы-маркеры —
        // считаем только настоящие кадры.
        while let sample = out.copyNextSampleBuffer() {
            if CMSampleBufferGetNumSamples(sample) > 0 { frames += 1 }
        }
        XCTAssertEqual(frames, 90)

        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let audio = try XCTUnwrap(audioTracks.first)
        let formats = try await audio.load(.formatDescriptions)
        XCTAssertEqual(formats.first.map(CMFormatDescriptionGetMediaSubType), kAudioFormatMPEG4AAC)
        let duration = try await asset.load(.duration)
        XCTAssertEqual(CMTimeGetSeconds(duration), 3.0, accuracy: 0.1)
    }

    /// Кроп задан сверху слева (как боксы Vision в журнале), а CoreImage
    /// считает снизу: перепутанная ось увела бы кроп с лица на грудь.
    func testCropIsMeasuredFromTopLeft() async throws {
        let times = (0..<30).map { Double($0) / 30 }
        let raw = try makeRawVideo(times: times, topWhiteRows: 360)
        let wav = try makeWav(seconds: 1.0)
        let schedule = try XCTUnwrap(LipSync.schedule(times: times, duration: 1.0))
        let output = folder.appendingPathComponent("clip.mp4.part")
        try await LipTakeEncoder.encode(.init(rawVideo: raw, sourcePTS: times, schedule: schedule,
                                              crop: CGRect(x: 100, y: 0, width: 360, height: 360),
                                              audio: wav, output: output))
        let asset = AVURLAsset(url: output, options: [AVURLAssetOverrideMIMETypeKey: "video/mp4"])
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: try XCTUnwrap(tracks.first), outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ])
        reader.add(out)
        XCTAssertTrue(reader.startReading())
        let pixel = try XCTUnwrap(out.copyNextSampleBuffer().flatMap(CMSampleBufferGetImageBuffer))
        CVPixelBufferLockBaseAddress(pixel, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixel, .readOnly) }
        let luma = CVPixelBufferGetBaseAddressOfPlane(pixel, 0)!.assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixel, 0)
        XCTAssertGreaterThan(luma[256 * rowBytes + 256], 200, "центр кропа должен быть белым (верх кадра)")
    }

    /// Отмена посреди кодирования не оставляет огрызок.
    func testCancellationRemovesPartialOutput() async throws {
        let times = (0..<300).map { Double($0) / 30 }
        let raw = try makeRawVideo(times: times)
        let wav = try makeWav(seconds: 10)
        let schedule = try XCTUnwrap(LipSync.schedule(times: times, duration: 10))
        let output = folder.appendingPathComponent("clip.mp4.part")
        let task = Task {
            try await LipTakeEncoder.encode(.init(rawVideo: raw, sourcePTS: times, schedule: schedule,
                                                  crop: CGRect(x: 0, y: 0, width: 720, height: 720),
                                                  audio: wav, output: output))
        }
        task.cancel()
        do {
            try await task.value
        } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }
}
