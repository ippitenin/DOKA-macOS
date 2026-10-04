import CoreVideo
import Vision
import XCTest
@testable import DOKA

/// Детектор лица и губ на Apple Vision.
///
/// Зачем: бокс и число лиц из него уходят в журнал `capture.json` — договор
/// с WISLIP. Ревизия запроса зафиксирована явно, чтобы журнал не поменялся
/// тихо вместе с умолчанием Vision в новом SDK, а 76 точек дают зеркалу
/// плотный контур губ. Камера не нужна: кадр — синтетический 420v, как у неё.
final class LipFaceTrackerTests: XCTestCase {

    /// Ровный серый кадр 1280×720 в родном формате камеры (420v, на IOSurface).
    private func makeGrayFrame() throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary
        XCTAssertEqual(CVPixelBufferCreate(nil, 1280, 720, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                           attributes, &buffer), kCVReturnSuccess)
        let pixel = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixel, [])
        for plane in 0..<CVPixelBufferGetPlaneCount(pixel) {
            let base = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(pixel, plane))
            memset(base, 128, CVPixelBufferGetBytesPerRowOfPlane(pixel, plane) * CVPixelBufferGetHeightOfPlane(pixel, plane))
        }
        CVPixelBufferUnlockBaseAddress(pixel, [])
        return pixel
    }

    /// Запрос — явно ревизия 3 и созвездие 76 точек (третья ревизия его умеет).
    func testRequestUsesRevision3With76Points() {
        let request = LipFaceTracker.makeRequest()
        XCTAssertEqual(request.revision, VNDetectFaceLandmarksRequestRevision3)
        XCTAssertTrue(VNDetectFaceLandmarksRequest.revision(VNDetectFaceLandmarksRequestRevision3,
                                                            supportsConstellation: .constellation76Points))
        XCTAssertEqual(request.constellation, .constellation76Points)
    }

    /// Кадр без лица — «лица нет», а не ошибка: в журнал уйдёт пустой бокс.
    func testBlankFrameGivesNoFace() throws {
        let sample = try LipFaceTracker().detect(in: makeGrayFrame())
        XCTAssertEqual(sample, .none)
        XCTAssertNil(sample.box)
        XCTAssertEqual(sample.count, 0)
        XCTAssertTrue(sample.eyes.isEmpty)
    }
}
