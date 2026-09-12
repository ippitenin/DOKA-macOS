import XCTest
@testable import DOKA

/// Сроки хранения: аудио диктовок и записей библиотеки.
///
/// Зачем: `TranscriptRetention.resolve` решает, УДАЛЯТЬ ли расшифровки
/// пользователя, и делает это по отсутствию ключа в UserDefaults. Когда-то
/// дефолтом было 12 часов (срок жизни результата на сервере Nexara), потом
/// журнал стал библиотекой и дефолт сменился на «всегда». Если ветка «ключа
/// нет» когда-нибудь вернётся к 12 часам, у людей молча исчезнут записи —
/// без ошибки, без диалога, просто пустая библиотека после обеда.
final class TranscriptRetentionTests: XCTestCase {

    /// Ключ пишется только при явном выборе в UI, поэтому его отсутствие —
    /// это «пользователь не выбирал», а не «выбрал 12 часов».
    func testMissingKeyMeansForever() {
        XCTAssertEqual(TranscriptRetention.resolve(stored: nil), .forever)
        XCTAssertNil(TranscriptRetention.resolve(stored: nil).hours)
    }

    /// Мусор в настройках — тоже «всегда»: безопасная сторона, ничего не
    /// удаляется. Обратное (падение на дефолт 12 ч) стирало бы данные.
    func testGarbageFallsBackToForever() {
        XCTAssertEqual(TranscriptRetention.resolve(stored: ""), .forever)
        XCTAssertEqual(TranscriptRetention.resolve(stored: "hours13"), .forever)
        XCTAssertEqual(TranscriptRetention.resolve(stored: "🙂"), .forever)
    }

    func testExplicitChoiceIsHonoured() {
        for value in TranscriptRetention.allCases {
            XCTAssertEqual(TranscriptRetention.resolve(stored: value.rawValue), value)
        }
    }

    /// Плашка «записи теперь хранятся всегда» показывается, только пока
    /// пользователь не выбрал срок сам.
    func testIsExplicitOnlyForKnownValues() {
        XCTAssertFalse(TranscriptRetention.isExplicit(stored: nil))
        XCTAssertFalse(TranscriptRetention.isExplicit(stored: "hours13"))
        XCTAssertTrue(TranscriptRetention.isExplicit(stored: "forever"))
        XCTAssertTrue(TranscriptRetention.isExplicit(stored: "hours12"))
    }

    /// «Всегда» обязан быть единственным вариантом без срока: `prune`
    /// пропускает записи ровно по `hours == nil`.
    func testOnlyForeverHasNoDeadline() {
        for value in TranscriptRetention.allCases where value != .forever {
            XCTAssertNotNil(value.hours, "\(value.rawValue) обязан иметь срок")
        }
        XCTAssertNil(TranscriptRetention.forever.hours)
    }

    func testHoursMatchTheirNames() {
        XCTAssertEqual(TranscriptRetention.hours12.hours, 12)
        XCTAssertEqual(TranscriptRetention.hours24.hours, 24)
        XCTAssertEqual(TranscriptRetention.hours48.hours, 48)
        XCTAssertEqual(TranscriptRetention.hours72.hours, 72)
        XCTAssertEqual(TranscriptRetention.days7.hours, 7 * 24)
        XCTAssertEqual(TranscriptRetention.days30.hours, 30 * 24)
    }

    /// Порядок кейсов — это порядок пунктов в пикере «Расширенных»:
    /// от короткого к длинному, «всегда» последним.
    func testCasesGoFromShortestToForever() {
        let hours = TranscriptRetention.allCases.map(\.hours)
        XCTAssertEqual(hours.last, .some(nil), "«всегда» должен быть последним")
        let finite = hours.compactMap { $0 }
        XCTAssertEqual(finite, finite.sorted(), "сроки должны возрастать")
    }
}

/// Срок хранения аудио диктовок (`HistoryStore.pruneAudio`).
final class AudioRetentionTests: XCTestCase {

    func testOnlyForeverHasNoDeadline() {
        for value in AudioRetention.allCases where value != .forever {
            XCTAssertNotNil(value.days, "\(value.rawValue) обязан иметь срок")
        }
        XCTAssertNil(AudioRetention.forever.days)
    }

    func testDaysMatchTheirNames() {
        XCTAssertEqual(AudioRetention.day1.days, 1)
        XCTAssertEqual(AudioRetention.day3.days, 3)
        XCTAssertEqual(AudioRetention.day7.days, 7)
        XCTAssertEqual(AudioRetention.day14.days, 14)
        XCTAssertEqual(AudioRetention.day30.days, 30)
    }

    func testCasesGoFromShortestToForever() {
        let days = AudioRetention.allCases.map(\.days)
        XCTAssertEqual(days.last, .some(nil), "«всегда» должен быть последним")
        let finite = days.compactMap { $0 }
        XCTAssertEqual(finite, finite.sorted(), "сроки должны возрастать")
    }

    /// rawValue уезжает в UserDefaults — переименование кейса молча сбросит
    /// выбор пользователя на дефолт.
    func testRawValuesAreStable() {
        XCTAssertEqual(AudioRetention.allCases.map(\.rawValue),
                       ["day1", "day3", "day7", "day14", "day30", "forever"])
    }
}
