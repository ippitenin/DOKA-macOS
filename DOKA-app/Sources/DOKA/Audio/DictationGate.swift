import Foundation

/// Решение, отправлять ли запись диктовки на распознавание. Чистая функция —
/// покрыта тестами. `speechDuration` — время выше
/// `AudioRecorder.speechLevelThreshold` по СТАРОЙ dB-кривой; сам порог здесь
/// не трогаем (ловушка CLAUDE.md: на нём калибрована статистика дашборда).
enum DictationGate {
    enum Decision: Equatable {
        case tooShort      // случайное нажатие — молча в покой
        case noSpeech      // речи не слышно — на распознавание не отправляем
        case transcribe
    }

    /// Минимальная длительность записи, ниже которой API не вызывается.
    static let minDuration: TimeInterval = 0.4
    /// Минимум активной речи. Тишина и отключённый микрофон дают ≈ 0, щелчки
    /// клавиш и дыхание — 0.05–0.1 с, короткое «да» — около 0.25–0.35 с.
    static let minSpeechDuration: TimeInterval = 0.25
    /// Отсеянную гейтом запись от этой длины можно распознать всё равно
    /// (слот повтора): страховка для тихих голосов и дальних микрофонов.
    static let retryableMinDuration: TimeInterval = 1.0

    static func decide(duration: TimeInterval, speechDuration: TimeInterval,
                       speechGateEnabled: Bool) -> Decision {
        if duration < minDuration { return .tooShort }
        if speechGateEnabled && speechDuration < minSpeechDuration { return .noSpeech }
        return .transcribe
    }

    static func isRetryable(duration: TimeInterval) -> Bool {
        duration >= retryableMinDuration
    }
}
