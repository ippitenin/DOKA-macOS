import Foundation

/// Чистая логика сшивки видео губ с WAV диктовки.
enum LipSync {
    /// Первые кадры холодной камеры не годятся никогда: экспозиция и баланс
    /// белого ещё едут.
    static let warmupMin: TimeInterval = 0.2
    /// Дольше ждать стабильности нельзя: иначе на мерцающем свете потеряли бы
    /// весь дубль.
    static let warmupMax: TimeInterval = 1.0
    /// Столько кадров подряд яркость должна стоять, чтобы считаться стабильной.
    static let stableRun = 5
    /// Допуск изменения средней яркости (0…255) между соседними кадрами.
    static let lumaTolerance = 1.5

    /// Индекс первого кадра после прогрева экспозиции. `times` — секунды от
    /// первого кадра, `lumas` — средняя яркость кадра (0…255). nil — полезного
    /// видео нет (клип короче минимума прогрева).
    static func stableStart(times: [Double], lumas: [Double]) -> Int? {
        precondition(times.count == lumas.count)
        guard let first = times.firstIndex(where: { $0 >= warmupMin }) else { return nil }
        for i in first..<times.count {
            if times[i] >= warmupMax { return i }
            let end = i + stableRun - 1
            guard end < times.count else { break }
            let stable = (i..<end).allSatisfy { abs(lumas[$0 + 1] - lumas[$0]) < lumaTolerance }
            if stable { return i }
        }
        return nil
    }
}

/// Какой исходный кадр показывать в каждом выходном кадре клипа.
struct LipSchedule: Equatable {
    /// Индекс исходного кадра для выходного кадра k (k/fps секунд от начала
    /// WAV). Не убывает — второй проход читает файл строго вперёд.
    let sourceIndex: [Int]
    /// С какой и по какую секунду шкалы WAV видео настоящее; вне окна —
    /// повтор первого или последнего кадра.
    let validFrom: Double
    let validTo: Double
}

extension LipSync {
    /// Частота клипа: WISLIP всё равно пересэмплирует в 25 к/с, а 30 — родная
    /// частота камер Mac.
    static let outputFps = 30.0
    /// Поправка «видео относительно звука», выставляется тестом с хлопком.
    static let avCalibration: Double = 0

    /// Хост-время кадров → секунды шкалы WAV (с поправкой на задержку входа).
    static func wavTimes(hosts: [Double], timing: RecordingTiming) -> [Double] {
        let zero = timing.wavHostStart
        return hosts.map { $0 - zero + avCalibration }
    }

    /// Расписание постоянной частоты на всю длину WAV: каждый выходной кадр
    /// берёт ближайший исходный. Выпавшие кадры повторяются, лишние
    /// пропускаются, до первого и после последнего кадра — повтор крайнего.
    /// `times` — секунды шкалы WAV ПОЛЕЗНЫХ кадров (после прогрева), по
    /// возрастанию. nil — кадров нет.
    static func schedule(times: [Double], duration: Double) -> LipSchedule? {
        guard let first = times.first, let last = times.last, duration > 0 else { return nil }
        let count = max(1, Int((duration * outputFps - 1e-9).rounded(.up)))
        var indices: [Int] = []
        indices.reserveCapacity(count)
        var j = 0
        for k in 0..<count {
            let t = Double(k) / outputFps
            while j + 1 < times.count, abs(times[j + 1] - t) <= abs(times[j] - t) { j += 1 }
            indices.append(j)
        }
        return LipSchedule(sourceIndex: indices,
                           validFrom: max(0, first),
                           validTo: min(duration, last + 1 / outputFps))
    }

    /// Фактическая частота по меткам кадров; 0 — меньше двух кадров.
    static func measuredFps(times: [Double]) -> Double {
        guard times.count >= 2, let first = times.first, let last = times.last, last > first else { return 0 }
        return Double(times.count - 1) / (last - first)
    }
}
