import CoreGraphics
import CoreVideo
import Foundation
import Vision

/// Лицо и губы в одном кадре камеры. Координаты — пиксели кадра, начало в
/// ВЕРХНЕМ левом углу, без зеркала (как в файле).
struct LipFaceSample: Equatable {
    /// Бокс самого крупного лица; nil — лица нет.
    var box: CGRect?
    /// Сколько лиц в кадре.
    var count: Int
    /// Внешний и внутренний контуры губ самого крупного лица — для зеркала.
    var outerLips: [CGPoint]
    var innerLips: [CGPoint]

    static let none = LipFaceSample(box: nil, count: 0, outerLips: [], innerLips: [])

    /// Прямоугольник рта по внешнему контуру губ; nil — губ не нашлось.
    var mouthRect: CGRect? {
        guard let first = outerLips.first else { return nil }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in outerLips.dropFirst() {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

/// Детектор лица и губ на Apple Vision. Не потокобезопасен: живёт на одной
/// последовательной очереди (`visionQueue` камеры).
final class LipFaceTracker {
    private let request = VNDetectFaceLandmarksRequest()

    func detect(in pixelBuffer: CVPixelBuffer) -> LipFaceSample {
        let width = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let height = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up)
        do {
            try handler.perform([request])
        } catch {
            return .none
        }
        let faces = request.results ?? []
        guard let face = faces.max(by: { area($0.boundingBox) < area($1.boundingBox) }) else {
            return .none
        }
        let size = CGSize(width: width, height: height)
        // Vision отдаёт нормализованные координаты с началом внизу слева.
        let bb = face.boundingBox
        let box = CGRect(x: bb.minX * width, y: (1 - bb.maxY) * height,
                         width: bb.width * width, height: bb.height * height)
        func flip(_ points: [CGPoint]) -> [CGPoint] {
            points.map { CGPoint(x: $0.x, y: height - $0.y) }
        }
        let outer = face.landmarks?.outerLips?.pointsInImage(imageSize: size) ?? []
        let inner = face.landmarks?.innerLips?.pointsInImage(imageSize: size) ?? []
        return LipFaceSample(box: box, count: faces.count,
                             outerLips: flip(outer), innerLips: flip(inner))
    }

    private func area(_ rect: CGRect) -> CGFloat { rect.width * rect.height }
}
