import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import Metal

/// Картинка зеркала из кадра камеры: окно `region` кадра (пиксели, начало
/// сверху слева, как у `LipFaceSample`) в картинку `size` пикселей. Протокол —
/// чтобы движок можно было проверить с фальшивым рендерером.
protocol LipMirrorRendering: AnyObject {
    func render(_ pixelBuffer: CVPixelBuffer, region: CGRect, size: CGSize, mirrored: Bool) -> CGImage?
    /// Холостой прогон до первого дубля; движок зовёт его один раз за процесс.
    func prewarm()
}

extension LipMirrorRendering {
    func prewarm() {}
}

/// Рендер зеркала через Core Image. Сам не синхронизирован: вызовы не
/// пересекаются — кадр рендерится на `renderQueue`, а `visionQueue` ждёт его
/// до конца, прежде чем взять следующий.
///
/// В буфер камеры НЕ пишет: рендер только в свой `CGImage`, иначе маска или
/// отражение попали бы в `raw.mp4`, а за ним в `clip.mp4`.
final class LipMirrorRenderer: LipMirrorRendering {
    /// Контекст ленивый: Metal-устройство и кэш ядер нужны только с зеркалом.
    /// Без промежуточного кэша — кадры камеры не повторяются, держать их
    /// промежуточные изображения незачем. Рабочее пространство — по
    /// умолчанию (линейное): выход в sRGB даёт правильный цвет кожи. Не
    /// копировать NSNull-настройки `LipTakeEncoder` — там YUV→YUV без
    /// управления цветом, здесь картинка для глаза.
    private lazy var context: CIContext = {
        let options: [CIContextOption: Any] = [.cacheIntermediates: false]
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: options)
        }
        return CIContext(options: options)
    }()

    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    func render(_ pixelBuffer: CVPixelBuffer, region: CGRect, size: CGSize, mirrored: Bool) -> CGImage? {
        guard size.width >= 1, size.height >= 1, region.width > 0, region.height > 0 else { return nil }
        let camera = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        let transform = LipMirrorGeometry.ciTransform(region: region, camera: camera, size: size, mirrored: mirrored)
        let downscale = size.width / region.width < 1 || size.height / region.height < 1
        let image = CIImage(cvPixelBuffer: pixelBuffer)
            // Бесконечный край: CGImage выходит непрозрачным (`noneSkipFirst`),
            // CA смешивает его дешевле, а выборка фильтра уменьшения у кромки
            // кадра не цепляет прозрачное.
            .clampedToExtent()
            .transformed(by: transform, highQualityDownsample: downscale)
        // `deferred: false` обязателен: отложенный CGImage рендерился бы при
        // отрисовке и до неё держал буфер камеры — пул захвата маленький, и
        // AVCapture начал бы ронять кадры.
        return context.createCGImage(image, from: CGRect(origin: .zero, size: size), format: .BGRA8,
                                     colorSpace: colorSpace, deferred: false)
    }

    /// Холостой рендер чёрного кадра 420v 1280×720: ядра Core Image
    /// компилируются до первого дубля, а не на первом кадре зеркала. Обе
    /// ветки масштаба: сцена в начале дубля — уменьшение, окно у рта на
    /// Retina — увеличение, и графы у них разные.
    func prewarm() {
        guard let buffer = Self.blackFrame() else { return }
        let size = CGSize(width: 448, height: 240)
        for region in [CGRect(x: 0, y: 0, width: 1280, height: 720), CGRect(x: 490, y: 380, width: 300, height: 160)] {
            _ = render(buffer, region: region, size: size, mirrored: true)
        }
    }

    /// Чёрный 420v (Y 16, CbCr 128) на IOSurface с вложениями BT.709 — как у
    /// камеры: без них Core Image пропускает стадию цвета, и прогрев
    /// скомпилировал бы не тот граф.
    static func blackFrame(width: Int = 1280, height: Int = 720) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                  kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                  attributes as CFDictionary, &buffer) == kCVReturnSuccess,
              let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        for (plane, value) in [(0, UInt8(16)), (1, UInt8(128))] {
            guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) else { return nil }
            memset(base, Int32(value), CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
                   * CVPixelBufferGetHeightOfPlane(buffer, plane))
        }
        for (key, value) in [(kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2),
                             (kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2),
                             (kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2)] {
            CVBufferSetAttachment(buffer, key, value, .shouldPropagate)
        }
        return buffer
    }
}
