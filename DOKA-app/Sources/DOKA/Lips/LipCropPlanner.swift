import CoreGraphics
import Foundation

/// Фиксированный кроп на весь дубль губ.
///
/// WISLIP сам ищет лицо в кадре (S3FD на уменьшенном вчетверо кадре — лицо
/// должно остаться крупнее 25 px) и сам трекает его, поэтому DOKA нужен один
/// квадрат, где лицо есть всегда, с запасом и без дрожи. Покадровый кроп
/// дал бы ложные «смены сцены», а тесный — лицо, которое WISLIP не найдёт.
enum LipCropPlanner {
    /// Сторона выходного кадра клипа.
    static let outputSide = 512.0
    /// Квадрат не меньше стольких лиц — запас, под который WISLIP кропит сам
    /// (центр ± 1,4 полубокса).
    static let faceMultiple = 2.3
    /// Запас вокруг пути головы, в лицах.
    static let travelMargin = 1.0
    static let minSide = 384.0
    /// Центр сдвигается вниз на долю лица: рот ниже центра бокса.
    static let downShift = 0.1

    struct Plan: Equatable {
        /// Квадрат в пикселях кадра камеры (начало сверху слева), целые чётные.
        let rect: CGRect
        /// Размер лица в выходном кадре 512 px.
        let faceInOutputPx: Double
    }

    /// `faces` — боксы лица в полезном окне дубля (пиксели, начало сверху слева).
    static func plan(faces: [CGRect], frame: CGSize) -> Plan? {
        guard !faces.isEmpty else { return nil }
        let size = median(faces.map { max($0.width, $0.height) })
        let center = CGPoint(x: median(faces.map(\.midX)), y: median(faces.map(\.midY)))
        // Выбросы: бокс другого размера (лицо на плакате) или очень далеко от
        // обычного места лица.
        var kept = faces.filter { box in
            let s = max(box.width, box.height)
            return s >= 0.6 * size && s <= 1.6 * size
                && hypot(box.midX - center.x, box.midY - center.y) <= 2 * size
        }
        if kept.isEmpty { kept = faces }

        // Путь головы по 5-му и 95-му процентилю — редкие ложные боксы не
        // раздувают квадрат.
        let minX = percentile(kept.map(\.minX), 0.05), maxX = percentile(kept.map(\.maxX), 0.95)
        let minY = percentile(kept.map(\.minY), 0.05), maxY = percentile(kept.map(\.maxY), 0.95)
        let travel = max(maxX - minX, maxY - minY)

        let limit = min(frame.width, frame.height)
        var side = max(faceMultiple * size, travel + travelMargin * size, minSide)
        side = min(side, limit)
        side = floor(side / 2) * 2

        let cx = (minX + maxX) / 2
        let cy = (minY + maxY) / 2 + downShift * size
        var x = even(cx - side / 2)
        var y = even(cy - side / 2)
        x = min(max(0, x), floor((frame.width - side) / 2) * 2)
        y = min(max(0, y), floor((frame.height - side) / 2) * 2)
        return Plan(rect: CGRect(x: x, y: y, width: side, height: side),
                    faceInOutputPx: size * outputSide / side)
    }

    private static func even(_ v: CGFloat) -> CGFloat { (v / 2).rounded() * 2 }

    private static func median(_ values: [CGFloat]) -> CGFloat {
        percentile(values, 0.5)
    }

    private static func percentile(_ values: [CGFloat], _ p: Double) -> CGFloat {
        let sorted = values.sorted()
        let index = Int((p * Double(sorted.count - 1)).rounded())
        return sorted[index]
    }
}
