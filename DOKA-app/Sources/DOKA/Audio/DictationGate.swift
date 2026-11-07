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

    /// Запасной путь: доля записи, которую должна занять речь по тихому порогу
    /// (−48 дБ). Без доли длинная тишина набирала бы 0,25 с: тишина комнаты на
    /// −48 даёт 0,19 с из 26 с (0,7 %, замер `SpeechMeter`), а тихий голос на
    /// короткой фразе — десятки процентов.
    static let fallbackMinShare: Double = 0.05

    /// - Parameter fallbackSpeechDuration: речь по тихому порогу (−48 дБ). Спасает
    ///   короткие фразы, когда громкость входа микрофона опущена: 7.11.2026 при
    ///   29 % обычный порог засчитывал речью 8 % записи, и «CI зелёный, конфликтов
    ///   нет» уходило в «Речь не услышана». В тихом режиме гейт и так считает по
    ///   −48 — туда передаётся 0.
    static func decide(duration: TimeInterval, speechDuration: TimeInterval,
                       fallbackSpeechDuration: TimeInterval = 0,
                       speechGateEnabled: Bool) -> Decision {
        if duration < minDuration { return .tooShort }
        guard speechGateEnabled else { return .transcribe }
        if speechDuration >= minSpeechDuration { return .transcribe }
        let fallbackPasses = fallbackSpeechDuration >= minSpeechDuration
            && fallbackSpeechDuration >= duration * fallbackMinShare
        return fallbackPasses ? .transcribe : .noSpeech
    }

    /// Что сказать человеку, когда гейт отсеял запись.
    enum NoSpeechMessage: Equatable {
        case plain
        /// Громкость входа ниже `lowInputVolume`, а буст выключен: причина и
        /// лекарство видны сразу, без похода в журнал.
        case lowInput(percent: Int)
    }

    /// Громкость входа ниже этой доли считается «тихим микрофоном».
    static let lowInputVolume: Float = 0.5

    static func noSpeechMessage(inputVolume: Float?, boostEnabled: Bool,
                                quiet: Bool) -> NoSpeechMessage {
        // С бустом громкость на время записи и так максимальная; шёпот тих сам по себе.
        guard !boostEnabled, !quiet, let inputVolume, inputVolume < lowInputVolume else {
            return .plain
        }
        return .lowInput(percent: Int((inputVolume * 100).rounded()))
    }

    static func isRetryable(duration: TimeInterval) -> Bool {
        duration >= retryableMinDuration
    }
}
