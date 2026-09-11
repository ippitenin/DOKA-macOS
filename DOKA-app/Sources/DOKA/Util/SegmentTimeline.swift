import Foundation

/// Какой сегмент расшифровки звучит сейчас. Чистая функция: плеер тикает
/// 20 раз в секунду, а в часовой записи сотни сегментов — поэтому бинарный
/// поиск, а не проход по списку на каждый тик.
enum SegmentTimeline {
    /// Индекс последнего сегмента с `start <= time`; nil — до первого сегмента
    /// (или время не число). `starts` ожидаются по возрастанию — так их отдают
    /// и сервер, и локальная нарезка.
    static func activeIndex(starts: [Double], time: Double) -> Int? {
        guard time.isFinite, let first = starts.first, time >= first else { return nil }
        var low = 0
        var high = starts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if starts[mid] <= time {
                low = mid
            } else {
                high = mid - 1
            }
        }
        return low
    }
}
