import AVFoundation
import XCTest
@testable import DOKA

/// Хранилище пар губ: обработка дублей и «Удалить всё» посреди неё.
///
/// Зачем: worker, уже прочитавший дубль, не должен после «Удалить всё»
/// записать счётчик отбраковки или папку пары — иначе стёртое воскресает
/// («Отброшено — 1» сразу после удаления).
@MainActor
final class LipDataStoreTests: XCTestCase {
    private var root: URL!
    private var files: LipDataFiles!
    private let fm = FileManager.default

    override func setUp() async throws {
        root = fm.temporaryDirectory.appendingPathComponent("doka-lipstore-tests-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        files = LipDataFiles(root: root)
    }

    override func tearDown() async throws {
        try? fm.removeItem(at: root)
    }

    /// Готовое сырьё дубля с пустым текстом — вердикт «Пустой текст».
    private func makeEmptyTextTake() throws -> UUID {
        let id = UUID()
        let folder = files.pendingFolder(id)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("raw".utf8).write(to: folder.appendingPathComponent("raw.mp4"))
        try Data("wav".utf8).write(to: folder.appendingPathComponent("audio.wav"))
        let log = LipCaptureLog(frameWidth: 1280, frameHeight: 720, camera: "Test",
                                frames: [.init(t: 0, host: 100, luma: 100)], faces: [], droppedFrames: 0,
                                failed: false,
                                effects: .init(centerStage: false, portrait: false, studioLight: false,
                                               backgroundReplacement: false, reactions: false))
        try JSONEncoder().encode(log).write(to: folder.appendingPathComponent("capture.json"))
        let job = LipJob(text: "  ", language: "ru", provider: "Test", model: "test", historyID: UUID(),
                         date: Date(), duration: 2, speechSeconds: 1, quietSpeechSeconds: 1, quiet: false,
                         microphone: nil, hostStart: 100, inputLatency: 0, speechOnset: 0.4, maxClockDrift: 0)
        try files.writeJob(job, for: id)
        return id
    }

    /// Дождаться, пока очередь ввода-вывода и главный поток успокоятся.
    private func settle(_ store: LipDataStore) async {
        for _ in 0..<10 {
            try? await Task.sleep(nanoseconds: 30_000_000)
            await withCheckedContinuation { continuation in store.ioQueue.async { continuation.resume() } }
        }
    }

    /// «Удалить всё» доступно, когда есть хоть что-то: остались только
    /// счётчики отбраковки или байты сырья — их тоже должно быть можно стереть.
    func testSummaryHasDataCountsCountersAndBytes() {
        var summary = LipDataStore.Summary()
        XCTAssertFalse(summary.hasData)
        summary.stats.rejected["noFace"] = 2
        XCTAssertTrue(summary.hasData)
        summary = LipDataStore.Summary()
        summary.bytes = 4096
        XCTAssertTrue(summary.hasData)
        summary = LipDataStore.Summary()
        summary.stats.headMissing = 1
        XCTAssertTrue(summary.hasData)
    }

    /// Контроль: без удаления дубль с пустым текстом отбрасывается и считается.
    func testEmptyTextTakeIsCountedAsRejected() async throws {
        let store = LipDataStore(files: files)
        store.enqueueForProcessing(try makeEmptyTextTake())
        await settle(store)
        XCTAssertEqual(files.readStats().rejected["emptyText"], 1)
    }

    /// Исход обработки публикуется — по нему окно «Тренировка» показывает
    /// судьбу прошлой фразы и возвращает отброшенную в очередь.
    func testOutcomesArePublished() async throws {
        let store = LipDataStore(files: files)
        var received: [LipTakeOutcome] = []
        let subscription = store.outcomes.sink { received.append($0) }
        defer { subscription.cancel() }

        let rejected = try makeEmptyTextTake()
        store.enqueueForProcessing(rejected)
        await settle(store)
        // Сырья нет вовсе — не решение по паре, а потерянные данные.
        let lost = UUID()
        store.enqueueForProcessing(lost)
        await settle(store)

        XCTAssertEqual(received, [.rejected(rejected, .emptyText), .rejected(lost, nil)])
        XCTAssertEqual(received.map(\.id), [rejected, lost])
    }

    /// «Удалить всё», пока worker ждёт чтения дубля: после удаления счётчик
    /// отбраковки не воскресает.
    func testDeleteAllDuringProcessingLeavesNothingBehind() async throws {
        let store = LipDataStore(files: files)
        let id = try makeEmptyTextTake()
        // Придерживаем очередь: чтение дубля встанет за этим блоком.
        let gate = DispatchSemaphore(value: 0)
        store.ioQueue.async { gate.wait() }
        store.enqueueForProcessing(id)
        for _ in 0..<5 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 50_000_000)
        store.deleteAll()
        gate.signal()
        await settle(store)
        XCTAssertEqual(files.readStats(), LipStats())
        XCTAssertFalse(fm.fileExists(atPath: files.takeFolder(id).path))
    }

    // MARK: - Сквозной путь на синтетическом дубле

    /// Дубль, каким его оставили бы камера и запись: сырьё 1280×720 с лицом
    /// 300 px (камера проснулась через 0,3 с после звука), журнал и WAV 3 с во
    /// временной папке записи.
    private func makeCapturedTake(speechOnset: Double?) throws -> (LipTake, RecordedDictation) {
        let take = LipTake(id: UUID(), pendingRoot: files.pendingRoot)
        try fm.createDirectory(at: take.folder, withIntermediateDirectories: true)
        let log = LipSyntheticTake.log()
        try LipSyntheticTake.writeRawVideo(to: take.rawVideoURL, times: log.frames.map(\.t))
        try JSONEncoder().encode(log).write(to: take.captureLogURL)
        let wav = root.appendingPathComponent("doka-\(take.id.uuidString).wav")
        try LipSyntheticTake.writeWav(to: wav, seconds: 3)
        let timing = RecordingTiming(hostStart: LipSyntheticTake.hostStart, inputLatency: 0,
                                     speechOnset: speechOnset, maxClockDrift: 0.001)
        let audio = RecordedDictation(url: wav, duration: 3, speechDuration: 0.1, microphone: "Mic",
                                      quiet: false, quietSpeechDuration: 0.2, timing: timing, lipTake: take)
        return (take, audio)
    }

    /// Ждать исходов, пока их не наберётся `count` (обработка с кодированием — секунды).
    private func waitForOutcomes(_ received: () -> [LipTakeOutcome], count: Int) async {
        let deadline = Date().addingTimeInterval(30)
        while received().count < count, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    private func readMeta(_ id: UUID) throws -> LipTakeMeta {
        let url = files.takeFolder(id).appendingPathComponent(LipDataLayout.meta)
        return try LipTakeMeta.decoder.decode(LipTakeMeta.self, from: Data(contentsOf: url))
    }

    /// Фраза окна «Тренировка» проходит весь путь, как в приложении: заказ
    /// (`commit`, исходный WAV удаляется сразу) → камера дописала сырьё →
    /// обработка → клип 512×512 со звуком и `meta.json` пары тренировки.
    /// Окно узнаёт об этом исходом `.saved`, и фраза больше не предлагается.
    func testTrainingTakeBecomesSilentTrainingPair() async throws {
        let store = LipDataStore(files: files, discardTake: { _ in XCTFail("дубль не должен выбрасываться") })
        var received: [LipTakeOutcome] = []
        let subscription = store.outcomes.sink { received.append($0) }
        defer { subscription.cancel() }

        let (take, audio) = try makeCapturedTake(speechOnset: 0.86)
        let phrase = "Купи хлеба по дороге домой"
        store.commit(take, caption: .training(phrase: phrase, origin: LipTrainingPhrase.Origin.everyday.rawValue),
                     audio: audio)
        try fm.removeItem(at: audio.url)   // контроллер удаляет исходник сразу после commit
        store.captureFinished(take)
        await waitForOutcomes({ received }, count: 1)

        XCTAssertEqual(received, [.saved(take.id)])
        let meta = try readMeta(take.id)
        XCTAssertEqual(meta.source, LipSource.training.rawValue)
        XCTAssertEqual(meta.mode, .silent)
        XCTAssertEqual(meta.text, phrase)
        XCTAssertEqual(meta.provider, LipCaption.trainingProvider)
        XCTAssertEqual(meta.model, "everyday")
        XCTAssertNil(meta.historyID)
        XCTAssertEqual(meta.speechOnset, 0.86)
        XCTAssertFalse(meta.quiet)
        XCTAssertEqual(meta.video.width, 512)
        XCTAssertEqual(meta.video.faceCoverage, 1)
        XCTAssertEqual(meta.video.faceGaps, [])

        // Клип — то, что ест WISLIP: видео 512×512 и звуковая дорожка.
        let clip = AVURLAsset(url: files.takeFolder(take.id).appendingPathComponent(LipDataLayout.clip))
        let video = try await clip.loadTracks(withMediaType: .video)
        XCTAssertEqual(video.count, 1)
        let size = try await video[0].load(.naturalSize)
        XCTAssertEqual(size, CGSize(width: 512, height: 512))
        let sound = try await clip.loadTracks(withMediaType: .audio)
        XCTAssertEqual(sound.count, 1)

        XCTAssertFalse(fm.fileExists(atPath: take.folder.path), "сырьё убрано")
        XCTAssertEqual(files.trainingTexts(), [phrase])
        XCTAssertEqual(files.summary().silent, 1)
        XCTAssertEqual(files.summary().voice, 0)
    }

    /// Диктовка — тот же путь в другом порядке событий (камера дописала
    /// раньше, чем распознавание): пара голосом с записью истории, а заказ —
    /// без ключей тренировки, как у прошлой версии.
    func testDictationTakeBecomesVoicePair() async throws {
        let store = LipDataStore(files: files, discardTake: { _ in XCTFail("дубль не должен выбрасываться") })
        var received: [LipTakeOutcome] = []
        let subscription = store.outcomes.sink { received.append($0) }
        defer { subscription.cancel() }

        let (take, audio) = try makeCapturedTake(speechOnset: 0.4)
        let historyID = UUID()
        store.captureFinished(take)
        store.commit(take, caption: LipCaption(text: "привет, это проверка", language: "ru", provider: "Nexara",
                                               model: "whisper-1", historyID: historyID),
                     audio: audio)
        // Заказ — следующим блоком очереди после записи: обработка прочтёт его
        // позже и удалит только вместе с сырьём.
        let jobURL = files.pendingFolder(take.id).appendingPathComponent(LipDataLayout.job)
        let job = await withCheckedContinuation { continuation in
            store.ioQueue.async {
                continuation.resume(returning: (try? String(contentsOf: jobURL, encoding: .utf8)) ?? "")
            }
        }
        XCTAssertTrue(job.contains("привет"), job)
        XCTAssertFalse(job.contains("\"source\""), job)
        XCTAssertFalse(job.contains("\"mode\""), job)
        try fm.removeItem(at: audio.url)
        await waitForOutcomes({ received }, count: 1)

        XCTAssertEqual(received, [.saved(take.id)])
        let meta = try readMeta(take.id)
        XCTAssertEqual(meta.source, LipSource.dictation.rawValue)
        XCTAssertEqual(meta.mode, .voice)
        XCTAssertEqual(meta.historyID, historyID)
        XCTAssertEqual(meta.speechOnset, 0.4)
        XCTAssertEqual(files.summary().voice, 1)
        XCTAssertEqual(files.trainingTexts(), [])
    }

    /// Звук дубля не удалось сохранить (WAV уже нет) — пары не будет: дубль
    /// выбрасывается, а исход «данные потеряны» уходит сразу. Без исхода
    /// фраза тренировки навсегда осталась бы «в обработке».
    func testFailedCommitPublishesLostOutcome() throws {
        var discarded: [LipTake] = []
        let store = LipDataStore(files: files, discardTake: { discarded.append($0) })
        var received: [LipTakeOutcome] = []
        let subscription = store.outcomes.sink { received.append($0) }
        defer { subscription.cancel() }

        let (take, audio) = try makeCapturedTake(speechOnset: 0.86)
        try fm.removeItem(at: audio.url)
        store.commit(take, caption: .training(phrase: "Фраза без звука", origin: "work"), audio: audio)

        XCTAssertEqual(discarded, [take])
        XCTAssertEqual(received, [.rejected(take.id, nil)])
    }
}
