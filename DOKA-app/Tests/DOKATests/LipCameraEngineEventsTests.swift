import XCTest
@testable import DOKA

/// События дубля камеры для хранилища пар: «записан» и «выброшен».
///
/// Зачем: хранилище помнит дубли, о которых пришло одно из двух событий.
/// Если «выброшен» придёт раньше «записан» (или «записан» придёт без пары),
/// id останется в памяти навсегда — меню-бар-приложение живёт неделями.
/// Инвариант: «выброшен» шлётся ровно тем дублям, о которых уже сообщили
/// «записан», и из той же последовательной очереди — то есть строго после.
/// Камера здесь не нужна: дубль без кадров тоже дописывается (как сбойный).
final class LipCameraEngineEventsTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("doka-lip-engine-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func add(_ item: String) { lock.lock(); items.append(item); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
    }

    private func makeEngine(_ events: Events) -> LipCameraEngine {
        let engine = LipCameraEngine()
        engine.onTakeCaptured = { _ in events.add("captured") }
        engine.onTakeDiscarded = { _ in events.add("discarded") }
        return engine
    }

    private func makeTake() throws -> LipTake {
        let take = LipTake(id: UUID(), pendingRoot: root)
        try FileManager.default.createDirectory(at: take.folder, withIntermediateDirectories: true)
        return take
    }

    private func waitUntil(_ condition: @escaping () -> Bool) {
        let deadline = Date().addingTimeInterval(3)
        while !condition() && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
    }

    /// Дописали, потом выбросили (ошибка распознавания): «записан», затем «выброшен».
    func testDiscardAfterCaptureEmitsBothInOrder() throws {
        let events = Events()
        let engine = makeEngine(events)
        let take = try makeTake()
        engine.begin(LipTakeRecorder(take: take, acceptFromHost: 0, queue: engine.videoQueue))
        engine.end()
        waitUntil { events.all == ["captured"] }
        engine.discard(take)
        waitUntil { events.all.count == 2 }
        XCTAssertEqual(events.all, ["captured", "discarded"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: take.folder.path))
    }

    /// Выбросили до того, как дописали (Esc посреди записи): ни одного события —
    /// хранилище об этом дубле не узнало и забывать ему нечего.
    func testDiscardBeforeCaptureEmitsNothing() throws {
        let events = Events()
        let engine = makeEngine(events)
        let take = try makeTake()
        engine.begin(LipTakeRecorder(take: take, acceptFromHost: 0, queue: engine.videoQueue))
        engine.discard(take)
        engine.end()
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(events.all, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: take.folder.path))
    }
}
