import AVFoundation
import XCTest
@testable import DOKA

/// Архив исходного звука (`SourceAudioArchiver`) и регрессия декодера
/// (`AudioFileDecoder.decodeToWav`), который после выноса `makePCMReader`
/// делит с архиватором выбор дорожки. Источник — синтетический WAV
/// из `WavWriter`: без микрофона и сети, прогон — доли секунды.
final class SourceAudioArchiverTests: XCTestCase {

    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("doka-archiver-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    /// WAV 16 кГц mono Int16 с синусоидой 440 Гц заданной длительности.
    private func makeSineWav(seconds: Double, name: String = "source.wav") throws -> URL {
        let url = tmp.appendingPathComponent(name)
        let writer = try WavWriter(url: url)
        let count = Int(seconds * Double(WavWriter.sampleRate))
        var samples = [Int16](repeating: 0, count: count)
        for i in 0..<count {
            let t = Double(i) / Double(WavWriter.sampleRate)
            samples[i] = Int16(sin(2 * .pi * 440 * t) * 0.5 * Double(Int16.max))
        }
        let data = samples.withUnsafeBufferPointer { ptr -> Data in
            // WAV — little-endian; на Apple Silicon и Intel нативный порядок совпадает.
            Data(buffer: ptr)
        }
        writer.append(data)
        try writer.finalize()
        return url
    }

    func testArchiveProducesReadableM4A() async throws {
        let source = try makeSineWav(seconds: 1.5)
        let destination = tmp.appendingPathComponent("test.m4a")

        let duration = try await SourceAudioArchiver.archive(source: source, to: destination)

        XCTAssertEqual(duration, 1.5, accuracy: 0.2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        let file = try AVAudioFile(forReading: destination)
        XCTAssertEqual(file.fileFormat.sampleRate, 16_000)
        XCTAssertEqual(file.fileFormat.channelCount, 1)
        XCTAssertEqual(file.fileFormat.streamDescription.pointee.mFormatID, kAudioFormatMPEG4AAC)
        let fileDuration = Double(file.length) / file.fileFormat.sampleRate
        XCTAssertEqual(fileDuration, 1.5, accuracy: 0.2)
    }

    func testArchiveOfMissingSourceThrowsAndLeavesNoFile() async throws {
        let source = tmp.appendingPathComponent("missing.wav")
        let destination = tmp.appendingPathComponent("missing.m4a")

        do {
            _ = try await SourceAudioArchiver.archive(source: source, to: destination)
            XCTFail("архив несуществующего файла не должен завершиться успехом")
        } catch {
            // Ожидаемо: тип ошибки не важен, важно отсутствие огрызка.
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testCancelledArchiveLeavesNoFile() async throws {
        // Длинный источник — чтобы отмена гарантированно застала работу в процессе.
        let source = try makeSineWav(seconds: 30)
        let destination = tmp.appendingPathComponent("cancelled.m4a")

        let task = Task {
            try await SourceAudioArchiver.archive(source: source, to: destination)
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("отменённая задача не должна завершиться успехом")
        } catch is CancellationError {
            // Ожидаемо.
        } catch {
            XCTFail("ожидалась CancellationError, пришла \(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    /// Регрессия выноса `makePCMReader`: WAV 16 кГц mono Int16 проходит
    /// декодер без изменений — та же длительность и те же байты.
    func testDecodeToWavKeepsDurationAndSamples() async throws {
        let source = try makeSineWav(seconds: 1.5)

        let decoded = try await AudioFileDecoder.decodeToWav(source)
        defer { try? FileManager.default.removeItem(at: decoded.url) }

        XCTAssertEqual(decoded.duration, 1.5, accuracy: 0.001)
        let original = try Data(contentsOf: source)
        let result = try Data(contentsOf: decoded.url)
        XCTAssertEqual(result.count, original.count)
        XCTAssertEqual(result, original, "декодер исказил PCM при тождественном формате")
    }
}
