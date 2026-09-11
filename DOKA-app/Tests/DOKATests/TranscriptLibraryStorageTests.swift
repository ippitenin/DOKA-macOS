import Combine
import XCTest
@testable import DOKA

/// Хранилище библиотеки: ошибка здесь — тихая потеря расшифровок пользователя.
/// Каждый тест работает во временной «папке данных».
@MainActor
final class TranscriptLibraryStorageTests: XCTestCase {
    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("doka-library-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private var root: URL { dir.appendingPathComponent(TranscriptLibraryFiles.folderName) }

    private func makeStore() -> TranscriptHistoryStore {
        TranscriptHistoryStore(dataFolder: dir)
    }

    private func sample(_ text: String = "Привет мир. Это дока.", llm: String? = nil) -> TranscriptResult {
        let segments = [TranscriptSegment(speaker: "speaker_0", start: 0, end: 3, text: text)]
        return TranscriptResult(fullText: text, language: "ru", duration: 3, segments: segments,
                                rawSegments: segments, words: [], llmOutput: llm)
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    /// Готовая запись в новой библиотеке; всё записано на диск.
    private func makeDoneRecord(in store: TranscriptHistoryStore, llm: String? = nil) -> UUID {
        let id = store.addPending(.init(fileName: "lecture.mp3", provider: "builtin"))
        store.markDone(id, result: sample(llm: llm))
        store.flush()
        return id
    }

    // MARK: - Записи из v1 (плашка о сроке хранения)

    /// Плашку «теперь хранятся всегда» видят только те, у кого были записи v1:
    /// на новой установке флаг миграции индекса тоже ставится, но плашки нет.
    func testRecordsFromV1AreDetectedOnlyAfterLegacyJournal() throws {
        let params = FileTranscriptionParams(providerID: "builtin", language: "auto", diarize: false,
                                             numSpeakers: nil, diarizationSetting: "general",
                                             rolesMode: "off", rolesText: "",
                                             llmPreset: "off", llmCustomPrompt: "")
        let fresh = makeStore()
        XCTAssertFalse(fresh.hasRecordsFromV1)
        fresh.addPending(.init(fileName: "new.mp3", provider: "builtin", params: params))
        XCTAssertFalse(fresh.hasRecordsFromV1)
        fresh.flush()

        let legacyDir = dir.appendingPathComponent("legacy", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyDir, withIntermediateDirectories: true)
        let legacy = FileTranscriptRecord(id: UUID(), fileName: "old.mp3", date: Date(), status: .done,
                                          result: StoredTranscript(sample()), provider: "builtin")
        try JSONEncoder().encode([legacy]).write(to: legacyDir.appendingPathComponent("transcripts.json"))
        let migrated = TranscriptHistoryStore(dataFolder: legacyDir)
        migrated.flush()
        XCTAssertTrue(migrated.hasRecordsFromV1)
    }

    // MARK: - Миграция v1

    func testLegacyJournalMigratesToBodiesAndBackup() throws {
        let id = UUID()
        let legacy = FileTranscriptRecord(id: id, fileName: "meeting.mp3", date: Date(), status: .done,
                                          result: StoredTranscript(sample(llm: "## Итог")),
                                          provider: "builtin")
        try JSONEncoder().encode([legacy]).write(to: dir.appendingPathComponent("transcripts.json"))

        let store = makeStore()
        store.flush()
        XCTAssertEqual(store.records.map(\.id), [id])
        XCTAssertNil(store.records[0].result, "v2 не держит результат в индексе")
        XCTAssertNotNil(store.records[0].summary)
        XCTAssertFalse(exists(dir.appendingPathComponent("transcripts.json")))
        XCTAssertTrue(exists(dir.appendingPathComponent(TranscriptLibraryFiles.legacyBackupName)))

        let body = try XCTUnwrap(store.files.readBodySync(id))
        XCTAssertNil(body.transcript.llmOutput, "анализ живёт только в analyses")
        XCTAssertEqual(body.analyses.count, 1)
        XCTAssertTrue(body.analyses[0].isNexara)
        XCTAssertEqual(body.makeResult(detail: .server).llmOutput, "## Итог")

        // Повторный запуск не дублирует и не воскрешает записи.
        XCTAssertEqual(makeStore().records.map(\.id), [id])
    }

    func testDeletedRecordDoesNotResurrectFromBackup() throws {
        let legacy = FileTranscriptRecord(id: UUID(), fileName: "a.mp3", date: Date(), status: .done,
                                          result: StoredTranscript(sample()), provider: "builtin")
        try JSONEncoder().encode([legacy]).write(to: dir.appendingPathComponent("transcripts.json"))
        let store = makeStore()
        store.delete(legacy.id)
        store.flush()
        XCTAssertTrue(makeStore().records.isEmpty)
    }

    // MARK: - Индекс — кэш, meta.json — правда

    func testMissingIndexIsRebuiltFromMeta() throws {
        let store = makeStore()
        let id = makeDoneRecord(in: store)
        try FileManager.default.removeItem(at: store.files.indexURL)

        let reloaded = makeStore()
        reloaded.flush()
        XCTAssertEqual(reloaded.records.map(\.id), [id])
        XCTAssertTrue(reloaded.records[0].isDone)
        XCTAssertTrue(exists(reloaded.files.bodyURL(id)), "тело не должно пострадать")
    }

    func testCorruptIndexIsKeptAsCopyAndRebuilt() throws {
        let store = makeStore()
        let id = makeDoneRecord(in: store)
        try Data("{ не json".utf8).write(to: store.files.indexURL)

        let reloaded = makeStore()
        reloaded.flush()
        XCTAssertEqual(reloaded.records.map(\.id), [id])
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertTrue(names.contains { $0.hasPrefix("index.corrupt-") })
    }

    func testSweepKeepsRecordFoldersAndRemovesLeftovers() throws {
        let store = makeStore()
        let id = makeDoneRecord(in: store)
        // Мусор: папка без meta и корзина.
        let orphan = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -60)],
                                              ofItemAtPath: orphan.path)
        let bin = root.appendingPathComponent("\(UUID().uuidString).deleting-x")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)

        let reloaded = makeStore()
        reloaded.flush()
        XCTAssertTrue(exists(reloaded.files.bodyURL(id)))
        XCTAssertFalse(exists(orphan))
        XCTAssertFalse(exists(bin))
    }

    func testDeleteRemovesFolderAndRecord() {
        let store = makeStore()
        let id = makeDoneRecord(in: store)
        store.delete(id)
        store.flush()
        XCTAssertFalse(exists(store.files.folder(for: id)))
        XCTAssertTrue(makeStore().records.isEmpty)
    }

    // MARK: - Жизненный цикл

    func testNexaraAnalysisBecomesFirstAnalysis() throws {
        let store = makeStore()
        let id = makeDoneRecord(in: store, llm: "Резюме")
        let body = try XCTUnwrap(store.files.readBodySync(id))
        XCTAssertEqual(body.analyses.map(\.markdown), ["Резюме"])
        XCTAssertEqual(store.record(id)?.summary?.analysisCount, 1)
    }

    func testRenameTrimsAndEmptyFallsBackToFileName() {
        let store = makeStore()
        let id = makeDoneRecord(in: store)
        store.rename(id, title: "  Итоги квартала ")
        XCTAssertEqual(store.record(id)?.displayTitle, "Итоги квартала")
        store.rename(id, title: "   ")
        XCTAssertNil(store.record(id)?.title)
        XCTAssertEqual(store.record(id)?.displayTitle, "lecture")
    }

    /// Безнадёжные записи на старте гасятся БЕЗ уведомлений — пользователь не
    /// ждал их в этой сессии.
    func testHopelessPendingOnLaunchDoesNotNotify() {
        let store = makeStore()
        let id = store.addPending(.init(fileName: "a.mp3", provider: "custom"))
        store.flush()

        let reloaded = makeStore()
        var notified = 0
        let token = reloaded.finished.sink { _ in notified += 1 }
        reloaded.resumePendingJobs()
        XCTAssertEqual(reloaded.record(id)?.failure, .interrupted)
        XCTAssertEqual(notified, 0)
        token.cancel()
    }

    func testCancelledAsyncJobCanBeRepolled() {
        let store = makeStore()
        let id = store.addPending(.init(fileName: "a.mp3", provider: "builtin"))
        store.setJobID(id, jobID: "job-1")
        store.markCancelled(id)
        XCTAssertTrue(store.canRepoll(store.record(id)!))
        store.markError(id, message: "x", failure: .jobFailed)
        XCTAssertFalse(store.canRepoll(store.record(id)!), "упавшую на сервере задачу не опрашиваем")
    }

    // MARK: - Срок хранения

    func testExpiredIDsSkipInProgressAndForever() {
        let old = Date(timeIntervalSinceNow: -48 * 3_600)
        let done = FileTranscriptRecord(id: UUID(), fileName: "a", date: old, status: .done, provider: "b")
        let running = FileTranscriptRecord(id: UUID(), fileName: "b", date: old, status: .inProgress, provider: "b")
        let fresh = FileTranscriptRecord(id: UUID(), fileName: "c", date: Date(), status: .done, provider: "b")
        let records = [done, running, fresh]
        XCTAssertEqual(TranscriptHistoryStore.expiredIDs(records, retention: .hours24, now: Date()), [done.id])
        XCTAssertTrue(TranscriptHistoryStore.expiredIDs(records, retention: .forever, now: Date()).isEmpty)
    }

    func testRetentionDefaultsToForeverWithoutExplicitChoice() {
        XCTAssertEqual(TranscriptRetention.resolve(stored: nil), .forever)
        XCTAssertEqual(TranscriptRetention.resolve(stored: "hours12"), .hours12)
        XCTAssertEqual(TranscriptRetention.resolve(stored: "мусор"), .forever)
        XCTAssertFalse(TranscriptRetention.isExplicit(stored: nil))
        XCTAssertTrue(TranscriptRetention.isExplicit(stored: "days30"))
    }

    // MARK: - Устойчивый декод

    func testUnknownFailureKindDecodesAsOther() throws {
        let data = Data(#"["из-будущего"]"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode([FailureKind].self, from: data), [.other])
    }

    func testAnalysisDecodesWithOnlyMarkdown() throws {
        let analysis = try JSONDecoder().decode(StoredAnalysis.self, from: Data(#"{"markdown":"x"}"#.utf8))
        XCTAssertEqual(analysis.markdown, "x")
        XCTAssertEqual(analysis.source, .nexara)
        XCTAssertFalse(analysis.truncated)
    }

    func testBodyWithBrokenAnalysesKeepsTranscript() throws {
        let transcript = StoredTranscript(sample()).withoutLLMOutput
        var json = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(TranscriptBody(transcript: transcript))) as! [String: Any]
        json["analyses"] = "сломано"
        let data = try JSONSerialization.data(withJSONObject: json)
        let body = try JSONDecoder().decode(TranscriptBody.self, from: data)
        XCTAssertEqual(body.transcript, transcript)
        XCTAssertTrue(body.analyses.isEmpty)
    }
}
