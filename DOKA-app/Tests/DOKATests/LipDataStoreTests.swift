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

    /// Контроль: без удаления дубль с пустым текстом отбрасывается и считается.
    func testEmptyTextTakeIsCountedAsRejected() async throws {
        let store = LipDataStore(files: files)
        store.enqueueForProcessing(try makeEmptyTextTake())
        await settle(store)
        XCTAssertEqual(files.readStats().rejected["emptyText"], 1)
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
}
