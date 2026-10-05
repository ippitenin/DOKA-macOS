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
    /// Центры контуров глаз (`leftEye`, затем `rightEye` — как у Vision) —
    /// опора масштаба и наклона, которая не «дышит» от речи. Именно центроиды
    /// контуров, а не зрачки: зрачки Vision при моргании неточны. Пусто —
    /// хотя бы одного глаза не нашлось.
    var eyes: [CGPoint] = []

    static let none = LipFaceSample(box: nil, count: 0, outerLips: [], innerLips: [])

    /// Глаза слева направо в кадре; nil — глаз не два. Порядок Vision (левый,
    /// правый глаз ЧЕЛОВЕКА) в незеркальном кадре идёт справа налево.
    static func eyesLeftToRight(_ eyes: [CGPoint]) -> (left: CGPoint, right: CGPoint)? {
        guard eyes.count == 2 else { return nil }
        let sorted = eyes.sorted { $0.x < $1.x }
        return (sorted[0], sorted[1])
    }
}

/// Поиск лица в кадре. Шов для тестов: движок камеры знает детектор только
/// через протокол, а тесты подставляют свой — без Vision и без камеры.
protocol LipFaceDetecting: AnyObject {
    /// Лицо в кадре; ошибка — Vision не справился с кадром.
    func detect(in pixelBuffer: CVPixelBuffer) throws -> LipFaceSample
}

/// Детектор лица и губ на Apple Vision. Не потокобезопасен: живёт на одной
/// последовательной очереди (`visionQueue` камеры).
final class LipFaceTracker: LipFaceDetecting {
    /// Запрос создаётся на первом кадре: конструктор движка камеры Vision не
    /// трогает (тесты событий дубля остаются быстрыми).
    private lazy var request = Self.makeRequest()
    private var loggedFormat = false

    /// Ревизия — явно третья: умолчание — последняя ревизия SDK сборки, и
    /// бокс и число лиц в журнале (договор с WISLIP) тихо поменялись бы с
    /// новым Xcode. Созвездие — 76 точек вместо 65: контур губ плотнее, и у
    /// точек есть оценка точности. Журнал от созвездия не зависит: на стенде
    /// (48 роликов 1280×720, 8774 кадра, macOS 27) бокс и число лиц у 65 и 76
    /// точек совпали до бита, а умолчание `VNDetectFaceLandmarksRequest()`
    /// там уже и есть ревизия 3 + 76 точек. Полная детекция — p95 ≈ 10 мс.
    static func makeRequest() -> VNDetectFaceLandmarksRequest {
        let request = VNDetectFaceLandmarksRequest()
        request.revision = VNDetectFaceLandmarksRequestRevision3
        if VNDetectFaceLandmarksRequest.revision(VNDetectFaceLandmarksRequestRevision3,
                                                 supportsConstellation: .constellation76Points) {
            request.constellation = .constellation76Points
        }
        return request
    }

    func detect(in pixelBuffer: CVPixelBuffer) throws -> LipFaceSample {
        let width = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let height = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up)
        try handler.perform([request])
        let faces = request.results ?? []
        guard let face = faces.max(by: { area($0.boundingBox) < area($1.boundingBox) }) else {
            return .none
        }
        let size = CGSize(width: width, height: height)
        // Vision отдаёт нормализованные координаты с началом внизу слева.
        let bb = face.boundingBox
        let box = CGRect(x: bb.minX * width, y: (1 - bb.maxY) * height,
                         width: bb.width * width, height: bb.height * height)
        func points(_ region: VNFaceLandmarkRegion2D?) -> [CGPoint] {
            (region?.pointsInImage(imageSize: size) ?? []).map { CGPoint(x: $0.x, y: height - $0.y) }
        }
        func centroid(_ region: VNFaceLandmarkRegion2D?) -> CGPoint? {
            let all = points(region)
            guard !all.isEmpty else { return nil }
            let n = CGFloat(all.count)
            return CGPoint(x: all.reduce(0) { $0 + $1.x } / n, y: all.reduce(0) { $0 + $1.y } / n)
        }
        let landmarks = face.landmarks
        // Единственная попытка лога — на лице с точками: иначе он записал
        // бы нули, и до конца процесса правды о формате было бы не узнать.
        if !loggedFormat, let landmarks {
            loggedFormat = true
            logFormat(landmarks, pixelBuffer)
        }
        let outer = landmarks?.outerLips, inner = landmarks?.innerLips
        let eyes = [centroid(landmarks?.leftEye), centroid(landmarks?.rightEye)].compactMap { $0 }
        return LipFaceSample(box: box, count: faces.count,
                             outerLips: points(outer), innerLips: points(inner),
                             eyes: eyes.count == 2 ? eyes : [])
    }

    private func area(_ rect: CGRect) -> CGFloat { rect.width * rect.height }

    /// Один раз за жизнь детектора: сколько точек реально отдаёт Vision и
    /// как камера размечает цвет кадра (матрица YCbCr, первичные цвета,
    /// передаточная функция) — без этого не подобрать ни сетку, ни пересчёт цвета.
    private func logFormat(_ landmarks: VNFaceLandmarks2D, _ pixelBuffer: CVPixelBuffer) {
        func count(_ region: VNFaceLandmarkRegion2D?) -> Int { region?.pointCount ?? 0 }
        func attachment(_ key: CFString) -> String {
            CVBufferCopyAttachment(pixelBuffer, key, nil).map { "\($0)" } ?? "—"
        }
        let type = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let fourCC = String((0..<4).map { Character(UnicodeScalar(UInt8((type >> (24 - 8 * $0)) & 0xFF))) })
        NSLog("DOKA: губы — Vision: ревизия %d, созвездие %d, точек %d (губы %d + %d, глаза %d + %d); кадр %@ %dx%d, матрица %@, первичные %@, передача %@",
              request.revision, request.constellation.rawValue, count(landmarks.allPoints),
              count(landmarks.outerLips), count(landmarks.innerLips),
              count(landmarks.leftEye), count(landmarks.rightEye),
              fourCC, CVPixelBufferGetWidth(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer),
              attachment(kCVImageBufferYCbCrMatrixKey), attachment(kCVImageBufferColorPrimariesKey),
              attachment(kCVImageBufferTransferFunctionKey))
    }
}
