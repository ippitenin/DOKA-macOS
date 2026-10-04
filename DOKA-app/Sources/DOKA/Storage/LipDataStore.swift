import Foundation

/// Хранилище пар «губы + текст» (эксперимент «Губы»).
///
/// Дубль уходит в обработку, когда сошлись два независимых события:
/// камера дописала сырьё (`captureFinished`) и диктовка зафиксирована
/// (`commit`). Порядок любой: локальное распознавание бывает быстрее, чем
/// камера допишет файл. После перезапуска то же самое проверяется по файлам
/// (`LipDataFiles.sweep`). Обработка — по одному дублю, фоном: решение,
/// второй проход, фиксация. Весь дисковый I/O — одна последовательная очередь.
@MainActor
final class LipDataStore: ObservableObject {
    static let shared = LipDataStore()

    struct Summary: Equatable {
        var voice = 0
        var whisper = 0
        var pending = 0
        var bytes: Int64 = 0
        var stats = LipStats()
        var loaded = false

        var pairs: Int { voice + whisper }
        var rejected: [(reason: LipRejectReason, count: Int)] {
            LipRejectReason.allCases.compactMap { reason in
                let count = stats.rejected[reason.rawValue] ?? 0
                return count > 0 ? (reason, count) : nil
            }
        }
    }

    @Published private(set) var summary = Summary()

    private let files = LipDataFiles()
    private let ioQueue = DispatchQueue(label: "com.pitenin.doka.lips.io", qos: .utility)
    private var captured: Set<UUID> = []
    private var committed: Set<UUID> = []
    private var queue: [UUID] = []
    private var worker: Task<Void, Never>?
    /// Чей сейчас `worker`: отменённая задача, завершаясь позже, не должна
    /// затереть ссылку на новую.
    private var workerID = UUID()
    private var started = false

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    // MARK: - Жизненный цикл

    /// Уборка и добор дублей, не успевших обработаться до выхода. Фоном и
    /// только если папка уже есть: у тех, кто эксперимент не включал, — ноль работы.
    func start(launch: Date) {
        guard !started else { return }
        started = true
        let files = self.files
        ioQueue.async {
            guard FileManager.default.fileExists(atPath: files.root.path) else { return }
            let resumable = files.sweep(launch: launch)
            Task { @MainActor in
                self.queue.append(contentsOf: resumable)
                self.runNext()
                self.refreshSummary()
            }
        }
    }

    /// Выход: текущее кодирование отменяется (огрызок удалит кодировщик),
    /// сырьё остаётся и доделается после запуска.
    func prepareForTermination() {
        worker?.cancel()
        ioQueue.sync {}
    }

    // MARK: - Два события дубля

    /// Камера дописала сырьё (`raw.mp4` + `capture.json`).
    func captureFinished(_ take: LipTake) {
        captured.insert(take.id)
        enqueueIfReady(take.id)
    }

    /// Диктовка зафиксирована: текст в истории. Вызывается из `settle` ДО
    /// удаления WAV — жёсткая ссылка на него берётся синхронно.
    func commit(_ take: LipTake, caption: LipCaption, audio: RecordedDictation) {
        do {
            try files.linkAudio(audio.url, into: take.id)
        } catch {
            NSLog("DOKA: губы — звук дубля не сохранён: %@", error.localizedDescription)
            LipCapture.shared.discard(take)
            return
        }
        let timing = audio.timing
        let job = LipJob(text: caption.text, language: caption.language, provider: caption.provider,
                         model: caption.model, historyID: caption.historyID, date: Date(),
                         duration: audio.duration, speechSeconds: audio.speechDuration,
                         quietSpeechSeconds: audio.quietSpeechDuration, quiet: audio.quiet,
                         microphone: audio.microphone, hostStart: timing?.hostStart,
                         inputLatency: timing?.inputLatency ?? 0, speechOnset: timing?.speechOnset,
                         maxClockDrift: timing?.maxClockDrift ?? 0)
        let files = self.files
        ioQueue.async {
            do {
                try files.writeJob(job, for: take.id)
            } catch {
                NSLog("DOKA: губы — заказ дубля не записан: %@", error.localizedDescription)
                return
            }
            Task { @MainActor in
                self.committed.insert(take.id)
                self.enqueueIfReady(take.id)
            }
        }
    }

    /// Дубль выброшен — забыть его, если одно из событий уже пришло.
    func forget(_ take: LipTake) {
        captured.remove(take.id)
        committed.remove(take.id)
    }

    private func enqueueIfReady(_ id: UUID) {
        guard captured.contains(id), committed.contains(id) else { return }
        captured.remove(id)
        committed.remove(id)
        queue.append(id)
        summary.pending = queue.count
        runNext()
    }

    // MARK: - Обработка

    private func runNext() {
        summary.pending = queue.count
        guard worker == nil, let id = queue.first else { return }
        let token = UUID()
        workerID = token
        worker = Task { [weak self] in
            await self?.process(id)
            guard let self, self.workerID == token else { return }
            self.worker = nil
            if !Task.isCancelled {
                self.queue.removeAll { $0 == id }
                self.runNext()
            }
            self.refreshSummary()
        }
    }

    private func process(_ id: UUID) async {
        let files = self.files
        let inputs: (LipJob, LipCaptureLog)? = await withCheckedContinuation { continuation in
            ioQueue.async {
                guard let job = files.readJob(id), let log = files.readCaptureLog(id) else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: (job, log))
            }
        }
        guard let (job, log) = inputs else {
            // Сырьё пропало или битое — выбросить, без счётчика: это не решение по паре.
            ioQueue.async { files.reject(id: id) }
            return
        }

        let plan = LipTakePlanner.plan(job: job, log: log)
        // Диагностика каждого дубля — для замера холодной камеры и рассинхрона
        // на живых диктовках (у отброшенных дублей сырьё удаляется).
        let firstFrameDelay = log.frames.first.flatMap { frame in job.timing.map { frame.host - $0.wavHostStart } }
        NSLog("DOKA: губы — дубль %@: %@; кадров %d, %.1f к/с, сброшено %d; первый кадр через %@ с, полезное видео %.2f–%.2f с, речь с %@ с; лицо %.0f%%, дрейф %.3f с",
              id.uuidString, String(describing: plan.verdict), log.frames.count, plan.measuredFps,
              log.droppedFrames, firstFrameDelay.map { String(format: "%.2f", $0) } ?? "?",
              plan.schedule?.validFrom ?? 0, plan.schedule?.validTo ?? 0,
              job.speechOnset.map { String(format: "%.2f", $0) } ?? "?",
              plan.faceCoverage * 100, job.maxClockDrift)
        guard let meta = LipTakePlanner.meta(id: id, job: job, log: log, plan: plan,
                                             appVersion: Self.appVersion),
              let schedule = plan.schedule, let crop = plan.crop else {
            if case .reject(let reason) = plan.verdict { record(id, rejected: reason) }
            return
        }

        let input = LipTakeEncoder.Input(rawVideo: files.rawVideoURL(id), sourcePTS: plan.sourcePTS,
                                         schedule: schedule, crop: crop.rect, audio: files.audioURL(id),
                                         output: await onIO { files.clipPartURL(id) })
        do {
            try await LipTakeEncoder.encode(input)
        } catch is CancellationError {
            return   // выход из приложения: сырьё остаётся до следующего запуска
        } catch {
            NSLog("DOKA: губы — кодирование дубля %@ не удалось: %@", id.uuidString, error.localizedDescription)
            record(id, rejected: .encodeFailed)
            return
        }

        let headMissing: Bool
        if case .keep(let missing) = plan.verdict { headMissing = missing } else { headMissing = false }
        await onIO {
            do {
                if try files.commit(id: id, meta: meta), headMissing {
                    var stats = files.readStats()
                    stats.headMissing += 1
                    files.writeStats(stats)
                }
            } catch {
                NSLog("DOKA: губы — пара %@ не зафиксирована: %@", id.uuidString, error.localizedDescription)
                files.reject(id: id)
            }
        }
        NSLog("DOKA: губы — пара %@ сохранена (%.1f с, лицо %.0f%%)", id.uuidString, job.duration,
              plan.faceCoverage * 100)
    }

    private func record(_ id: UUID, rejected reason: LipRejectReason) {
        NSLog("DOKA: губы — дубль %@ отброшен: %@", id.uuidString, reason.rawValue)
        let files = self.files
        ioQueue.async {
            files.reject(id: id)
            var stats = files.readStats()
            stats.rejected[reason.rawValue, default: 0] += 1
            files.writeStats(stats)
        }
    }

    private func onIO<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            ioQueue.async { continuation.resume(returning: work()) }
        }
    }

    // MARK: - Сводка и удаление

    func refreshSummary() {
        let files = self.files
        ioQueue.async {
            let counts = files.summary()
            let stats = files.readStats()
            Task { @MainActor in
                self.summary.voice = counts.voice
                self.summary.whisper = counts.whisper
                self.summary.bytes = counts.bytes
                self.summary.stats = stats
                self.summary.pending = self.queue.count
                self.summary.loaded = true
            }
        }
    }

    /// Стереть все пары, сырьё и счётчики. Корень `LipData` остаётся.
    func deleteAll() {
        worker?.cancel()
        worker = nil
        workerID = UUID()
        queue.removeAll()
        captured.removeAll()
        committed.removeAll()
        let files = self.files
        ioQueue.async { files.deleteAll() }
        refreshSummary()
    }
}
