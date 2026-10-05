import CoreGraphics
@testable import DOKA

/// Синтетическое лицо в порядке Vision rev3/76 — общее для тестов зеркала.
/// Координаты — пиксели кадра 1280×720, сверху слева.
enum LipSyntheticFace {
    /// Внешний контур — 14 точек: 13 — левый уголок, 0…6 — верх слева
    /// направо, 7 — правый уголок, 8…12 — низ справа налево; внутренний — 6
    /// точек без уголков, 0…2 — верх слева направо, 3…5 — низ справа налево.
    /// `upper`/`lower` — точек между уголками (5 и 3 — созвездие 65: уголки 9
    /// и 5). `spacing` раскладывает точки верхней губы по ширине (тождество —
    /// равномерно); отрицательный `gap` перекрещивает внутренний контур.
    static func lips(center: CGPoint = CGPoint(x: 640, y: 480), halfWidth w: CGFloat = 60,
                     gap: CGFloat = 8, upper: Int = 7, lower: Int = 5,
                     spacing: (CGFloat) -> CGFloat = { $0 }) -> (outer: [CGPoint], inner: [CGPoint]) {
        func at(_ t: CGFloat, _ lift: CGFloat) -> CGPoint {
            CGPoint(x: center.x - w + 2 * w * t, y: center.y - lift * sin(.pi * t))
        }
        var outer = (0..<upper).map { at(spacing(CGFloat($0 + 1) / CGFloat(upper + 1)), 24) }
        outer.append(CGPoint(x: center.x + w, y: center.y))
        outer += (0..<lower).map { at(1 - CGFloat($0 + 1) / CGFloat(lower + 1), -26) }
        outer.append(CGPoint(x: center.x - w, y: center.y))
        let inner = [0.3, 0.5, 0.7].map { at($0, gap / 2) } + [0.7, 0.5, 0.3].map { at($0, -gap / 2) }
        return (outer, inner)
    }

    /// Лицо анфас: рот с серединой уголков `mouth`, межглазное 126 px на 1,1
    /// межглазного выше рта, бокс детектора 345 px вокруг глаз.
    static func sample(mouth: CGPoint = CGPoint(x: 640, y: 480)) -> LipFaceSample {
        let d: CGFloat = 126, side: CGFloat = 345
        let eyes = CGPoint(x: mouth.x, y: mouth.y - 1.1 * d)
        let lips = lips(center: mouth, halfWidth: 0.836 * d / 2)
        var sample = LipFaceSample(box: CGRect(x: eyes.x - side / 2, y: eyes.y - 0.4 * side, width: side, height: side),
                                   count: 1, outerLips: lips.outer, innerLips: lips.inner)
        // Порядок Vision: левый глаз лица — справа в кадре.
        sample.eyes = [CGPoint(x: eyes.x + d / 2, y: eyes.y), CGPoint(x: eyes.x - d / 2, y: eyes.y)]
        sample.lipContoursClosed = true
        return sample
    }

    /// Лицо есть, губ нет.
    static func faceWithoutLips(mouth: CGPoint = CGPoint(x: 640, y: 480)) -> LipFaceSample {
        var face = sample(mouth: mouth)
        face.outerLips = []
        face.innerLips = []
        return face
    }
}
