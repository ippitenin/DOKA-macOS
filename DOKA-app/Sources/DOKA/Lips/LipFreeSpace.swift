import Foundation

/// Свободное место на томе данных — кэш для старта дубля губ.
///
/// Опрос тома (`volumeAvailableCapacityForImportantUsage`) — около 30 мс, а на
/// почти полном диске и дольше; на главном потоке при старте КАЖДОЙ диктовки
/// это была бы задержка до начала записи. Поэтому значение опрашивается фоном
/// (при настройке камеры и после каждого дубля), а старт только читает кэш.
final class LipFreeSpace: @unchecked Sendable {
    /// Меньше — дубль не начинается: сырьё длинной диктовки весит десятки
    /// мегабайт, и забивать диск до отказа ради пар нельзя.
    static let minBytes: Int64 = 2 * 1024 * 1024 * 1024

    private let probe: @Sendable () -> Int64?
    private let queue = DispatchQueue(label: "com.pitenin.doka.lips.freespace", qos: .utility)
    private let lock = NSLock()
    private var cached: Int64?

    init(probe: @escaping @Sendable () -> Int64? = LipFreeSpace.systemProbe) {
        self.probe = probe
    }

    /// Последнее известное значение; nil — ещё не опрашивали или том не ответил.
    var value: Int64? {
        lock.lock()
        defer { lock.unlock() }
        return cached
    }

    /// Хватает ли места. Неизвестно — не мешаем диктовке.
    var hasRoom: Bool {
        guard let value else { return true }
        return value > Self.minBytes
    }

    /// Опросить том фоном. `completion` — на фоновой очереди.
    func refresh(completion: (@Sendable () -> Void)? = nil) {
        queue.async { [self] in
            let bytes = probe()
            lock.lock()
            cached = bytes
            lock.unlock()
            completion?()
        }
    }

    static let systemProbe: @Sendable () -> Int64? = {
        let values = try? AppDataFolder.defaultURL
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}
