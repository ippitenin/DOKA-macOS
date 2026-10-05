import CoreGraphics
import CoreVideo
import XCTest
@testable import DOKA

/// Рендер картинки зеркала из кадра камеры (Core Image).
///
/// Зачем: картинка и маска теперь из одного кадра, и маска ложится на
/// картинку через `LipMirrorGeometry.map` — значит, рендер обязан ставить
/// пиксели ровно туда же (с точностью до пикселя, в том числе при дробном
/// окне и зеркале), видеодиапазон 420v — растягивать в полный, а верх кадра
/// оставлять верхом. И буфер камеры отдавать сразу: пул захвата маленький.
/// Кадры синтетические — 420v на IOSurface, как у камеры, с вложениями BT.709.
final class LipMirrorRendererTests: XCTestCase {

    private let camera = CGSize(width: 1280, height: 720)
    private let renderer = LipMirrorRenderer()

    // MARK: - Синтетический кадр

    private static let attachments: [CFString: CFString] = [
        kCVImageBufferYCbCrMatrixKey: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
        kCVImageBufferColorPrimariesKey: kCVImageBufferColorPrimaries_ITU_R_709_2,
        kCVImageBufferTransferFunctionKey: kCVImageBufferTransferFunction_ITU_R_709_2,
    ]

    /// Заполнить 420v: яркость по пикселю, цветность — серая (128).
    private static func fill(_ buffer: CVPixelBuffer, luma: (Int, Int) -> UInt8) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let width = CVPixelBufferGetWidthOfPlane(buffer, 0), height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let y = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
        let yRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        for row in 0..<height {
            for col in 0..<width { y[row * yRow + col] = luma(col, row) }
        }
        let c = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!
        memset(c, 128, CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) * CVPixelBufferGetHeightOfPlane(buffer, 1))
        for (key, value) in attachments {
            CVBufferSetAttachment(buffer, key, value, .shouldPropagate)
        }
    }

    private func frame(luma: (Int, Int) -> UInt8) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        XCTAssertEqual(CVPixelBufferCreate(nil, Int(camera.width), Int(camera.height),
                                           kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                           attributes as CFDictionary, &buffer), kCVReturnSuccess)
        let pixel = try XCTUnwrap(buffer)
        Self.fill(pixel, luma: luma)
        return pixel
    }

    /// Пиксели картинки, BGRA sRGB, строки сверху вниз.
    private struct Pixels {
        let width: Int, height: Int
        let data: [UInt8]

        init(_ image: CGImage) {
            width = image.width
            height = image.height
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            bytes.withUnsafeMutableBytes { raw in
                let context = CGContext(data: raw.baseAddress, width: image.width, height: image.height,
                                        bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                            | CGBitmapInfo.byteOrder32Little.rawValue)!
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            }
            data = bytes
        }

        /// (R, G, B) пикселя `(x, y)` от верхнего левого угла.
        func rgb(_ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
            let i = (y * width + x) * 4
            return (Int(data[i + 2]), Int(data[i + 1]), Int(data[i]))
        }

        func luma(_ x: Int, _ y: Int) -> Int {
            let p = rgb(x, y)
            return (p.r + p.g + p.b) / 3
        }
    }

    private func render(_ buffer: CVPixelBuffer, region: CGRect? = nil, size: CGSize = CGSize(width: 320, height: 180),
                        mirrored: Bool = false) throws -> Pixels {
        let image = try XCTUnwrap(renderer.render(buffer, region: region ?? CGRect(origin: .zero, size: camera),
                                                  size: size, mirrored: mirrored))
        return Pixels(image)
    }

    // MARK: - Тесты

    func testOutputHasTargetPixelSize() throws {
        let buffer = try frame { _, _ in 128 }
        let target = LipMirrorTarget(size: CGSize(width: 224, height: 120), scale: 2, reduceMotion: false)
        let image = try XCTUnwrap(renderer.render(buffer, region: CGRect(x: 400, y: 200, width: 448, height: 240),
                                                  size: target.pixelSize, mirrored: true))
        XCTAssertEqual(image.width, 448)
        XCTAssertEqual(image.height, 240)
    }

    /// Видеодиапазон: Y 16 — чёрный, Y 235 — белый, CbCr 128 — без оттенка.
    /// Средне-серый проверяет управление цветом: Y 126 по обратной кривой
    /// BT.709 и кодированию sRGB — 139; без управления цветом (NSNull-настройки
    /// `LipTakeEncoder`) вышло бы 128.
    func testVideoRangeMapsToFullRange() throws {
        let buffer = try frame { x, _ in x < 640 ? 16 : 235 }
        let pixels = try render(buffer)
        for (x, expected) in [(40, 0), (280, 255)] {
            let p = pixels.rgb(x, 90)
            XCTAssertEqual(p.r, expected, accuracy: 3, "x \(x)")
            XCTAssertEqual(p.g, expected, accuracy: 3, "x \(x)")
            XCTAssertEqual(p.b, expected, accuracy: 3, "x \(x)")
        }
        let gray = try render(try frame { _, _ in 126 }).rgb(160, 90)
        XCTAssertEqual(gray.g, 139, accuracy: 3, "кадр без управления цветом")
        XCTAssertEqual(gray.r, gray.g, accuracy: 3)
        XCTAssertEqual(gray.b, gray.g, accuracy: 3)
    }

    /// Начало координат региона — сверху, как у кадра и трекера; у CIImage
    /// оно снизу, и переворот легко потерять.
    func testTopOfRegionIsTopOfImage() throws {
        let buffer = try frame { _, y in y < 360 ? 235 : 16 }
        let pixels = try render(buffer)
        XCTAssertGreaterThan(pixels.luma(160, 20), 240)
        XCTAssertLessThan(pixels.luma(160, 160), 15)
    }

    func testMirroredRegionShowsRightSideOnLeft() throws {
        let buffer = try frame { x, _ in x < 640 ? 16 : 235 }
        let plain = try render(buffer)
        XCTAssertLessThan(plain.luma(20, 90), 15)
        let mirrored = try render(buffer, mirrored: true)
        XCTAssertGreaterThan(mirrored.luma(20, 90), 240)
        XCTAssertLessThan(mirrored.luma(300, 90), 15)
    }

    /// Яркое пятно встаёт туда, куда `map` ставит маску, — с точностью до
    /// пикселя при дробном окне, с зеркалом и без, в обеих ветках масштаба:
    /// увеличение (окно у рта на Retina) и уменьшение (сцена, экран 1×).
    func testRenderedDotLandsWhereMapPutsIt() throws {
        let cases: [(dot: CGRect, region: CGRect, size: CGSize)] = [
            (CGRect(x: 700, y: 300, width: 6, height: 6),
             CGRect(x: 512.3, y: 201.7, width: 336.6, height: 180.3), CGSize(width: 448, height: 240)),
            // Пятно крупнее: после уменьшения в 2,7 раза мелкое ушло бы под порог.
            (CGRect(x: 700, y: 300, width: 24, height: 24),
             CGRect(x: 380.4, y: 120.6, width: 600.2, height: 321.5), CGSize(width: 224, height: 120)),
        ]
        for (dot, region, size) in cases {
            try assertDot(dot, region: region, size: size)
        }
    }

    private func assertDot(_ dot: CGRect, region: CGRect, size: CGSize,
                           file: StaticString = #filePath, line: UInt = #line) throws {
        let buffer = try frame { x, y in dot.contains(CGPoint(x: x, y: y)) ? 235 : 16 }
        for mirrored in [false, true] {
            let pixels = try render(buffer, region: region, size: size, mirrored: mirrored)
            var sum = 0.0, sx = 0.0, sy = 0.0
            for y in 0..<pixels.height {
                for x in 0..<pixels.width {
                    let w = Double(max(pixels.luma(x, y) - 30, 0))
                    sum += w
                    sx += w * (Double(x) + 0.5)
                    sy += w * (Double(y) + 0.5)
                }
            }
            XCTAssertGreaterThan(sum, 0, file: file, line: line)
            let expected = LipMirrorGeometry.map(CGPoint(x: dot.midX, y: dot.midY), region: region, size: size,
                                                 mirrored: mirrored)
            XCTAssertEqual(sx / sum, Double(expected.x), accuracy: 1, "зеркало \(mirrored)", file: file, line: line)
            XCTAssertEqual(sy / sum, Double(expected.y), accuracy: 1, "зеркало \(mirrored)", file: file, line: line)
        }
    }

    /// Готовая картинка не держит буфер камеры: при пуле на один буфер новый
    /// выдаётся, пока картинка ещё жива. Отложенный рендер держал бы буфер
    /// до отрисовки, и камера ждала бы свободного.
    func testRenderDoesNotRetainCameraBuffer() throws {
        let pixelAttributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey: Int(camera.width),
            kCVPixelBufferHeightKey: Int(camera.height),
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        var created: CVPixelBufferPool?
        XCTAssertEqual(CVPixelBufferPoolCreate(nil, nil, pixelAttributes as CFDictionary, &created), kCVReturnSuccess)
        let pool = try XCTUnwrap(created)
        let aux = [kCVPixelBufferPoolAllocationThresholdKey: 1] as CFDictionary

        var image: CGImage?
        try autoreleasepool {
            var buffer: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, aux, &buffer),
                           kCVReturnSuccess)
            let pixel = try XCTUnwrap(buffer)
            Self.fill(pixel) { _, _ in 128 }
            image = renderer.render(pixel, region: CGRect(origin: .zero, size: camera),
                                    size: CGSize(width: 448, height: 240), mirrored: true)
        }
        XCTAssertNotNil(image)

        var next: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, aux, &next), kCVReturnSuccess,
                       "буфер камеры держит отрендеренная картинка")
        XCTAssertNotNil(image)
    }

    func testPrewarmDoesNotCrash() {
        renderer.prewarm()
        XCTAssertNotNil(LipMirrorRenderer.blackFrame())
    }
}
