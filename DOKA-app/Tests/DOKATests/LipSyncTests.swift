import XCTest
@testable import DOKA

/// Синхронизация видео губ с WAV диктовки: отсечение прогрева камеры.
///
/// Зачем: первые кадры холодной камеры — скачок экспозиции. Трекер лиц
/// WISLIP рвёт трек на резкой «смене сцены», поэтому полезное видео
/// начинается с кадра, после которого яркость стабильна.
final class LipSyncTests: XCTestCase {

    private func times(_ count: Int, fps: Double = 30) -> [Double] {
        (0..<count).map { Double($0) / fps }
    }

    // MARK: - Прогрев

    /// Экспозиция растёт полсекунды, потом стоит — полезное видео с плато.
    func testStableStartSkipsExposureRamp() {
        let t = times(60)
        let lumas = t.map { $0 < 0.5 ? $0 * 200 : 120 }   // рампа 0…100, затем 120
        let index = LipSync.stableStart(times: t, lumas: lumas)
        XCTAssertEqual(index, 15)                           // t = 0,5 с
    }

    /// Камера сразу стабильна — всё равно не раньше 0,2 с.
    func testStableStartIsNotEarlierThanMinimum() {
        let t = times(60)
        let index = LipSync.stableStart(times: t, lumas: t.map { _ in 100 })
        XCTAssertEqual(index, 6)                            // t = 0,2 с
    }

    /// Яркость так и не успокоилась — не позже 1,0 с, иначе потеряли бы весь дубль.
    func testStableStartIsCappedAtMaximum() {
        let t = times(90)
        let lumas = t.indices.map { $0.isMultiple(of: 2) ? 80.0 : 110.0 }
        XCTAssertEqual(LipSync.stableStart(times: t, lumas: lumas), 30)   // t = 1,0 с
    }

    /// Короткий клип без стабильного участка — полезного видео нет.
    func testStableStartIsNilWhenNothingUsable() {
        XCTAssertNil(LipSync.stableStart(times: [], lumas: []))
        let t = times(5)                                    // 0…0,13 с
        XCTAssertNil(LipSync.stableStart(times: t, lumas: t.map { _ in 100 }))
    }

    // MARK: - Журнал захвата

    /// `capture.json` переживает перезапуск приложения: обработчик читает его
    /// после старта, если дубль не успели закодировать.
    func testCaptureLogRoundTrips() throws {
        let log = LipCaptureLog(
            frameWidth: 1280, frameHeight: 720, camera: "FaceTime HD Camera",
            frames: [.init(t: 0, host: 100.0, luma: 90), .init(t: 1.0 / 30, host: 100.0 + 1.0 / 30, luma: 91)],
            faces: [.init(host: 100.0, box: [400, 100, 300, 300], count: 1),
                    .init(host: 100.07, box: nil, count: 0)],
            droppedFrames: 2, failed: false,
            effects: .init(centerStage: false, portrait: true, studioLight: false,
                           backgroundReplacement: false, reactions: false))
        let data = try JSONEncoder().encode(log)
        XCTAssertEqual(try JSONDecoder().decode(LipCaptureLog.self, from: data), log)
    }
}
