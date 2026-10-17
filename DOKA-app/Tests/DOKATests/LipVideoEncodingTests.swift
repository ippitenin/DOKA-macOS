import AVFoundation
import VideoToolbox
import XCTest
@testable import DOKA

/// Тесты не кодируют видео аппаратно — ни нынешние, ни будущие.
///
/// Зачем: 17.10.2026 тесты с аппаратным кодировщиком (AVE) дважды уронили
/// ядро (`dart-ave0 … PTE invalid exception`, `Tests/DOKATests/CLAUDE.md`).
/// Вторая паника — от `LipTakeRecorder`, которого тогдашняя правка не
/// коснулась. Поэтому разрешение одно на всё (`LipVideoEncoding`), его
/// ставит только `main.swift`, а сторож проверяет по исходникам, что ни
/// одна видеодорожка его не обходит.
final class LipVideoEncodingTests: XCTestCase {

    /// Тестовый процесс `main.swift` не исполняет — разрешения нет.
    func testHardwareIsOffInTests() {
        XCTAssertFalse(LipVideoEncoding.hardwareAllowed)
        let settings = LipVideoEncoding.outputSettings([AVVideoCodecKey: AVVideoCodecType.h264])
        let spec = settings[AVVideoEncoderSpecificationKey] as? [String: Any]
        let hardware = spec?[kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String] as? Bool
        XCTAssertEqual(hardware, false)
        XCTAssertEqual(settings[AVVideoCodecKey] as? AVVideoCodecType, .h264)
    }

    /// Каждая видеодорожка и каждая сессия VideoToolbox — через переключатель;
    /// включает его только `main.swift`.
    func testEveryVideoWriterGoesThroughTheSwitch() throws {
        let package = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = try swiftFiles(in: package.appendingPathComponent("Sources/DOKA"))
        let tests = try swiftFiles(in: package.appendingPathComponent("Tests/DOKATests"))
        XCTAssertFalse(sources.isEmpty)
        XCTAssertFalse(tests.isEmpty)

        let writers = ["AVAssetWriterInput(mediaType: .video", "VTCompressionSessionCreate"]
        let enable = "hardwareAllowed" + " = true"
        var checked = 0
        for file in sources + tests {
            let text = try String(contentsOf: file, encoding: .utf8)
            let name = file.lastPathComponent
            if writers.contains(where: text.contains) {
                checked += 1
                XCTAssertTrue(text.contains("LipVideoEncoding.outputSettings("),
                              "\(name): видеодорожка в обход LipVideoEncoding.outputSettings")
            }
            if text.contains(enable) {
                XCTAssertEqual(name, "main.swift", "\(name): аппаратный кодировщик включают только в main.swift")
            }
        }
        // LipTakeRecorder, LipTakeEncoder и LipSyntheticTake.
        XCTAssertGreaterThanOrEqual(checked, 3)
        let main = try XCTUnwrap(sources.first { $0.lastPathComponent == "main.swift" })
        XCTAssertTrue(try String(contentsOf: main, encoding: .utf8).contains(enable),
                      "приложение должно кодировать аппаратно")
    }

    private func swiftFiles(in folder: URL) throws -> [URL] {
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil))
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }
}
