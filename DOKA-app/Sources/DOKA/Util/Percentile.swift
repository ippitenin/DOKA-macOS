import Foundation

/// Перцентиль по ближайшему рангу: элемент с индексом `round(p · (n − 1))`
/// отсортированного ряда, без интерполяции. Один расчёт для сводок лога
/// (время Vision, рендер и латентность зеркала) и для кропа дубля губ.
enum Percentile {
    /// `sorted` — ряд по возрастанию; nil — ряд пуст.
    static func nearestRank<T: BinaryFloatingPoint>(_ sorted: [T], _ p: Double) -> T? {
        guard !sorted.isEmpty else { return nil }
        return sorted[Int((p * Double(sorted.count - 1)).rounded())]
    }

    /// Перцентиль с линейной интерполяцией между соседними элементами — как
    /// `numpy.percentile` по умолчанию. Нужен там, где Swift обязан повторить
    /// расчёт стенда на Python (`ExclamationDetector`). `sorted` — по возрастанию.
    static func linear(_ sorted: [Double], _ p: Double) -> Double? {
        guard !sorted.isEmpty else { return nil }
        let position = p * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = min(lower + 1, sorted.count - 1)
        return sorted[lower] + (sorted[upper] - sorted[lower]) * (position - Double(lower))
    }

    /// p50 и p95 одной сортировкой, в миллисекундах — для логов; nil — ряд пуст.
    static func millisecondsSummary(seconds: [Double]) -> (count: Int, p50: Double, p95: Double)? {
        let sorted = seconds.sorted()
        guard let p50 = nearestRank(sorted, 0.5), let p95 = nearestRank(sorted, 0.95) else { return nil }
        return (sorted.count, p50 * 1000, p95 * 1000)
    }
}
