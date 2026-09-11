import AVFoundation
import Foundation

/// Воспроизведение записей для SwiftUI-плееров: аудио истории диктовок и
/// архив звука записей библиотеки. Один активный плеер на всё приложение
/// (singleton): одновременно звучит одна запись, id диктовок и файловых
/// записей не пересекаются, а перенос «Папки данных» останавливает всё сразу.
@MainActor
final class RecordingPlayer: NSObject, ObservableObject {
    static let shared = RecordingPlayer()

    /// id записи, чьё аудио сейчас загружено (для подсветки нужной карточки).
    @Published private(set) var currentRecordID: UUID?
    @Published private(set) var isPlaying = false
    /// Двусторонняя привязка к слайдеру. Пока тащим ползунок — тикер её не перетирает.
    @Published var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    /// Скорость воспроизведения (плеер библиотеки). Переживает смену записи
    /// внутри библиотеки; история скоростью не управляет — `toggle` её сбрасывает.
    @Published var rate: Float = 1 {
        didSet { player?.rate = rate }
    }
    /// Выставляется вью на время drag слайдера.
    var isScrubbing = false

    private var player: AVAudioPlayer?
    private var ticker: Timer?

    private override init() { super.init() }

    /// Загружает (если ещё не та запись) и play/pause toggle — плеер истории.
    func toggle(url: URL, recordID: UUID) {
        if currentRecordID == recordID, player != nil {
            isPlaying ? pause() : play()
            return
        }
        // У плеера истории нет выбора скорости: запись не должна внезапно
        // заиграть на скорости, выставленной в библиотеке.
        rate = 1
        load(url: url, recordID: recordID)
        play()
    }

    /// Воспроизведение с позиции (клик по тайм-коду, плеер библиотеки).
    func play(url: URL, recordID: UUID, from time: TimeInterval) {
        guard ensureLoaded(url: url, recordID: recordID) else { return }
        seek(to: time)
        play()
    }

    /// Загрузить запись, если загружена другая (без воспроизведения) — чтобы
    /// перемотка слайдером и ±5 с работали и до первого нажатия «Play».
    @discardableResult
    func ensureLoaded(url: URL, recordID: UUID) -> Bool {
        if currentRecordID == recordID, player != nil { return true }
        load(url: url, recordID: recordID)
        return player != nil
    }

    func play() {
        guard let player else { return }
        player.play()
        isPlaying = true
        startTicker()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        stopTicker()
    }

    /// Перемотка ползунком.
    func seek(to time: TimeInterval) {
        guard let player else { return }
        let t = min(max(0, time), duration)
        player.currentTime = t
        currentTime = t
    }

    /// Перемотка на `delta` секунд от текущей позиции (±5 с).
    func skip(by delta: TimeInterval) {
        guard player != nil else { return }
        seek(to: currentTime + delta)
    }

    /// Полная остановка и выгрузка — при сворачивании карточки / смене секции / удалении.
    func stop() {
        stopTicker()
        player?.stop()
        player = nil
        isPlaying = false
        currentRecordID = nil
        currentTime = 0
        duration = 0
    }

    /// Остановить, только если загружена именно эта запись.
    func stopIfCurrent(_ recordID: UUID) {
        if currentRecordID == recordID { stop() }
    }

    private func load(url: URL, recordID: UUID) {
        stop()
        guard let p = try? AVAudioPlayer(contentsOf: url) else { return }
        p.delegate = self
        // enableRate — ДО prepareToPlay, иначе смена скорости молча не действует.
        p.enableRate = true
        p.prepareToPlay()
        p.rate = rate
        player = p
        currentRecordID = recordID
        duration = p.duration
        currentTime = 0
    }

    private func startTicker() {
        stopTicker()
        // Таймер запланирован на главном runloop и срабатывает на главном потоке.
        ticker = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let player = self.player, !self.isScrubbing else { return }
                self.currentTime = player.currentTime
            }
        }
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }
}

extension RecordingPlayer: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isPlaying = false
            self.currentTime = 0
            self.stopTicker()
        }
    }
}
