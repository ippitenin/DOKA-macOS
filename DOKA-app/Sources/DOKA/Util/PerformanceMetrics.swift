import Foundation

/// Сведения о системе для блока System Information (экран Analyze).
struct SystemInfo {
    let device: String
    let processor: String
    let memory: String

    static func current() -> SystemInfo {
        SystemInfo(
            device: sysctlString("hw.model") ?? "Mac",
            // На M-чипе отдаёт «Apple M… Pro». Прежний фолбэк
            // `hw.perflevel0.name` давал имя кластера ядер («Super»), а не чипа.
            processor: sysctlString("machdep.cpu.brand_string") ?? "—",
            memory: ByteCountFormatter.string(
                fromByteCount: Int64(ProcessInfo.processInfo.physicalMemory),
                countStyle: .memory)
        )
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}

/// Агрегаты производительности по выборке записей (экран Analyze).
/// Чистый value-type — тестопригоден (как `DashboardMetrics`).
struct PerformanceMetrics {
    let records: [TranscriptionRecord]

    init(records: [TranscriptionRecord]) { self.records = records }

    var totalTranscripts: Int { records.count }
    var totalWords: Int { records.reduce(0) { $0 + $1.text.dokaWordCount } }

    /// «Анализируемые» — есть и время распознавания, и длительность.
    /// Старые записи без latency сюда не попадают.
    var analyzable: [TranscriptionRecord] {
        records.filter { ($0.transcriptionTime ?? 0) > 0 && $0.duration > 0 }
    }
    var analyzableCount: Int { analyzable.count }

    var byModel: [Group] { grouped { $0.model ?? "—" } }
    var byProvider: [Group] { grouped { $0.provider ?? "—" } }

    private func grouped(by key: (TranscriptionRecord) -> String) -> [Group] {
        var buckets: [String: [TranscriptionRecord]] = [:]
        for r in analyzable { buckets[key(r), default: []].append(r) }
        return buckets
            .map { name, recs in
                Group(
                    name: name,
                    count: recs.count,
                    totalAudio: recs.reduce(0) { $0 + $1.duration },
                    totalProcess: recs.reduce(0) { $0 + ($1.transcriptionTime ?? 0) },
                    words: recs.reduce(0) { $0 + $1.text.dokaWordCount }
                )
            }
            .sorted { $0.count > $1.count }
    }

    /// Группа по модели/провайдеру.
    struct Group: Identifiable {
        var id: String { name }
        let name: String
        let count: Int
        let totalAudio: TimeInterval
        let totalProcess: TimeInterval
        let words: Int

        /// «X× быстрее реального времени» = суммарное аудио / суммарное время распознавания.
        var fasterThanRealtime: Double { totalProcess > 0 ? totalAudio / totalProcess : 0 }
        var avgAudio: TimeInterval { count > 0 ? totalAudio / Double(count) : 0 }
        var avgProcess: TimeInterval { count > 0 ? totalProcess / Double(count) : 0 }
    }
}
