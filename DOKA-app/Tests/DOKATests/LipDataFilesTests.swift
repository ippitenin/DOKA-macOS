import XCTest
@testable import DOKA

/// Файловый слой пар губ: раскладка `LipData`, фиксация, уборка, удаление.
///
/// Зачем: каждая ловушка здесь — про потерю данных или мусор. Дубль, чья
/// обработка не успела до выхода, обязан доделаться после запуска; огрызки
/// и брошенные папки — исчезнуть; «Удалить всё» — не трогать сам корень
/// (на него смотрит симлинк инструмента обучения); клип без `meta.json`
/// не должен притворяться парой.
final class LipDataFilesTests: XCTestCase {
    private var root: URL!
    private var files: LipDataFiles!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("doka-lipdata-tests-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        files = LipDataFiles(root: root)
    }

    override func tearDown() {
        try? fm.removeItem(at: root)
    }

    // MARK: - Помощники

    private func makePending(_ id: UUID, files names: [String], age: TimeInterval = 3600) throws -> URL {
        let folder = files.pendingFolder(id)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in names { try Data("x".utf8).write(to: folder.appendingPathComponent(name)) }
        try backdate(folder, by: age)
        return folder
    }

    private func backdate(_ url: URL, by age: TimeInterval) throws {
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path)
    }

    private func meta(_ id: UUID, mode: LipMode) -> LipTakeMeta {
        LipTakeMeta(schemaVersion: 1, id: id, date: Date(timeIntervalSince1970: 1_791_115_200),
                    source: "dictation", mode: mode, text: "привет", language: "ru", provider: "Nexara",
                    model: "whisper-1", historyID: nil, duration: 3, speechSeconds: 2, quietSpeechSeconds: 2,
                    speechOnset: 0.4, quiet: mode == .whisper,
                    video: .init(width: 512, height: 512, fps: 30, validFrom: 0.3, validTo: 3, faceCoverage: 1,
                                 faceGaps: [], cropRect: [0, 0, 512, 512], cameraFrame: [1280, 720],
                                 camera: "FaceTime HD Camera", measuredFps: 30, droppedFrames: 0,
                                 multiFaceFrames: 0, mirrored: false,
                                 effects: .init(centerStage: false, portrait: false, studioLight: false,
                                                backgroundReplacement: false, reactions: false)),
                    audio: .init(sampleRate: 16000, codec: "aac", inputLatency: 0, maxClockDrift: 0,
                                 microphone: nil),
                    appVersion: "test")
    }

    private func commitTake(_ id: UUID, mode: LipMode) throws {
        _ = try makePending(id, files: LipDataFiles.readyFiles)
        try Data("clip".utf8).write(to: files.clipPartURL(id))
        XCTAssertTrue(try files.commit(id: id, meta: meta(id, mode: mode)))
    }

    // MARK: - Уборка на старте

    /// Готовый дубль (все четыре файла) после перезапуска доделывается;
    /// брошенное сырьё, клип без meta, огрызки и корзина — удаляются.
    func testSweepResumesReadyPendingAndRemovesJunk() throws {
        let ready = UUID(), halfDone = UUID(), noMeta = UUID(), withMeta = UUID()
        _ = try makePending(ready, files: LipDataFiles.readyFiles)
        _ = try makePending(halfDone, files: ["raw.mp4", "capture.json"])

        let orphan = files.takeFolder(noMeta)
        try fm.createDirectory(at: orphan, withIntermediateDirectories: true)
        try Data("clip".utf8).write(to: orphan.appendingPathComponent("clip.mp4"))
        try backdate(orphan, by: 3600)

        try commitTake(withMeta, mode: .voice)
        let part = files.clipPartURL(withMeta)
        try Data("x".utf8).write(to: part)
        try backdate(part, by: 3600)

        let trash = root.appendingPathComponent("takes.deleting-\(UUID().uuidString)")
        try fm.createDirectory(at: trash, withIntermediateDirectories: true)

        let resumable = files.sweep(launch: Date())
        XCTAssertEqual(resumable, [ready])
        XCTAssertFalse(fm.fileExists(atPath: files.pendingFolder(halfDone).path))
        XCTAssertFalse(fm.fileExists(atPath: orphan.path))
        XCTAssertFalse(fm.fileExists(atPath: part.path))
        XCTAssertTrue(fm.fileExists(atPath: files.takeFolder(withMeta).appendingPathComponent("meta.json").path))
        XCTAssertFalse(fm.fileExists(atPath: trash.path))
    }

    /// Свежее сырьё (создано после запуска) — это идущая запись, его не трогать.
    func testSweepLeavesFreshPending() throws {
        let fresh = UUID()
        _ = try makePending(fresh, files: ["raw.mp4"], age: 0)
        XCTAssertEqual(files.sweep(launch: Date().addingTimeInterval(-60)), [])
        XCTAssertTrue(fm.fileExists(atPath: files.pendingFolder(fresh).path))
    }

    // MARK: - Фиксация

    /// Клип переименовывается, meta пишется, сырьё уходит.
    func testCommitMovesClipWritesMetaAndDropsPending() throws {
        let id = UUID()
        try commitTake(id, mode: .whisper)
        let take = files.takeFolder(id)
        XCTAssertTrue(fm.fileExists(atPath: take.appendingPathComponent("clip.mp4").path))
        XCTAssertFalse(fm.fileExists(atPath: files.clipPartURL(id).path))
        let data = try Data(contentsOf: take.appendingPathComponent("meta.json"))
        XCTAssertEqual(try LipTakeMeta.decoder.decode(LipTakeMeta.self, from: data).mode, .whisper)
        XCTAssertFalse(fm.fileExists(atPath: files.pendingFolder(id).path))
    }

    /// Пока кодировалось, всё удалили — клип не воскрешает пару.
    func testCommitAfterDeletionDiscardsClip() throws {
        let id = UUID()
        try Data("clip".utf8).write(to: files.clipPartURL(id))
        XCTAssertFalse(try files.commit(id: id, meta: meta(id, mode: .voice)))
        XCTAssertFalse(fm.fileExists(atPath: files.takeFolder(id).path))
    }

    func testRejectRemovesPending() throws {
        let id = UUID()
        _ = try makePending(id, files: LipDataFiles.readyFiles)
        files.reject(id: id)
        XCTAssertFalse(fm.fileExists(atPath: files.pendingFolder(id).path))
    }

    /// WAV диктовки сразу после фиксации удаляется — дубль держит свою ссылку.
    func testLinkAudioSurvivesSourceRemoval() throws {
        let id = UUID()
        _ = try makePending(id, files: [], age: 0)
        let wav = root.appendingPathComponent("doka-test.wav")
        try Data("RIFF".utf8).write(to: wav)
        try files.linkAudio(wav, into: id)
        try fm.removeItem(at: wav)
        XCTAssertEqual(try Data(contentsOf: files.pendingFolder(id).appendingPathComponent("audio.wav")),
                       Data("RIFF".utf8))
    }

    // MARK: - Сводка и удаление

    func testSummaryCountsPairsByMode() throws {
        try commitTake(UUID(), mode: .voice)
        try commitTake(UUID(), mode: .voice)
        try commitTake(UUID(), mode: .whisper)
        let summary = files.summary()
        XCTAssertEqual(summary.voice, 2)
        XCTAssertEqual(summary.whisper, 1)
        XCTAssertGreaterThan(summary.bytes, 0)
    }

    /// «Удалить всё» стирает пары, сырьё и счётчики, но корень остаётся.
    func testDeleteAllKeepsRoot() throws {
        try commitTake(UUID(), mode: .voice)
        _ = try makePending(UUID(), files: ["raw.mp4"])
        files.writeStats(LipStats(rejected: ["noFace": 3], headMissing: 2))
        files.deleteAll()
        XCTAssertTrue(fm.fileExists(atPath: root.path))
        XCTAssertEqual(files.summary().voice, 0)
        XCTAssertEqual(files.readStats(), LipStats())
        XCTAssertEqual((try? fm.contentsOfDirectory(atPath: root.path)) ?? [], [])
    }

    func testStatsRoundTrip() {
        files.writeStats(LipStats(rejected: ["lateCamera": 1], headMissing: 4))
        XCTAssertEqual(files.readStats(), LipStats(rejected: ["lateCamera": 1], headMissing: 4))
    }
}
