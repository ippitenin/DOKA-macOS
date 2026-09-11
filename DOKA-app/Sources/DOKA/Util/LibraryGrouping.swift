import Foundation

/// Группа ленты библиотеки по дате записи.
enum LibraryDateGroup: CaseIterable, Equatable {
    case today, yesterday, thisWeek, earlier

    /// Заголовок — литеральным `switch`: ключи не собираются интерполяцией,
    /// поэтому `DYNAMIC_PREFIXES` в check-localization.sh не пополняется.
    var title: String {
        switch self {
        case .today: return L("library.group.today")
        case .yesterday: return L("library.group.yesterday")
        case .thisWeek: return L("library.group.thisWeek")
        case .earlier: return L("library.group.earlier")
        }
    }
}

/// Группа с элементами в исходном порядке.
struct LibraryGroup<Item>: Identifiable {
    let kind: LibraryDateGroup
    var items: [Item]

    var id: LibraryDateGroup { kind }
}

/// Раскладка записей библиотеки по группам «Сегодня / Вчера / На этой неделе /
/// Раньше». Чистые функции: календарь и «сейчас» передаются явно — в тестах
/// фиксированные, в UI — текущие.
enum LibraryGrouping {
    /// Группа одной даты. «Вчера» приоритетнее «На этой неделе» (в понедельник
    /// воскресенье остаётся «Вчера», хотя это уже прошлая неделя); дата из
    /// будущего (часы сдвинули назад) — «Сегодня», а не «Раньше».
    static func bucket(for date: Date, now: Date, calendar: Calendar) -> LibraryDateGroup {
        let startOfToday = calendar.startOfDay(for: now)
        if date >= startOfToday { return .today }
        if let startOfYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday),
           date >= startOfYesterday {
            return .yesterday
        }
        if let week = calendar.dateInterval(of: .weekOfYear, for: now), week.contains(date) {
            return .thisWeek
        }
        return .earlier
    }

    /// Группы в порядке `LibraryDateGroup.allCases`, пустые пропущены; внутри
    /// группы сохраняется порядок входа (сортирует вызывающий).
    static func group<Item>(_ items: [Item], date: (Item) -> Date,
                            now: Date, calendar: Calendar) -> [LibraryGroup<Item>] {
        var buckets: [LibraryDateGroup: [Item]] = [:]
        for item in items {
            buckets[bucket(for: date(item), now: now, calendar: calendar), default: []].append(item)
        }
        return LibraryDateGroup.allCases.compactMap { kind in
            guard let items = buckets[kind], !items.isEmpty else { return nil }
            return LibraryGroup(kind: kind, items: items)
        }
    }
}
