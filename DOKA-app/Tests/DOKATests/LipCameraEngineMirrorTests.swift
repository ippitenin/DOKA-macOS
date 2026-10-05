import CoreGraphics
import CoreMedia
import CoreVideo
import QuartzCore
import XCTest
@testable import DOKA

/// Зеркало в движке камеры: картинка и маска одного кадра.
///
/// Зачем: видео в зеркале и маска обязаны меняться одновременно — значит,
/// рендер и Vision смотрят на ОДИН И ТОТ ЖЕ буфер камеры, маска кадра идёт
/// через тот же регион, что и его картинка, а кадр, который показывает вью,
/// несёт картинку именно этого буфера. Рендер идёт параллельно с Vision:
/// буфер камеры держится max(Vision, рендер), а не сумму. Без окна зеркала
/// рендер не нужен вовсе (Core Image на каждом кадре впустую), журнал лица
/// для WISLIP от зеркала не меняется (~15 Гц), а неудачный рендер не держит
/// флаг занятости Vision, не сбивает журнал и не показывает маску поверх
/// чёрного. Камера, Vision и Core Image не нужны: детектор и рендерер подставные.
final class LipCameraEngineMirrorTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("doka-lip-mirror-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private let target = LipMirrorTarget(size: CGSize(width: 224, height: 120), scale: 2, reduceMotion: false)
    private let camera = CGSize(width: 1280, height: 720)

    /// Запоминает буферы, в которых искал лицо, и отдаёт `sample` на каждый.
    /// `onDetect` — крючок внутри поиска (для проверки параллельности).
    private final class RecordingDetector: LipFaceDetecting, @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [CVPixelBuffer] = []
        private let sample: LipFaceSample
        var onDetect: (() -> Void)?
        var buffers: [CVPixelBuffer] { lock.withLock { seen } }

        init(sample: LipFaceSample = LipFaceSample(box: CGRect(x: 100, y: 40, width: 80, height: 96), count: 1,
                                                   outerLips: [], innerLips: [])) {
            self.sample = sample
        }

        func detect(in pixelBuffer: CVPixelBuffer) throws -> LipFaceSample {
            lock.withLock { seen.append(pixelBuffer) }
            onDetect?()
            return sample
        }
    }

    /// Запоминает буферы, регионы и размеры рендера; отдаёт свою картинку на
    /// каждый буфер (или ничего — «рендер не удался»). Считает прогревы.
    private final class RecordingRenderer: LipMirrorRendering, @unchecked Sendable {
        struct Call {
            let buffer: CVPixelBuffer
            let image: CGImage?
            let region: CGRect
            let size: CGSize
            let mirrored: Bool
        }
        private let lock = NSLock()
        private var made: [Call] = []
        private var warmed = 0
        private let fails: Bool
        var onRender: (() -> Void)?
        var calls: [Call] { lock.withLock { made } }
        var prewarms: Int { lock.withLock { warmed } }

        init(fails: Bool = false) { self.fails = fails }

        func render(_ pixelBuffer: CVPixelBuffer, region: CGRect, size: CGSize, mirrored: Bool) -> CGImage? {
            onRender?()
            let image = fails ? nil : Self.makeImage()
            lock.withLock {
                made.append(Call(buffer: pixelBuffer, image: image, region: region, size: size, mirrored: mirrored))
            }
            return image
        }

        func prewarm() {
            lock.withLock { warmed += 1 }
        }

        private static func makeImage() -> CGImage? {
            CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)?.makeImage()
        }
    }

    private final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func add(_ item: String) { lock.lock(); items.append(item); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
    }

    private func makeEngine(_ detector: RecordingDetector, _ renderer: RecordingRenderer,
                            _ events: Events) -> LipCameraEngine {
        let engine = LipCameraEngine(detector: detector, renderer: renderer)
        engine.onTakeCaptured = { _ in events.add("captured") }
        engine.onTakeDiscarded = { _ in events.add("discarded") }
        return engine
    }

    @MainActor
    private func begin(_ engine: LipCameraEngine) throws -> LipTake {
        let take = LipTake(id: UUID(), pendingRoot: root)
        try FileManager.default.createDirectory(at: take.folder, withIntermediateDirectories: true)
        engine.begin(LipTakeRecorder(take: take, acceptFromHost: 0, queue: engine.videoQueue))
        engine.mirrorFeed.begin(take: take.id)
        return take
    }

    /// Кадр 1280×720 в родном формате камеры (420v) с меткой `host` —
    /// координаты синтетического лица заданы в пикселях такого кадра.
    private func makeFrame(host: Double) throws -> CMSampleBuffer {
        var pixel: CVPixelBuffer?
        CVPixelBufferCreate(nil, Int(camera.width), Int(camera.height), kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                            nil, &pixel)
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

    /// 30 к/с, и каждый кадр застаёт Vision свободным: кадр отдан на
    /// видео-очереди, затем Vision и рендер закончили и сняли флаг занятости.
    private func feedFrames(_ engine: LipCameraEngine, count: Int) throws -> [Double] {
        let hosts = (0..<count).map { 1 + Double($0) / 30 }
        for host in hosts {
            let frame = try makeFrame(host: host)
            engine.videoQueue.async { engine.handleFrame(frame, host: host) }
            engine.videoQueue.sync {}
            engine.visionQueue.sync {}
        }
        return hosts
    }

    /// Прокрутить главную очередь: кадры, отправленные ящиком, доставлены.
    @MainActor
    private func flushMain() {
        let done = expectation(description: "главная очередь")
        DispatchQueue.main.async { done.fulfill() }
        wait(for: [done], timeout: 2)
    }

    private func finish(_ engine: LipCameraEngine, _ events: Events) {
        engine.end()
        let deadline = Date().addingTimeInterval(3)
        while events.all != ["captured"] && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertEqual(events.all, ["captured"])
    }

    private func journal(_ take: LipTake) throws -> LipCaptureLog {
        try JSONDecoder().decode(LipCaptureLog.self, from: Data(contentsOf: take.captureLogURL))
    }

    /// Рендер и Vision получают на каждом кадре один и тот же буфер, а вью
    /// показывает картинку последнего — того же кадра, что и его маска.
    @MainActor
    func testMirrorRendersTheSameBufferVisionSaw() throws {
        let detector = RecordingDetector(), renderer = RecordingRenderer(), events = Events()
        let engine = makeEngine(detector, renderer, events)
        var shown: [LipMirrorFrame?] = []
        let owner = engine.mirrorFeed.attach(target: target) { shown.append($0) }
        defer { engine.mirrorFeed.detach(owner: owner) }
        _ = try begin(engine)

        let hosts = try feedFrames(engine, count: 6)
        flushMain()

        let rendered = renderer.calls, seen = detector.buffers
        XCTAssertEqual(rendered.count, hosts.count)
        XCTAssertEqual(seen.count, hosts.count)
        for (call, buffer) in zip(rendered, seen) {
            XCTAssertTrue(call.buffer === buffer)
            XCTAssertEqual(call.size, target.pixelSize)
            XCTAssertTrue(call.mirrored)
        }
        let last = try XCTUnwrap(shown.last ?? nil)
        XCTAssertEqual(last.host, try XCTUnwrap(hosts.last), accuracy: 1e-9)
        XCTAssertTrue(last.image === rendered.last?.image)
        finish(engine, events)
    }

    /// Окна зеркала нет — рендер не зовётся ни разу, Vision работает как раньше.
    @MainActor
    func testNoRenderWithoutMirrorTarget() throws {
        let detector = RecordingDetector(), renderer = RecordingRenderer(), events = Events()
        let engine = makeEngine(detector, renderer, events)
        _ = try begin(engine)

        let hosts = try feedFrames(engine, count: 6)

        XCTAssertEqual(renderer.calls.count, 0)
        XCTAssertEqual(detector.buffers.count, hosts.count)
        finish(engine, events)
    }

    /// С зеркалом журнал лица прежний: Vision и рендер на каждом кадре, в
    /// журнал — каждый второй (~15 Гц, договор с WISLIP).
    @MainActor
    func testJournalUnchangedWithMirror() throws {
        let detector = RecordingDetector(), renderer = RecordingRenderer(), events = Events()
        let engine = makeEngine(detector, renderer, events)
        let owner = engine.mirrorFeed.attach(target: target) { _ in }
        defer { engine.mirrorFeed.detach(owner: owner) }
        let take = try begin(engine)

        let hosts = try feedFrames(engine, count: 10)
        finish(engine, events)

        XCTAssertEqual(renderer.calls.count, hosts.count)
        XCTAssertEqual(detector.buffers.count, hosts.count)
        let journalHosts = try journal(take).faces.map(\.host)
        let expected = stride(from: 0, to: hosts.count, by: 2).map { hosts[$0] }
        XCTAssertEqual(journalHosts.count, expected.count, "журнал: \(journalHosts)")
        for (got, want) in zip(journalHosts, expected) {
            XCTAssertEqual(got, want, accuracy: 1e-9)
        }
    }

    /// Маска каждого кадра — через тот же регион, через который рендерилась
    /// его картинка: сверка с эталонным конвейером на тех же кадрах.
    @MainActor
    func testMaskUsesRegionOfItsPicture() throws {
        let sample = LipSyntheticFace.sample(mouth: CGPoint(x: 800, y: 450))
        let detector = RecordingDetector(sample: sample), renderer = RecordingRenderer(), events = Events()
        let engine = makeEngine(detector, renderer, events)
        var shown: [LipMirrorFrame?] = []
        let owner = engine.mirrorFeed.attach(target: target) { shown.append($0) }
        defer { engine.mirrorFeed.detach(owner: owner) }
        let take = try begin(engine)

        let hosts = try feedFrames(engine, count: 20)
        flushMain()

        let calls = renderer.calls
        XCTAssertEqual(calls.count, hosts.count)
        let reference = LipMirrorPipeline()
        var expected: LipMeshPaths?
        for (call, host) in zip(calls, hosts) {
            let region = reference.region(take: take.id, camera: camera, target: target)
            XCTAssertEqual(call.region, region)
            expected = reference.update(sample: sample, host: host, camera: camera, region: region, target: target)
        }
        let scene = LipMirrorGeometry.sceneRegion(camera: camera, aspect: target.aspect)
        XCTAssertNotEqual(calls.last?.region, scene, "камера не въехала к рту — сверка ничего не проверяет")

        let last = try XCTUnwrap(shown.last ?? nil)
        XCTAssertEqual(last.host, try XCTUnwrap(hosts.last), accuracy: 1e-9)
        let paths = try XCTUnwrap(last.paths)
        let want = try XCTUnwrap(expected)
        XCTAssertEqual(paths.band.boundingBoxOfPath, want.band.boundingBoxOfPath)
        XCTAssertEqual(paths.grid.boundingBoxOfPath, want.grid.boundingBoxOfPath)
        finish(engine, events)
    }

    /// Рендер и Vision одного кадра идут одновременно: каждый ждёт, пока в
    /// работу войдёт другой. При последовательном исполнении одно из ожиданий
    /// истекло бы.
    @MainActor
    func testRenderRunsInParallelWithVision() throws {
        let detector = RecordingDetector(), renderer = RecordingRenderer(), events = Events()
        let visionEntered = DispatchSemaphore(value: 0), renderEntered = DispatchSemaphore(value: 0)
        let results = Events()
        detector.onDetect = {
            visionEntered.signal()
            results.add("vision \(renderEntered.wait(timeout: .now() + 2) == .success)")
        }
        renderer.onRender = {
            renderEntered.signal()
            results.add("render \(visionEntered.wait(timeout: .now() + 2) == .success)")
        }
        let engine = makeEngine(detector, renderer, events)
        let owner = engine.mirrorFeed.attach(target: target) { _ in }
        defer { engine.mirrorFeed.detach(owner: owner) }
        _ = try begin(engine)

        _ = try feedFrames(engine, count: 1)

        XCTAssertEqual(results.all.sorted(), ["render true", "vision true"])
        finish(engine, events)
    }

    /// Рендер не удался — флаг занятости всё равно снят (каждый следующий
    /// кадр снова идёт и в Vision, и в рендер), журнал лица на прежнем ритме,
    /// а кадр без картинки вью не получает: маска поверх чёрного не мигает.
    @MainActor
    func testRenderFailureKeepsGateAndJournal() throws {
        let detector = RecordingDetector(sample: LipSyntheticFace.sample()), renderer = RecordingRenderer(fails: true)
        let events = Events()
        let engine = makeEngine(detector, renderer, events)
        var shown: [LipMirrorFrame?] = []
        let owner = engine.mirrorFeed.attach(target: target) { shown.append($0) }
        defer { engine.mirrorFeed.detach(owner: owner) }
        let take = try begin(engine)

        let hosts = try feedFrames(engine, count: 6)
        flushMain()

        XCTAssertEqual(renderer.calls.count, hosts.count)
        XCTAssertEqual(detector.buffers.count, hosts.count)
        XCTAssertEqual(shown.count, 1, "только «пусто» от начала дубля")
        XCTAssertNil(shown.first ?? nil)
        finish(engine, events)
        let journalHosts = try journal(take).faces.map(\.host)
        let expected = stride(from: 0, to: hosts.count, by: 2).map { hosts[$0] }
        XCTAssertEqual(journalHosts.count, expected.count, "журнал: \(journalHosts)")
        for (got, want) in zip(journalHosts, expected) {
            XCTAssertEqual(got, want, accuracy: 1e-9)
        }
    }

    /// Прогрев — один раз за процесс: рендерер и модель Vision прогреваются
    /// ровно по разу, сколько бы раз его ни звали.
    func testPrewarmRunsOnce() {
        let detector = RecordingDetector(), renderer = RecordingRenderer()
        let engine = LipCameraEngine(detector: detector, renderer: renderer)

        engine.prewarmMirror()
        engine.prewarmMirror()
        engine.visionQueue.sync {}

        XCTAssertEqual(renderer.prewarms, 1)
        XCTAssertEqual(detector.buffers.count, 1)
        XCTAssertEqual(renderer.calls.count, 0)
    }
}
