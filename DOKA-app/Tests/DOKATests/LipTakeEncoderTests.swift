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

    /// Сырое видео 1280×720 (`LipSyntheticTake.writeRawVideo`) в папке теста.
    private func makeRawVideo(times: [Double], topWhiteRows: Int? = nil, gray: ((Int) -> Int)? = nil,
                              timeScale: CMTimeScale? = nil) throws -> URL {
        let url = folder.appendingPathComponent("raw.mp4")
        try LipSyntheticTake.writeRawVideo(to: url, times: times, topWhiteRows: topWhiteRows, gray: gray,
                                           timeScale: timeScale)
        return url
    }

    private func makeWav(seconds: Double) throws -> URL {
        let url = folder.appendingPathComponent("audio.wav")
        try LipSyntheticTake.writeWav(to: url, seconds: seconds)
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

    /// Каждый выходной кадр берёт ИМЕННО свой исходный: метки в журнале —
    /// наносекунды с дрожанием камеры, а в файле они округлены масштабом
    /// времени дорожки. Порог «на миллисекунду раньше цели» при грубом
    /// масштабе перечитывал бы лишний кадр — видео опережало бы звук на кадр,
    /// а число кадров осталось бы верным.
    func testEachOutputFrameShowsItsScheduledSource() async throws {
        let times = (0..<40).map { Double($0) / 30 + ($0.isMultiple(of: 2) ? 0.0013 : -0.0011) }
        let gray: (Int) -> Int = { 20 + $0 * 5 }
        let raw = try makeRawVideo(times: times, gray: gray, timeScale: 300)
        let wav = try makeWav(seconds: 40.0 / 30)
        let schedule = try XCTUnwrap(LipSync.schedule(times: times, duration: 40.0 / 30))
        let output = folder.appendingPathComponent("clip.mp4.part")
        try await LipTakeEncoder.encode(.init(rawVideo: raw, sourcePTS: times, schedule: schedule,
                                              crop: CGRect(x: 384, y: 104, width: 512, height: 512),
                                              audio: wav, output: output))
        let asset = AVURLAsset(url: output, options: [AVURLAssetOverrideMIMETypeKey: "video/mp4"])
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: try XCTUnwrap(tracks.first), outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ])
        reader.add(out)
        XCTAssertTrue(reader.startReading())
        var k = 0
        while let sample = out.copyNextSampleBuffer() {
            guard let pixel = CMSampleBufferGetImageBuffer(sample) else { continue }
            CVPixelBufferLockBaseAddress(pixel, .readOnly)
            let plane = CVPixelBufferGetBaseAddressOfPlane(pixel, 0)!.assumingMemoryBound(to: UInt8.self)
            let luma = Double(plane[256 * CVPixelBufferGetBytesPerRowOfPlane(pixel, 0) + 256])
            CVPixelBufferUnlockBaseAddress(pixel, .readOnly)
            let expected = 16 + Double(gray(schedule.sourceIndex[k])) * 219 / 255
            XCTAssertEqual(luma, expected, accuracy: 2.5, "выходной кадр \(k)")
            k += 1
        }
        XCTAssertEqual(k, schedule.sourceIndex.count)
    }

    /// Сырой файл кончился раньше журнала (сбой ридера, обрезанный файл):
    /// повторять последний кадр до конца — значит сохранить пару с застывшим
    /// видео. Плохая пара хуже отсутствующей — кодирование обязано упасть.
    func testRawShorterThanLogFails() async throws {
        let times = (0..<60).map { Double($0) / 30 }
        let raw = try makeRawVideo(times: Array(times.prefix(40)))
        let wav = try makeWav(seconds: 2.0)
        let schedule = try XCTUnwrap(LipSync.schedule(times: times, duration: 2.0))
        let output = folder.appendingPathComponent("clip.mp4.part")
        do {
            try await LipTakeEncoder.encode(.init(rawVideo: raw, sourcePTS: times, schedule: schedule,
                                                  crop: CGRect(x: 0, y: 0, width: 720, height: 720),
                                                  audio: wav, output: output))
            XCTFail("кодирование обязано упасть: кадров в файле меньше, чем в журнале")
        } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    /// Звука меньше, чем видео по расписанию: дорожка оборвалась бы молча.
    func testAudioShorterThanScheduleFails() async throws {
        let times = (0..<90).map { Double($0) / 30 }
        let raw = try makeRawVideo(times: times)
        let wav = try makeWav(seconds: 1.0)
        let schedule = try XCTUnwrap(LipSync.schedule(times: times, duration: 3.0))
        let output = folder.appendingPathComponent("clip.mp4.part")
        do {
            try await LipTakeEncoder.encode(.init(rawVideo: raw, sourcePTS: times, schedule: schedule,
                                                  crop: CGRect(x: 0, y: 0, width: 720, height: 720),
                                                  audio: wav, output: output))
            XCTFail("кодирование обязано упасть: звук короче видео")
        } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
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
