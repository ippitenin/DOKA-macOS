import Foundation

/// Пороги «звучит ли речь» для гейта тишины, включая тихий режим (шёпот).
/// Чистые функции — тестируются на синтетике, без микрофона.
///
/// Обычный порог −40 дБFS — это ровно `AudioRecorder.speechLevelThreshold` (0.2)
/// на старой кривой `(db + 50) / 50`. Сам `AudioRecorder` по-прежнему считает
/// по той кривой: на ней калибрована статистика дашборда, и трогать её нельзя.
enum SpeechMeter {
    static let standardThresholdDb: Float = -40

    /// Порог тихого режима. Замер на реальных записях (MacBook Pro, тихая комната,
    /// 16 кГц, буферы ~21 мс): шёпот — медиана −45,6, p90 −42 дБFS, то есть почти
    /// целиком ниже обычного порога (на −40 гейт насчитал 0,15 с речи на 38 с шёпота).
    /// Тишина комнаты — медиана −55, p99 −48,5, максимум −46. На −48 шёпот дал 8,3 с
    /// из 38, тишина — 0,19 с из 26: случайное нажатие гейт по-прежнему отсеет.
    static let quietThresholdDb: Float = -48

    /// Подъём уровня для панелей записи в тихом режиме (+12 дБ): пол их кривой
    /// (~−41 дБFS) выше шёпота, и без подъёма волна стояла бы на месте.
    static let quietDisplayGain: Float = 4

    static func decibels(rms: Float) -> Float {
        20 * log10(max(rms, 1e-7))
    }

    static func isQuietSpeech(db: Float) -> Bool {
        db >= quietThresholdDb
    }

    /// Время речи по обоим порогам — тем же расчётом по буферам, что в
    /// `AudioRecorder` (RMS буфера → дБFS → порог). Для тестов и калибровки.
    static func measure(samples: [Float], sampleRate: Double,
                        bufferFrames: Int = 1024) -> (standard: TimeInterval, quiet: TimeInterval) {
        var standard: TimeInterval = 0
        var quiet: TimeInterval = 0
        var start = 0
        while start < samples.count {
            let end = min(start + bufferFrames, samples.count)
            var sum: Float = 0
            for i in start..<end { sum += samples[i] * samples[i] }
            let db = decibels(rms: sqrt(sum / Float(end - start)))
            let seconds = Double(end - start) / sampleRate
            if db >= standardThresholdDb { standard += seconds }
            if isQuietSpeech(db: db) { quiet += seconds }
            start = end
        }
        return (standard, quiet)
    }
}
