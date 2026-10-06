import Foundation
import FluidAudio

/// Интервал речи одного говорящего. `speaker` уже приведён к формату Nexara
/// (`speaker_0`, `speaker_1`, …) — весь показ и экспорт спикеров в проекте
/// разбирает именно его (`SpeakerName`, `TranscriptFormatter.bySpeaker`).
struct SpeakerSpan: Equatable {
    let speaker: String
    let start: Double
    let end: Double
}

/// Локальное разделение по спикерам — две модели FluidAudio, обе «кто когда
/// говорил» без распознавания текста, поэтому годятся и для локальных
/// движков, и для текста пользовательского сетевого сервиса:
/// - «Авто» — Nemotron 3 Diarization (NVIDIA, ~195 МБ, OpenMDW-1.1).
///   Замер 6.10.2026 на 85-минутной записи с тремя голосами: качество
///   на уровне pyannote (те же три спикера, 95 % слов совпадают), но в
///   1,4–2,1 раза быстрее, процессору в 2–2,7 раза меньше работы, а память
///   почти не растёт с длиной записи — звук подаётся кусками (`appendAudio`),
///   результат кадр в кадр как у `processComplete`. Подсказки «ровно N
///   человек» у него нет, слотов — 8.
/// - Заданное число спикеров — офлайновый pyannote (VBx: сегментация +
///   WeSpeaker + кластеризация, ~22 МБ): его подсказка настоящая
///   (`withSpeakers(exactly:)`), и пользовательские «1–10» работают как раньше.
///
/// Импорт FluidAudio намеренно ограничен файлами движков в `Local/`.
@MainActor
final class LocalDiarizer {
    /// Модели pyannote; менеджер создаётся на каждый прогон, потому что
    /// подсказка о числе спикеров живёт в его конфиге, а не в вызове.
    private var models: OfflineDiarizerModels?
    private var nemotron: NemotronModels?

    var isLoaded: Bool { models != nil && nemotron != nil }

    func load() async throws {
        if models == nil {
            models = try await OfflineDiarizerModels.load(from: LocalModelStore.diarizerFolder)
        }
        if nemotron == nil {
            // Файлы уже на месте (`LocalModelStore.isOnDisk` сверяет и маркер
            // версии весов) — `loadFromHuggingFace` только загружает, без сети.
            nemotron = NemotronModels(try await Nemotron3Models.loadFromHuggingFace(
                config: .offline, cacheDirectory: LocalModelStore.diarizerFolder))
        }
    }

    /// Разбор WAV 16 кГц mono (то, что отдаёт `AudioFileDecoder`) на интервалы
    /// говорящих. `numSpeakers` — подсказка «ровно столько человек»: она не
    /// выдумывает спикеров там, где их не слышно, но не даёт разбить одного
    /// на нескольких (проверено стендом). Без подсказки — Nemotron.
    func diarize(wavURL: URL,
                 numSpeakers: Int?,
                 progress: @escaping @MainActor (Double) -> Void) async throws -> [SpeakerSpan] {
        let sink = ProgressSink(report: progress)
        guard let numSpeakers else {
            guard let nemotron else { throw LocalEngineError.modelMissing }
            let worker = Task.detached(priority: .userInitiated) {
                try Self.nemotronLabels(wavURL: wavURL, models: nemotron, progress: sink)
            }
            let labels = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: {
                worker.cancel()
            }
            try Task.checkCancellation()
            return SpeakerFrames.spans(labels: labels)
        }
        guard let models else { throw LocalEngineError.modelMissing }

        let config = OfflineDiarizerConfig.default.withSpeakers(exactly: numSpeakers)
        let manager = OfflineDiarizerManager(config: config)
        manager.initialize(models: models)

        let result = try await manager.process(wavURL) { done, total in
            sink.report(done: done, total: total)
        }
        try Task.checkCancellation()
        return SpeakerFrames.remapByFirstAppearance(result.segments.map {
            ($0.speakerId, Double($0.startTimeSeconds), Double($0.endTimeSeconds))
        })
    }

    func unload() {
        models = nil
        nemotron = nil
    }

    // MARK: - Nemotron

    /// Модели Nemotron держат `MLModel` и не помечены `Sendable`; в отвязанную
    /// задачу уходят только целиком, а работает с ними один прогон за раз.
    private struct NemotronModels: @unchecked Sendable {
        let models: Nemotron3Models
        init(_ models: Nemotron3Models) { self.models = models }
    }

    /// Кусок, который читается и отдаётся модели за раз: 30 с звука — 960 КБ.
    private nonisolated static let chunkBytes = WavWriter.bytesPerSecond * 30

    /// Говорящий каждого кадра (10 мс) по всему файлу. Звук идёт кусками и
    /// дальше не хранится; от вероятностей остаётся байт на кадр
    /// (`SpeakerFrames.labels`) — 360 КБ на час записи. Отмена — между кусками.
    private nonisolated static func nemotronLabels(wavURL: URL, models: NemotronModels,
                                                   progress: ProgressSink) throws -> [Int8] {
        let diarizer = Nemotron3Diarizer(config: .offline, models: models.models)
        let handle = try FileHandle(forReadingFrom: wavURL)
        defer { try? handle.close() }
        let headerBytes = WavWriter.header(dataSize: 0).count
        let total = max(Int(try handle.seekToEnd()) - headerBytes, 1)
        try handle.seek(toOffset: UInt64(headerBytes))

        var labels: [Int8] = []
        func collect(_ results: [Nemotron3ChunkResult]) {
            for result in results {
                labels += SpeakerFrames.labels(probabilities: result.probabilities,
                                               numSpeakers: result.numSpeakers)
            }
        }
        var done = 0
        while let data = try handle.read(upToCount: chunkBytes), !data.isEmpty {
            try Task.checkCancellation()
            diarizer.appendAudio(samples(data))
            collect(try diarizer.processBufferedAudio())
            done += data.count
            progress.report(done: done, total: total)
        }
        try Task.checkCancellation()
        collect(try diarizer.finishStream())
        return labels
    }

    /// PCM Int16 little-endian (тело WAV `WavWriter`) → Float в [-1, 1).
    private nonisolated static func samples(_ data: Data) -> [Float] {
        data.withUnsafeBytes { raw in
            raw.bindMemory(to: Int16.self).map { Float(Int16(littleEndian: $0)) / 32_768 }
        }
    }

    /// Колбэк прогресса приходит с произвольного потока и обязан быть
    /// `@Sendable`; квантуем до целых процентов, как у скачивания моделей,
    /// и прыгаем на главный актёр.
    private final class ProgressSink: @unchecked Sendable {
        private let lock = NSLock()
        private var lastPercent = -1
        private let report: @MainActor (Double) -> Void

        init(report: @escaping @MainActor (Double) -> Void) {
            self.report = report
        }

        func report(done: Int, total: Int) {
            guard total > 0 else { return }
            let fraction = min(max(Double(done) / Double(total), 0), 1)
            let percent = Int(fraction * 100)
            lock.lock()
            let changed = percent > lastPercent
            if changed { lastPercent = percent }
            lock.unlock()
            guard changed else { return }
            Task { @MainActor [report] in report(fraction) }
        }
    }
}
