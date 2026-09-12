import Foundation

/// Посуточный бакет статистики (ключ — день в локальной timezone, начало суток).
struct StatsDayBucket: Codable, Equatable {
    var words: Int
    var duration: TimeInterval
    var sessions: Int

    init(words: Int, duration: TimeInterval, sessions: Int) {
        self.words = words
        self.duration = duration
        self.sessions = sessions
    }

    private enum CodingKeys: String, CodingKey { case words, duration, sessions }

    /// Толерантный декодер — по той же причине, что и у `StatsSnapshot`, но
    /// упустить его здесь опаснее: синтезированный декодер бросает на любом
    /// недостающем ключе, а бакеты лежат ВНУТРИ снимка. Одно новое поле в
    /// этой структуре — и все файлы, записанные прошлой версией, перестали бы
    /// декодироваться целиком: `try?` в `StatsStore.load()` проглотил бы
    /// ошибку, и накопленное «за всё время» молча обнулилось бы. Восстановить
    /// его неоткуда — история капается на 200 записей.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        words = try c.decodeIfPresent(Int.self, forKey: .words) ?? 0
        duration = try c.decodeIfPresent(TimeInterval.self, forKey: .duration) ?? 0
        sessions = try c.decodeIfPresent(Int.self, forKey: .sessions) ?? 0
    }
}

/// Снимок статистики на диске. Версионируется на случай будущих миграций.
struct StatsSnapshot: Codable, Equatable {
    var version: Int = 2
    var totalWords: Int = 0
    var totalDuration: TimeInterval = 0
    var totalSessions: Int = 0
    /// Слова и длительность активной речи (без тишины/пауз) — основа «скорости речи».
    /// Накапливаются только по записям с измеренной активностью (новый рекордер);
    /// старые данные сюда не попадают и считаются по полной длительности записи.
    var totalSpeechWords: Int = 0
    var totalSpeechDuration: TimeInterval = 0
    var firstUseDate: Date? = nil
    /// Ключ — "yyyy-MM-dd" (en_US_POSIX, локальная TZ) начала суток.
    var days: [String: StatsDayBucket] = [:]
    /// Был ли выполнен одноразовый бэкфилл из истории (идемпотентность).
    var seededFromHistory: Bool = false

    enum CodingKeys: String, CodingKey {
        case version, totalWords, totalDuration, totalSessions
        case totalSpeechWords, totalSpeechDuration, firstUseDate, days, seededFromHistory
    }
}

extension StatsSnapshot {
    /// Толерантный декодер: отсутствующие ключи берут значения по умолчанию.
    /// Синтезированный `Decodable` бросает ошибку на любом недостающем ключе —
    /// тогда добавление поля или старый файл обнулили бы накопленную статистику.
    /// Здесь же отсутствие ключа просто означает «дефолт».
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 2
        totalWords = try c.decodeIfPresent(Int.self, forKey: .totalWords) ?? 0
        totalDuration = try c.decodeIfPresent(TimeInterval.self, forKey: .totalDuration) ?? 0
        totalSessions = try c.decodeIfPresent(Int.self, forKey: .totalSessions) ?? 0
        totalSpeechWords = try c.decodeIfPresent(Int.self, forKey: .totalSpeechWords) ?? 0
        totalSpeechDuration = try c.decodeIfPresent(TimeInterval.self, forKey: .totalSpeechDuration) ?? 0
        firstUseDate = try c.decodeIfPresent(Date.self, forKey: .firstUseDate)
        days = try c.decodeIfPresent([String: StatsDayBucket].self, forKey: .days) ?? [:]
        seededFromHistory = try c.decodeIfPresent(Bool.self, forKey: .seededFromHistory) ?? false
    }
}

/// Персистентная статистика диктовки: lifetime-агрегаты + посуточные бакеты.
/// История (`HistoryStore`) капается на 200 записей, поэтому агрегаты «за всё
/// время» хранятся отдельно и инкрементятся на каждой завершённой диктовке.
/// JSON в `~/Library/Application Support/DOKA/stats.json` (тот же каталог и
/// паттерн, что у `HistoryStore`).
@MainActor
final class StatsStore: ObservableObject {
    static let shared = StatsStore()

    @Published private(set) var snapshot = StatsSnapshot()

    private let fileURL: URL

    /// Формат ключа суток — фиксированный, не зависит от локали пользователя.
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f
    }()

    private init() {
        let dir = AppDataFolder.currentURL
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("stats.json")
        load()
        seedFromHistoryIfNeeded()
    }

    // MARK: - Инкремент (вызывается на каждой завершённой диктовке)

    func record(text: String, duration: TimeInterval, speechDuration: TimeInterval = 0, date: Date = Date()) {
        let words = text.dokaWordCount
        guard words > 0 || duration > 0 else { return }
        snapshot.totalWords += words
        snapshot.totalDuration += duration
        snapshot.totalSessions += 1
        // Активную речь учитываем только когда она измерена — иначе «скорость речи»
        // занижается тишиной/паузами в записи.
        if speechDuration > 0 {
            snapshot.totalSpeechWords += words
            snapshot.totalSpeechDuration += speechDuration
        }
        if snapshot.firstUseDate == nil { snapshot.firstUseDate = date }
        addToDay(date: date, words: words, duration: duration, sessions: 1)
        save()
    }

    private func addToDay(date: Date, words: Int, duration: TimeInterval, sessions: Int) {
        let key = Self.dayFormatter.string(from: date)
        var bucket = snapshot.days[key] ?? StatsDayBucket(words: 0, duration: 0, sessions: 0)
        bucket.words += words
        bucket.duration += duration
        bucket.sessions += sessions
        snapshot.days[key] = bucket
    }

    // MARK: - Бэкфилл из истории (один раз)

    /// При первом запуске новой версии (пустой стор) — переносит агрегаты из
    /// текущей истории, чтобы дашборд сразу был наполнен. Флаг `seededFromHistory`
    /// делает операцию идемпотентной (без задвоения при повторных запусках).
    private func seedFromHistoryIfNeeded() {
        guard !snapshot.seededFromHistory else { return }
        // Сеем только в пустой стор, иначе уже учтённое задвоится.
        guard snapshot.totalSessions == 0 else {
            snapshot.seededFromHistory = true
            save()
            return
        }
        let records = HistoryStore.shared.records
        for record in records {
            let words = record.text.dokaWordCount
            snapshot.totalWords += words
            snapshot.totalDuration += record.duration
            snapshot.totalSessions += 1
            addToDay(date: record.date, words: words, duration: record.duration, sessions: 1)
        }
        snapshot.firstUseDate = records.map(\.date).min()
        snapshot.seededFromHistory = true
        save()
    }

    // MARK: - Доступ для дашборда

    /// Ровно `days` точек: от начала сегодняшних суток назад, по возрастанию даты,
    /// с нулевыми бакетами для пустых дней (постоянная ширина графика).
    func recentDays(_ days: Int = 30) -> [(date: Date, bucket: StatsDayBucket)] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        var result: [(date: Date, bucket: StatsDayBucket)] = []
        for offset in stride(from: days - 1, through: 0, by: -1) {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            let key = Self.dayFormatter.string(from: day)
            let bucket = snapshot.days[key] ?? StatsDayBucket(words: 0, duration: 0, sessions: 0)
            result.append((date: day, bucket: bucket))
        }
        return result
    }

    // MARK: - Файл

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(StatsSnapshot.self, from: data) else { return }
        snapshot = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
