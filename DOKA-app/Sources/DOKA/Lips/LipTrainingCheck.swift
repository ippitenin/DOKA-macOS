import Foundation

/// Решение по фразе тренировки ДО фиксации — по одному звуку, сразу после
/// стопа. Остальное (камера, губы, синхронизация) решит обработка пары тем
/// же `LipTakeVerdict`, что у диктовки. Чистая логика.
enum LipTrainingCheck: Equatable {
    case keep
    /// Случайное нажатие: фразу за секунду не проговорить.
    case tooShort
    /// Прозвучал голос — беззвучной такую пару не назвать.
    case voiced

    static let minDuration: TimeInterval = 1.0
    /// Автостоп: фраза WISLIP — не длиннее 13 с.
    static let maxDuration: TimeInterval = 13

    /// Больше стольких секунд речи по ОБЫЧНОМУ порогу (−40 дБFS) — фразу
    /// сказали вслух. Замер 6.10.2026 на клипах WISLIP (окна 21 мс, как у
    /// записи): вслух — от 1,02 с (80 из 80), беззвучно — до 0,51 с (79 из
    /// 80; выброс 4,2 с — фраза, сказанная вслух по ошибке); сигнал старта
    /// «Pop» добавляет до 0,13 с.
    ///
    /// Шёпот уровнем от беззвучного НЕ отличить: по тихому порогу (−48)
    /// беззвучные и шёпотные клипы перекрываются целиком — фон помещения и
    /// усиление микрофона в двух сессиях записи разные, а сам шёпот тихий.
    /// Поэтому проверка ловит только голос; от шёпота бережёт подсказка
    /// «только губами».
    static let maxVoicedSeconds: TimeInterval = 0.7

    static func decide(duration: TimeInterval, speechSeconds: TimeInterval) -> LipTrainingCheck {
        if duration < minDuration { return .tooShort }
        if speechSeconds > maxVoicedSeconds { return .voiced }
        return .keep
    }

    /// Момент подсказки «Говорите» на шкале WAV — это `speechOnset` пары:
    /// раньше подсказки человек не начинает. nil — подсказки не было (губ не
    /// дождались) или звук не дал хост-времени.
    static func onset(cueHost: TimeInterval?, timing: RecordingTiming?) -> TimeInterval? {
        guard let cueHost, let timing else { return nil }
        return max(0, cueHost - timing.wavHostStart)
    }
}
