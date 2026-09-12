import XCTest
@testable import DOKA

/// Устойчивость снимка статистики диктовки.
///
/// Зачем: `stats.json` копит агрегаты «за всё время», и восстановить их
/// неоткуда — история капается на 200 записей, поэтому бэкфилл вернёт лишь
/// хвост. `StatsStore.load()` оборачивает декод в `try?`: любое исключение
/// означает не ошибку, а МОЛЧАЛИВОЕ обнуление всей статистики пользователя.
/// Поэтому декодер обязан переживать и отсутствующие поля, и мусор.
final class StatsSnapshotTests: XCTestCase {

    private func decode(_ json: String) throws -> StatsSnapshot {
        try JSONDecoder().decode(StatsSnapshot.self, from: Data(json.utf8))
    }

    // MARK: - Верхний уровень

    /// Снимок из старой версии, где полей ещё не было: дефолты, а не отказ.
    func testMissingTopLevelFieldsDefaultToZero() throws {
        let snapshot = try decode(#"{"totalWords":100}"#)
        XCTAssertEqual(snapshot.totalWords, 100)
        XCTAssertEqual(snapshot.totalDuration, 0)
        XCTAssertEqual(snapshot.totalSessions, 0)
        XCTAssertEqual(snapshot.totalSpeechWords, 0)
        XCTAssertNil(snapshot.firstUseDate)
        XCTAssertTrue(snapshot.days.isEmpty)
        XCTAssertFalse(snapshot.seededFromHistory)
    }

    func testEmptyObjectDecodes() throws {
        XCTAssertEqual(try decode("{}"), StatsSnapshot())
    }

    // MARK: - Посуточные бакеты

    /// ГЛАВНОЕ. Верхний уровень декодируется толерантно, а вложенный бакет —
    /// нет. Стоит добавить в `StatsDayBucket` хоть одно поле, и все файлы,
    /// записанные прошлой версией, перестанут декодироваться: `decodeIfPresent`
    /// бросит на первом же бакете, `try?` в `StatsStore.load()` это проглотит,
    /// и «за всё время» станет нулём. Ровно такую ловушку в проекте уже ловили
    /// на `ReplacementRule` — там её закрыли ручным декодером.
    func testDayBucketWithMissingFieldDoesNotWipeEverything() throws {
        let snapshot = try decode("""
        {"totalWords":5000,"totalSessions":42,
         "days":{"2026-09-01":{"words":10,"duration":5}}}
        """)
        XCTAssertEqual(snapshot.totalWords, 5000, "агрегаты не должны теряться из-за бакета")
        XCTAssertEqual(snapshot.totalSessions, 42)
        XCTAssertEqual(snapshot.days["2026-09-01"],
                       StatsDayBucket(words: 10, duration: 5, sessions: 0))
    }

    func testDayBucketWithUnknownFieldIsAccepted() throws {
        let snapshot = try decode("""
        {"days":{"2026-09-01":{"words":1,"duration":2,"sessions":3,"мусор":true}}}
        """)
        XCTAssertEqual(snapshot.days["2026-09-01"],
                       StatsDayBucket(words: 1, duration: 2, sessions: 3))
    }

    /// Полностью пустой бакет — нули, а не отказ всего файла.
    func testEmptyDayBucketDecodesToZeroes() throws {
        let snapshot = try decode(#"{"days":{"2026-09-01":{}}}"#)
        XCTAssertEqual(snapshot.days["2026-09-01"], StatsDayBucket(words: 0, duration: 0, sessions: 0))
    }

    // MARK: - Round-trip

    func testRoundTripPreservesEverything() throws {
        var snapshot = StatsSnapshot()
        snapshot.totalWords = 1234
        snapshot.totalDuration = 567.8
        snapshot.totalSessions = 90
        snapshot.totalSpeechWords = 1200
        snapshot.totalSpeechDuration = 300
        snapshot.firstUseDate = Date(timeIntervalSince1970: 1_700_000_000)
        snapshot.seededFromHistory = true
        snapshot.days = ["2026-09-01": StatsDayBucket(words: 10, duration: 20, sessions: 2)]
        let data = try JSONEncoder().encode(snapshot)
        XCTAssertEqual(try JSONDecoder().decode(StatsSnapshot.self, from: data), snapshot)
    }

    /// Бэкфилл из истории одноразовый — флаг обязан переживать запись.
    func testSeedFlagSurvivesRoundTrip() throws {
        var snapshot = StatsSnapshot()
        snapshot.seededFromHistory = true
        let data = try JSONEncoder().encode(snapshot)
        XCTAssertTrue(try JSONDecoder().decode(StatsSnapshot.self, from: data).seededFromHistory)
    }
}
