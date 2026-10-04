import CoreMedia
import CoreVideo
import XCTest
@testable import DOKA

/// Vision в движке камеры против финализации и выброса дубля.
///
/// Зачем: лицо ищется на своей очереди и может быть в работе, когда дубль
/// заканчивают или выбрасывают. Запись лица по последнему кадру обязана
/// попасть в журнал ДО финализации (иначе хвост дубля останется «без лица»),
/// выброшенный дубль не получает ни строчки, а флаг занятости Vision
/// снимается и при ошибке — иначе лицо не искалось бы до конца дубля. И хотя
/// Vision идёт на каждом кадре, журнал лица остаётся на прежних ~15 Гц.
/// Камера и Vision не нужны: кадры синтетические, детектор подставной.
final class LipCameraEngineVisionTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("doka-lip-vision-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    /// Лицо, которое «находит» подставной детектор.
    private static let face = LipFaceSample(box: CGRect(x: 100, y: 40, width: 80, height: 96), count: 1,
                                            outerLips: [], innerLips: [])
    private static let faceBox: [Double] = [100, 40, 80, 96]

    /// Держит Vision «в работе», пока тест не отпустит.
    private final class HeldDetector: LipFaceDetecting, @unchecked Sendable {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)

        func detect(in pixelBuffer: CVPixelBuffer) throws -> LipFaceSample {
            entered.signal()
            // Страховка: упавший тест не вешает очередь Vision навсегда.
            _ = release.wait(timeout: .now() + 5)
            return LipCameraEngineVisionTests.face
        }
    }

    /// Первый кадр — ошибка Vision, дальше — лицо.
    private final class FailingOnceDetector: LipFaceDetecting, @unchecked Sendable {
        private struct VisionFailure: Error {}
        private let lock = NSLock()
        private var count = 0
        var calls: Int { lock.withLock { count } }

        func detect(in pixelBuffer: CVPixelBuffer) throws -> LipFaceSample {
            let call = lock.withLock {
                count += 1
                return count
            }
            if call == 1 { throw VisionFailure() }
            return LipCameraEngineVisionTests.face
        }
    }

    /// Отвечает сразу и считает вызовы.
    private final class CountingDetector: LipFaceDetecting, @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var calls: Int { lock.withLock { count } }

        func detect(in pixelBuffer: CVPixelBuffer) throws -> LipFaceSample {
            lock.withLock { count += 1 }
            return LipCameraEngineVisionTests.face
        }
    }

    private final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func add(_ item: String) { lock.lock(); items.append(item); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
    }

    private func makeEngine(_ detector: any LipFaceDetecting, _ events: Events) -> LipCameraEngine {
        let engine = LipCameraEngine(detector: detector)
        engine.onTakeCaptured = { _ in events.add("captured") }
        engine.onTakeDiscarded = { _ in events.add("discarded") }
        return engine
    }

    private func begin(_ engine: LipCameraEngine) throws -> LipTake {
        let take = LipTake(id: UUID(), pendingRoot: root)
        try FileManager.default.createDirectory(at: take.folder, withIntermediateDirectories: true)
        engine.begin(LipTakeRecorder(take: take, acceptFromHost: 0, queue: engine.videoQueue))
        return take
    }

    /// Кадр 320×180 в родном формате камеры (420v) с меткой `host`.
    private func makeFrame(host: Double) throws -> CMSampleBuffer {
        var pixel: CVPixelBuffer?
        CVPixelBufferCreate(nil, 320, 180, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &pixel)
        let buffer = try XCTUnwrap(pixel)
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer,
                                                     formatDescriptionOut: &format)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
                                        presentationTimeStamp: CMTime(seconds: host, preferredTimescale: 90_000),
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: buffer,
                                                 formatDescription: try XCTUnwrap(format),
                                                 sampleTiming: &timing, sampleBufferOut: &sample)
        return try XCTUnwrap(sample)
    }

    /// Подать кадр так, как его подаёт камера, — на видео-очереди.
    private func feed(_ engine: LipCameraEngine, host: Double) throws {
        let frame = try makeFrame(host: host)
        engine.videoQueue.async { engine.handleFrame(frame, host: host) }
    }

    private func journal(_ take: LipTake) throws -> LipCaptureLog {
        try JSONDecoder().decode(LipCaptureLog.self, from: Data(contentsOf: take.captureLogURL))
    }

    private func waitUntil(_ condition: @escaping () -> Bool) {
        let deadline = Date().addingTimeInterval(3)
        while !condition() && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
    }

    /// Дубль закончили, пока Vision искал лицо в последнем кадре: запись лица
    /// всё равно попадает в журнал — финализация встаёт в очередь за Vision.
    func testFaceEntryLandsBeforeFinishWhenEndDuringVision() throws {
        let detector = HeldDetector()
        let events = Events()
        let engine = makeEngine(detector, events)
        let take = try begin(engine)
        try feed(engine, host: 1)
        XCTAssertEqual(detector.entered.wait(timeout: .now() + 3), .success)

        engine.end()
        engine.videoQueue.sync {}   // блок `end()` прошёл: финализация ждёт Vision
        detector.release.signal()
        waitUntil { events.all == ["captured"] }

        XCTAssertEqual(events.all, ["captured"])
        let log = try journal(take)
        XCTAssertEqual(log.faces.map(\.host), [1])
        XCTAssertEqual(log.faces.first?.box, Self.faceBox)
    }

    /// Дубль выбросили (Esc), пока Vision искал лицо: запоздавший результат
    /// ничего не пишет — ни журнала, ни папки, ни событий.
    func testDiscardDuringVisionWritesNothing() throws {
        let detector = HeldDetector()
        let events = Events()
        let engine = makeEngine(detector, events)
        let take = try begin(engine)
        try feed(engine, host: 1)
        XCTAssertEqual(detector.entered.wait(timeout: .now() + 3), .success)

        engine.discard(take)
        engine.videoQueue.sync {}   // дубль выброшен раньше, чем Vision вернулся
        detector.release.signal()
        engine.end()
        Thread.sleep(forTimeInterval: 0.3)
        engine.videoQueue.sync {}

        XCTAssertEqual(events.all, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: take.folder.path))
    }

    /// 30 к/с и Vision свободен на каждом кадре: он смотрит ВСЕ кадры, а в
    /// журнал лица идёт каждый второй — ~15 Гц, как до перехода на Vision на
    /// каждом кадре. Частота журнала — договор с WISLIP (и `multiFaceFrames`
    /// в `meta.json` считается по его строкам): движок без `cadence.admit`
    /// удвоил бы её, а тесты самой `LipJournalCadence` этого не заметили бы.
    func testVisionOnEveryFrameJournalOnEveryOther() throws {
        let detector = CountingDetector()
        let events = Events()
        let engine = makeEngine(detector, events)
        let take = try begin(engine)

        let hosts = (0..<10).map { 1 + Double($0) / 30 }
        for host in hosts {
            try feed(engine, host: host)
            engine.videoQueue.sync {}    // кадр отдан Vision
            engine.visionQueue.sync {}   // Vision закончил и снял флаг занятости
        }
        engine.end()
        waitUntil { events.all == ["captured"] }

        XCTAssertEqual(events.all, ["captured"])
        XCTAssertEqual(detector.calls, hosts.count)
        let journalHosts = try journal(take).faces.map(\.host)
        let expected = stride(from: 0, to: hosts.count, by: 2).map { hosts[$0] }
        XCTAssertEqual(journalHosts.count, expected.count, "журнал: \(journalHosts)")
        for (got, want) in zip(journalHosts, expected) {
            XCTAssertEqual(got, want, accuracy: 1e-9)
        }
    }

    /// Vision упал на кадре — флаг занятости всё равно снят: следующие кадры
    /// снова идут в Vision, а кадр с ошибкой в журнале — «лица нет», как раньше.
    func testGateReleasedWhenVisionFails() throws {
        let detector = FailingOnceDetector()
        let events = Events()
        let engine = makeEngine(detector, events)
        let take = try begin(engine)

        // Кадры через 0,1 с — каждый взятый Vision результат идёт в журнал.
        var host = 1.0
        let deadline = Date().addingTimeInterval(3)
        while detector.calls < 2 && Date() < deadline {
            try feed(engine, host: host)
            host += 0.1
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTAssertGreaterThanOrEqual(detector.calls, 2)

        engine.end()
        waitUntil { events.all == ["captured"] }
        let log = try journal(take)
        XCTAssertGreaterThanOrEqual(log.faces.count, 2)
        XCTAssertNil(log.faces.first?.box)
        XCTAssertEqual(log.faces.last?.box, Self.faceBox)
    }
}
