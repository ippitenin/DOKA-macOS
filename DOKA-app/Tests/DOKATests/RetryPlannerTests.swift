import XCTest
@testable import DOKA

/// «Повторить»: план выбирается по таблице правил, первое подошедшее побеждает.
/// Ошибка здесь — либо лишняя оплата (переотправка вместо бесплатного
/// опроса), либо вечный цикл опроса задачи, которой на сервере уже нет.
final class RetryPlannerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let hour: TimeInterval = 3_600

    private func record(_ status: FileTranscriptRecord.Status = .cancelled,
                        jobID: String? = nil,
                        submittedAgo: TimeInterval? = nil,
                        createdAgo: TimeInterval = 60,
                        failure: FailureKind? = nil) -> FileTranscriptRecord {
        var record = FileTranscriptRecord(id: UUID(), fileName: "a.mp3",
                                          date: now.addingTimeInterval(-createdAgo),
                                          status: status, provider: "builtin")
        record.jobID = jobID
        record.submittedAt = submittedAgo.map { now.addingTimeInterval(-$0) }
        record.failure = failure
        return record
    }

    private func plan(_ record: FileTranscriptRecord,
                      provider: String = "builtin",
                      serviceExists: Bool = true,
                      original: Bool = false,
                      audio: Bool = false) -> RetryPlan? {
        RetryPlanner.plan(for: record, context: .init(providerID: provider,
                                                      serviceExists: serviceExists,
                                                      originalReadable: original,
                                                      hasStoredAudio: audio,
                                                      now: now))
    }

    // MARK: - Повторный опрос

    func testCancelledJobWithinLifetimeIsRepolledEvenWithFileAtHand() {
        let cancelled = record(jobID: "job-1", submittedAgo: hour)
        XCTAssertEqual(plan(cancelled, original: true, audio: true), .repoll(jobID: "job-1"))
    }

    func testTransientErrorIsRepolled() {
        let failed = record(.error("сеть"), jobID: "job-1", submittedAgo: hour, failure: .network)
        XCTAssertEqual(plan(failed), .repoll(jobID: "job-1"))
    }

    /// Ключ и баланс пользователь может исправить — опрос снова имеет смысл.
    func testFixableFailuresAreRepolled() {
        for failure in [FailureKind.auth, .noFunds] {
            let failed = record(.error("x"), jobID: "job-1", submittedAgo: hour, failure: failure)
            XCTAssertEqual(plan(failed), .repoll(jobID: "job-1"), "\(failure)")
        }
    }

    /// Пустой или неразборчивый готовый результат опрос вернул бы тем же —
    /// «Повторить» переотправляет файл, а не крутит опрос 12 часов.
    func testDeterministicResponseErrorIsResent() {
        let failed = record(.error("x"), jobID: "job-1", submittedAgo: hour, failure: .other)
        XCTAssertEqual(plan(failed, original: true), .rerunOriginal(billed: true))
    }

    func testServerSideFailureIsResent() {
        let failed = record(.error("x"), jobID: "job-1", submittedAgo: hour, failure: .jobFailed)
        XCTAssertEqual(plan(failed, original: true), .rerunOriginal(billed: true))
    }

    /// После 404 опрос не повторяется — иначе «Повторить» зациклился бы на нём.
    func testMissingJobIsNotRepolledAgain() {
        let failed = record(.error("x"), jobID: "job-1", submittedAgo: hour, failure: .jobNotFound)
        XCTAssertEqual(plan(failed, audio: true), .rerunStoredAudio(billed: true))
        let expired = record(.error("x"), jobID: "job-1", submittedAgo: hour, failure: .expired)
        XCTAssertEqual(plan(expired, audio: true), .rerunStoredAudio(billed: true))
    }

    func testResultOlderThanServerLifetimeIsResent() {
        let old = record(jobID: "job-1", submittedAgo: 13 * hour)
        XCTAssertEqual(plan(old, original: true), .rerunOriginal(billed: true))
    }

    /// Без `submittedAt` (старые записи) дедлайн — от создания записи.
    func testDeadlineFallsBackToCreationDate() {
        XCTAssertEqual(plan(record(jobID: "job-1", createdAgo: hour)), .repoll(jobID: "job-1"))
        XCTAssertEqual(plan(record(jobID: "job-1", createdAgo: 13 * hour)), .needsFile)
    }

    // MARK: - Переотправка

    func testDeletedPresetIsServiceUnavailable() {
        let preset = "custom:\(UUID().uuidString)"
        XCTAssertEqual(plan(record(), provider: preset, serviceExists: false, original: true, audio: true),
                       .serviceUnavailable)
    }

    func testOriginalIsPreferredOverStoredAudio() {
        XCTAssertEqual(plan(record(), original: true, audio: true), .rerunOriginal(billed: true))
    }

    func testStoredAudioIsFallbackForUnreadableOriginal() {
        XCTAssertEqual(plan(record(), original: false, audio: true), .rerunStoredAudio(billed: true))
    }

    func testNoSourceNeedsFile() {
        XCTAssertEqual(plan(record(.error("x"))), .needsFile)
    }

    func testOnlyNetworkServicesAreBilled() {
        XCTAssertEqual(plan(record(), provider: "local:whisper", original: true), .rerunOriginal(billed: false))
        XCTAssertEqual(plan(record(), provider: "local:parakeet", audio: true), .rerunStoredAudio(billed: false))
        XCTAssertEqual(plan(record(), provider: "custom:\(UUID().uuidString)", original: true),
                       .rerunOriginal(billed: true))
    }

    // MARK: - Повторять нечего

    func testDoneAndRunningRecordsHaveNoPlan() {
        XCTAssertNil(plan(record(.done, jobID: "job-1", submittedAgo: hour), original: true))
        XCTAssertNil(plan(record(.inProgress, jobID: "job-1", submittedAgo: hour), original: true))
        XCTAssertFalse(RetryPlanner.canRepoll(record(.inProgress, jobID: "job-1", submittedAgo: hour), now: now))
    }
}
