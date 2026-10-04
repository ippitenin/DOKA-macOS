import Foundation

/// Метки времени записи для сшивки видео губ с WAV (эксперимент «Губы»).
/// Хост-время — секунды `mach_absolute_time`: та же база у `AVAudioTime`,
/// часов `AVCaptureSession` (после `CMSyncConvertTime`) и `CACurrentMediaTime`.
struct RecordingTiming: Equatable {
    /// Хост-время первого буфера tap (без поправки на задержку входа).
    let hostStart: TimeInterval
    /// Задержка входа (`inputNode.presentationLatency`): звук буфера прозвучал
    /// на столько раньше его хост-времени. У Bluetooth-микрофонов — сотни мс.
    let inputLatency: TimeInterval
    /// Начало речи, секунды от начала WAV; nil — речи не нашлось.
    let speechOnset: TimeInterval?
    /// Наибольшее расхождение хост-времени буфера с «старт + накопленный звук».
    /// Растёт, когда аудиодвижок теряет буферы: тогда шкала WAV и хост-часы
    /// расходятся, и губы со звуком не сшить.
    let maxClockDrift: TimeInterval

    /// Хост-время нулевого сэмпла WAV.
    var wavHostStart: TimeInterval { hostStart - inputLatency }
}

/// Начало речи по буферам tap. Сигнал старта «Pop» играет, когда микрофон
/// уже пишет, и на тихом пороге даёт 0,06–0,13 с «речи» — поэтому первые
/// 0,2 с не считаются, а речью признаются только три буфера подряд (~64 мс).
struct SpeechOnsetTracker {
    static let ignoredHead: TimeInterval = 0.2
    static let requiredBuffers = 3

    private(set) var onset: TimeInterval?
    private var run = 0
    private var runStart: TimeInterval = 0

    /// `start` — время начала буфера от начала записи, сек.
    mutating func feed(isSpeech: Bool, at start: TimeInterval) {
        guard onset == nil else { return }
        guard isSpeech, start >= Self.ignoredHead else {
            run = 0
            return
        }
        if run == 0 { runStart = start }
        run += 1
        if run >= Self.requiredBuffers { onset = runStart }
    }
}

/// Сверка хост-времени буферов с накопленным звуком.
struct HostClockDriftTracker {
    private(set) var hostStart: TimeInterval?
    private(set) var maxDrift: TimeInterval = 0

    /// `host` — хост-время буфера, `elapsed` — сколько секунд звука записано до него.
    mutating func feed(host: TimeInterval, elapsed: TimeInterval) {
        guard let start = hostStart else {
            hostStart = host - elapsed
            return
        }
        maxDrift = max(maxDrift, abs(host - (start + elapsed)))
    }
}
