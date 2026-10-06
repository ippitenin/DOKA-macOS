import Foundation

/// Одна запись истории транскрипций.
///
/// Поля после `language` — опциональные: добавлены позже ради карточек/инспектора/плеера.
/// Старый `history.json` без них декодируется штатно (Optional → синтезированный
/// `decodeIfPresent`), новые записи их заполняют. Поля `id/text/date/duration/language`
/// трогать нельзя — их читает бэкфилл `StatsStore`.
struct TranscriptionRecord: Codable, Identifiable, Equatable {
    let id: UUID
    let text: String
    let date: Date
    let duration: TimeInterval
    let language: String
    // Метаданные новых записей (у старых — nil, UI деградирует мягко):
    let speechDuration: TimeInterval?
    let model: String?
    let provider: String?          // SettingsStore.Provider.rawValue
    let microphone: String?
    let transcriptionTime: TimeInterval?   // latency распознавания, сек
    let audioFileName: String?     // "<id>.m4a" в AudioStore, либо nil
    /// Распознанный текст ДО ИИ-обработки, если она его изменила; nil — не
    /// обрабатывали или правки не было. `var` с дефолтом: прежние вызовы
    /// memberwise-init не меняются, старая история читается.
    var rawText: String? = nil
}

extension TranscriptionRecord {
    /// URL существующего файла аудио записи, либо nil (файла нет/не сохранялся).
    var audioURL: URL? { audioFileName.flatMap { AudioStore.shared.url(forFileName: $0) } }
}

/// История транскрипций: JSON-файл в Application Support, максимум 200 записей.
@MainActor
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()
    private static let limit = 200

    @Published private(set) var records: [TranscriptionRecord] = []

    private let fileURL: URL

    private init() {
        let dir = AppDataFolder.currentURL
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("history.json")
        load()
    }

    var lastText: String? { records.first?.text }

    /// Добавляет запись. `id` передаётся снаружи, когда заранее закодировано аудио
    /// (имя файла детерминировано от id); иначе генерируется. Доп. поля — с дефолтами,
    /// поэтому старые вызовы `add(text:duration:language:)` продолжают работать.
    @discardableResult
    func add(id: UUID = UUID(), text: String, duration: TimeInterval, language: String,
             speechDuration: TimeInterval? = nil, model: String? = nil,
             provider: String? = nil, microphone: String? = nil,
             transcriptionTime: TimeInterval? = nil, audioFileName: String? = nil,
             rawText: String? = nil) -> UUID {
        let record = TranscriptionRecord(
            id: id, text: text, date: Date(), duration: duration, language: language,
            speechDuration: speechDuration, model: model, provider: provider,
            microphone: microphone, transcriptionTime: transcriptionTime, audioFileName: audioFileName,
            rawText: rawText
        )
        records.insert(record, at: 0)
        if records.count > Self.limit {
            // Вытесняемые за лимит записи — заодно убираем их аудио с диска.
            let droppedNames = records[Self.limit...].compactMap(\.audioFileName)
            records.removeLast(records.count - Self.limit)
            if !droppedNames.isEmpty { AudioStore.shared.removeFiles(named: droppedNames) }
        }
        save()
        return id
    }

    func delete(_ record: TranscriptionRecord) {
        records.removeAll { $0.id == record.id }
        if let name = record.audioFileName { AudioStore.shared.removeFile(named: name) }
        save()
    }

    /// Пакетное удаление (мультивыбор): один проход, одно сохранение.
    func delete(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let names = records.filter { ids.contains($0.id) }.compactMap(\.audioFileName)
        records.removeAll { ids.contains($0.id) }
        if !names.isEmpty { AudioStore.shared.removeFiles(named: names) }
        save()
    }

    func clear() {
        let names = records.compactMap(\.audioFileName)
        records.removeAll()
        if !names.isEmpty { AudioStore.shared.removeFiles(named: names) }
        save()
    }

    /// Удаляет аудиофайлы записей старше срока хранения. Тексты записей остаются —
    /// UI деградирует мягко (`AudioStore.url(forFileName:)` проверяет наличие файла).
    func pruneAudio(olderThan days: Int) {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let names = records.filter { $0.date < cutoff }.compactMap(\.audioFileName)
        if !names.isEmpty { AudioStore.shared.removeFiles(named: names) }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([TranscriptionRecord].self, from: data) else { return }
        records = decoded
        // Подчистить аудио, осиротевшее после крашей между кодированием и сохранением json.
        let keep = Set(decoded.compactMap(\.audioFileName))
        Task.detached { AudioStore.shared.pruneOrphans(keeping: keep) }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
