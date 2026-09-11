import XCTest
@testable import DOKA

/// Группы ленты библиотеки. Календарь и часовой пояс фиксированы: неделя с
/// понедельника, как в русской локали, и без сюрпризов летнего времени.
final class LibraryGroupingTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Moscow")!
        calendar.firstWeekday = 2
        return calendar
    }()

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    // Четверг, 10 сентября 2026: неделя — с понедельника 7-го.
    private var thursday: Date { date(2026, 9, 10, 15) }

    func testToday() {
        XCTAssertEqual(LibraryGrouping.bucket(for: date(2026, 9, 10, 0, 0), now: thursday, calendar: calendar), .today)
        XCTAssertEqual(LibraryGrouping.bucket(for: date(2026, 9, 10, 14), now: thursday, calendar: calendar), .today)
    }

    func testYesterday() {
        XCTAssertEqual(LibraryGrouping.bucket(for: date(2026, 9, 9, 0, 0), now: thursday, calendar: calendar), .yesterday)
        XCTAssertEqual(LibraryGrouping.bucket(for: date(2026, 9, 9, 23, 59), now: thursday, calendar: calendar), .yesterday)
    }

    func testThisWeek() {
        XCTAssertEqual(LibraryGrouping.bucket(for: date(2026, 9, 7, 0, 30), now: thursday, calendar: calendar), .thisWeek)
        XCTAssertEqual(LibraryGrouping.bucket(for: date(2026, 9, 8), now: thursday, calendar: calendar), .thisWeek)
    }

    func testEarlier() {
        XCTAssertEqual(LibraryGrouping.bucket(for: date(2026, 9, 6, 23, 59), now: thursday, calendar: calendar), .earlier)
        XCTAssertEqual(LibraryGrouping.bucket(for: date(2025, 1, 1), now: thursday, calendar: calendar), .earlier)
    }

    /// В понедельник воскресенье — прошлая неделя, но показывается «Вчера».
    func testYesterdayWinsOverPreviousWeekOnMonday() {
        let monday = date(2026, 9, 7, 9)
        XCTAssertEqual(LibraryGrouping.bucket(for: date(2026, 9, 6, 20), now: monday, calendar: calendar), .yesterday)
        XCTAssertEqual(LibraryGrouping.bucket(for: date(2026, 9, 5, 20), now: monday, calendar: calendar), .earlier)
    }

    /// Часы сдвинули назад — запись «из будущего» не должна уезжать в «Раньше».
    func testFutureDateIsToday() {
        XCTAssertEqual(LibraryGrouping.bucket(for: date(2026, 9, 12), now: thursday, calendar: calendar), .today)
    }

    func testGroupKeepsOrderAndSkipsEmptyGroups() {
        let items = [
            ("a", date(2026, 9, 10, 14)),
            ("b", date(2026, 9, 1)),
            ("c", date(2026, 9, 10, 9)),
            ("d", date(2026, 8, 20))
        ]
        let groups = LibraryGrouping.group(items, date: { $0.1 }, now: thursday, calendar: calendar)
        XCTAssertEqual(groups.map(\.kind), [.today, .earlier])
        XCTAssertEqual(groups[0].items.map(\.0), ["a", "c"])
        XCTAssertEqual(groups[1].items.map(\.0), ["b", "d"])
    }

    func testGroupOfEmptyList() {
        let groups = LibraryGrouping.group([Date](), date: { $0 }, now: thursday, calendar: calendar)
        XCTAssertTrue(groups.isEmpty)
    }
}
