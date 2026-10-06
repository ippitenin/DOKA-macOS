import Foundation

/// Очередь фраз сеанса тренировки. Чистая логика.
///
/// Пулы (история, рабочие, бытовые) перемешиваются каждый своим порядком и
/// идут по кругу — фразы разного рода чередуются, и сеанс не превращается в
/// полсотни одинаковых рабочих указаний подряд. Уже записанные фразы
/// (нормализованный текст, `LipTrainingPhrases.normalize`) не предлагаются;
/// одинаковая фраза в двух пулах остаётся в первом.
struct LipTrainingQueue {
    private(set) var items: [LipTrainingPhrase]

    init(pools: [[LipTrainingPhrase]], done: Set<String>, seed: UInt64) {
        var generator = SplitMix64(seed: seed)
        var seen = done
        var shuffled: [[LipTrainingPhrase]] = []
        for pool in pools {
            let fresh = pool.filter { seen.insert(LipTrainingPhrases.normalize($0.text)).inserted }
            shuffled.append(fresh.shuffled(using: &generator))
        }
        var items: [LipTrainingPhrase] = []
        let longest = shuffled.map(\.count).max() ?? 0
        for index in 0..<longest {
            for pool in shuffled where index < pool.count { items.append(pool[index]) }
        }
        self.items = items
    }

    /// Пустая очередь — пока фразы сеанса грузятся.
    static let empty = LipTrainingQueue(pools: [], done: [], seed: 0)

    /// Фраза на экране; nil — фразы кончились.
    var current: LipTrainingPhrase? { items.first }
    var count: Int { items.count }

    /// Фраза записана — убрать её.
    mutating func advance() {
        guard !items.isEmpty else { return }
        items.removeFirst()
    }

    /// «Пропустить» — фраза уходит в конец очереди.
    mutating func skip() {
        guard items.count > 1 else { return }
        items.append(items.removeFirst())
    }

    /// Вернуть фразу, которую отбросила обработка: она придёт снова через
    /// `after` фраз — сразу же повторять ту же фразу скучно, а причина
    /// (свет, ладонь) могла уже уйти.
    mutating func requeue(_ phrase: LipTrainingPhrase, after: Int = 3) {
        items.insert(phrase, at: min(after, items.count))
    }

    /// «Переписать прошлую» — фраза снова на экране.
    mutating func pushFront(_ phrase: LipTrainingPhrase) {
        items.insert(phrase, at: 0)
    }
}

/// Детерминированный генератор для перемешивания: тестам нужен
/// воспроизводимый порядок, приложение берёт случайное зерно на сеанс.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
