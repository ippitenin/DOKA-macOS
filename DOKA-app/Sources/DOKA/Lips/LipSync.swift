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
