import Foundation

/// Файл индекса библиотеки. Это КЭШ: источник правды — `meta.json` в папке
/// каждой записи, индекс всегда можно восстановить сканированием.
struct LibraryIndexFile: Codable {
    static let currentVersion = 2

    var version: Int
    /// Слияние легаси-журнала v1 уже выполнено — повторно не сливаем
    /// (иначе удалённые пользователем записи воскресали бы из копии).
    var migratedFromV1: Bool
    var records: [FileTranscriptRecord]
}

/// Файловый слой библиотеки транскрибаций:
/// ```
/// <папка данных>/transcripts/
///   index.json              кэш списка (восстанавливается из meta.json)
///   <UUID>/meta.json        FileTranscriptRecord — источник правды
///   <UUID>/transcript.json  TranscriptBody (есть только у готовых)
///   <UUID>/text.txt         плоский текст для поиска
///   <UUID>/audio.m4a        архив звука (audio.m4a.part — пока кодируется)
///   <UUID>.deleting-<uuid>  корзина фонового удаления
/// ```
/// Весь дисковый ввод-вывод идёт через ОДНУ последовательную очередь: чтение,
/// поставленное после записи, видит её (у задач actor такого порядка нет).
/// Состояние класса неизменяемо, кроме `frozen`, которое трогает только
/// очередь, — поэтому `@unchecked Sendable` корректен (прецедент `AudioStore`).
final class TranscriptLibraryFiles: @unchecked Sendable {
    static let folderName = "transcripts"
    static let indexFileName = "index.json"
    static let metaFileName = "meta.json"
    static let bodyFileName = "transcript.json"
    static let textFileName = "text.txt"
    static let audioFileName = "audio.m4a"
    /// Журнал v1 в корне папки данных: читается один раз для миграции.
    static let legacyFileName = "transcripts.json"
    /// Резервная копия v1 после миграции — откат на прошлую версию не теряет
    /// журнал. Живёт ограниченно, иначе удалённые записи пережили бы свой срок.
    static let legacyBackupName = "transcripts.v1.bak"
    static let legacyBackupLifetime: TimeInterval = 14 * 86_400

    let root: URL
    private let dataFolder: URL
    private let queue = DispatchQueue(label: "com.doka.transcripts.io", qos: .utility)
    /// После переноса «Папки данных» запись запрещена до перезапуска: новые
    /// данные ушли бы в папку, которую перенос уже удалил.
    private var frozen = false

    init(dataFolder: URL) {
        self.dataFolder = dataFolder
        root = dataFolder.appendingPathComponent(Self.folderName, isDirectory: true)
    }

    // MARK: - Пути

    var indexURL: URL { root.appendingPathComponent(Self.indexFileName) }
    func folder(for id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    func metaURL(_ id: UUID) -> URL { folder(for: id).appendingPathComponent(Self.metaFileName) }
    func bodyURL(_ id: UUID) -> URL { folder(for: id).appendingPathComponent(Self.bodyFileName) }
    func textURL(_ id: UUID) -> URL { folder(for: id).appendingPathComponent(Self.textFileName) }
    func audioURL(_ id: UUID) -> URL { folder(for: id).appendingPathComponent(Self.audioFileName) }
    func audioPartURL(_ id: UUID) -> URL {
        folder(for: id).appendingPathComponent(Self.audioFileName + ".part")
    }

    /// Архив звука записи, если он реально лежит на диске.
    func existingAudioURL(_ id: UUID) -> URL? {
        let url = audioURL(id)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - Запись (асинхронно на очереди, атомарно)

    func writeMeta(_ record: FileTranscriptRecord) {
        enqueueWrite { [self] in
            try FileManager.default.createDirectory(at: folder(for: record.id),
                                                    withIntermediateDirectories: true)
            try Self.encoder().encode(record).write(to: metaURL(record.id), options: .atomic)
        }
    }

    func writeIndex(_ records: [FileTranscriptRecord], migratedFromV1: Bool) {
        let file = LibraryIndexFile(version: LibraryIndexFile.currentVersion,
                                    migratedFromV1: migratedFromV1, records: records)
        enqueueWrite { [self] in
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Self.encoder().encode(file).write(to: indexURL, options: .atomic)
        }
    }

    func writeBody(_ body: TranscriptBody, id: UUID) {
        enqueueWrite { [self] in
            try FileManager.default.createDirectory(at: folder(for: id),
                                                    withIntermediateDirectories: true)
            try Self.encoder().encode(body).write(to: bodyURL(id), options: .atomic)
        }
    }

    func writeText(_ text: String, id: UUID) {
        enqueueWrite { [self] in
            try FileManager.default.createDirectory(at: folder(for: id),
                                                    withIntermediateDirectories: true)
            try Data(text.utf8).write(to: textURL(id), options: .atomic)
        }
    }

    /// Удаление записей: мгновенный rename папки в корзину (запись пропадает
    /// атомарно), затем стирание — на той же очереди, поэтому `flush()` ждёт
    /// и его (перенос папки не копирует файлы, исчезающие посреди копирования).
    func trash(_ ids: [UUID]) {
        queue.async { [self] in
            guard !frozen else { return }
            let fm = FileManager.default
            for id in ids {
                let folder = folder(for: id)
                guard fm.fileExists(atPath: folder.path) else { continue }
                let bin = root.appendingPathComponent("\(id.uuidString).deleting-\(UUID().uuidString)")
                do {
                    try fm.moveItem(at: folder, to: bin)
                } catch {
                    try? fm.removeItem(at: folder)
                }
            }
        }
    }

    /// Стереть корзину. Вызывающий ставит это ПОСЛЕ записи индекса: переименование
    /// в корзину атомарно убирает записи, индекс уже без них, и kill посреди
    /// долгого стирания ничего не вернёт (остатки подчистит sweep на старте).
    func emptyTrash() {
        queue.async { [self] in
            guard !frozen,
                  let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return }
            for name in names where name.contains(".deleting-") {
                try? FileManager.default.removeItem(at: root.appendingPathComponent(name))
            }
        }
    }

    /// Готовый архив: `.part` → `audio.m4a`, только если запись ещё жива (есть
    /// meta). Удалённая за время кодирования запись не воскреснет от архива.
    func commitAudio(_ id: UUID) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                let fm = FileManager.default
                let part = audioPartURL(id)
                guard !frozen, fm.fileExists(atPath: metaURL(id).path) else {
                    try? fm.removeItem(at: part)
                    continuation.resume(returning: false)
                    return
                }
                try? fm.removeItem(at: audioURL(id))
                do {
                    try fm.moveItem(at: part, to: audioURL(id))
                    continuation.resume(returning: true)
                } catch {
                    try? fm.removeItem(at: part)
                    continuation.resume(returning: false)
                }
            }
        }
    }

    /// Копия архива для «Распознать заново» (на APFS — мгновенный clonefile).
    func cloneAudio(from source: UUID, to target: UUID) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                let fm = FileManager.default
                // meta цели — как в commitAudio: удалённая за это время запись
                // (папка уже в корзине) не воскреснет папкой с одним аудио.
                guard !frozen, fm.fileExists(atPath: audioURL(source).path),
                      fm.fileExists(atPath: metaURL(target).path) else {
                    continuation.resume(returning: false)
                    return
                }
                do {
                    try fm.createDirectory(at: folder(for: target), withIntermediateDirectories: true)
                    try? fm.removeItem(at: audioURL(target))
                    try fm.copyItem(at: audioURL(source), to: audioURL(target))
                    continuation.resume(returning: true)
                } catch {
                    continuation.resume(returning: false)
                }
            }
        }
    }

    func removeAudio(_ ids: [UUID]) {
        queue.async { [self] in
            for id in ids {
                try? FileManager.default.removeItem(at: audioURL(id))
                try? FileManager.default.removeItem(at: audioPartURL(id))
            }
        }
    }

    /// Дождаться всех поставленных операций (перед переносом папки, в тестах).
    func flush() {
        queue.sync {}
    }

    /// Запретить запись до перезапуска (после переноса «Папки данных»).
    func freeze() {
        queue.sync { frozen = true }
    }

    // MARK: - Чтение

    func readBody(_ id: UUID) async -> TranscriptBody? {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                continuation.resume(returning: Self.decodeBody(at: bodyURL(id)))
            }
        }
    }

    /// Синхронное чтение тела (тесты и отладка) — после всех поставленных записей.
    func readBodySync(_ id: UUID) -> TranscriptBody? {
        queue.sync { Self.decodeBody(at: bodyURL(id)) }
    }

    /// Синхронное чтение текста для поиска. Вызывается вне главного потока
    /// (из actor индекса) — никогда не с самой очереди.
    func readText(_ id: UUID) -> String? {
        queue.sync {
            (try? Data(contentsOf: textURL(id))).flatMap { String(data: $0, encoding: .utf8) }
        }
    }

    /// Сколько занимает библиотека и сколько из этого — аудио.
    func librarySize() async -> (total: Int64, audio: Int64) {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                var total: Int64 = 0
                var audio: Int64 = 0
                let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
                if let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) {
                    for case let url as URL in enumerator {
                        let values = try? url.resourceValues(forKeys: Set(keys))
                        guard values?.isRegularFile == true else { continue }
                        let size = Int64(values?.totalFileAllocatedSize ?? 0)
                        total += size
                        if url.lastPathComponent == Self.audioFileName { audio += size }
                    }
                }
                continuation.resume(returning: (total, audio))
            }
        }
    }

    // MARK: - Загрузка и миграция

    struct LoadOutcome {
        var records: [FileTranscriptRecord]
        var migratedFromV1: Bool
        /// Индекс восстанавливали/сверяли — его стоит переписать.
        var indexChanged: Bool
    }

    /// Синхронная загрузка на старте (до `prune`/`resumePendingJobs`):
    /// индекс → сверка с папками записей → одноразовая миграция v1.
    /// Папки с телами здесь НИКОГДА не удаляются: пропавший или битый индекс
    /// восстанавливается из `meta.json`, а не превращается в «пустую
    /// библиотеку», которую sweep затем стёр бы.
    func loadOrMigrate(now: Date = Date()) -> LoadOutcome {
        let fm = FileManager.default
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)

        var records: [FileTranscriptRecord] = []
        var migrated = false
        var changed = false

        if let data = try? Data(contentsOf: indexURL) {
            if let index = try? JSONDecoder().decode(LibraryIndexFile.self, from: data),
               index.version == LibraryIndexFile.currentVersion {
                records = index.records
                migrated = index.migratedFromV1
            } else {
                // Битый индекс не затираем молча: копия для разбора, список —
                // из meta.json записей.
                let stamp = Int(now.timeIntervalSince1970)
                let corrupt = root.appendingPathComponent("index.corrupt-\(stamp).json")
                try? fm.moveItem(at: indexURL, to: corrupt)
                NSLog("DOKA: индекс библиотеки не читается — восстанавливаю из meta.json (копия: \(corrupt.lastPathComponent))")
                changed = true
            }
        } else if fm.fileExists(atPath: root.path) {
            changed = true   // индекса нет — соберём из папок (если они есть)
        }

        // Сверка с папками записей.
        let folderIDs = recordFolderIDs()
        let before = records.count
        records.removeAll { !folderIDs.contains($0.id) }
        if records.count != before { changed = true }
        var known = Set(records.map(\.id))
        for id in folderIDs where !known.contains(id) {
            if let record = Self.decodeMeta(at: metaURL(id)) {
                records.append(record)
                known.insert(id)
                changed = true
            }
        }
        // Незавершённые записи — перечитать meta: крэш между записью meta и
        // индекса оставил бы в индексе устаревший статус (например, «в
        // процессе» у уже готовой записи — её сочли бы прерванной).
        for index in records.indices where records[index].status == .inProgress {
            if let fresh = Self.decodeMeta(at: metaURL(records[index].id)), fresh != records[index] {
                records[index] = fresh
                changed = true
            }
        }

        if !migrated {
            let result = migrateLegacy(into: &records)
            if result.didRun {
                migrated = true
                changed = true
            }
        }
        cleanupLegacyBackup(now: now)

        records.sort { $0.date > $1.date }
        sweep(knownIDs: Set(records.map(\.id)), launch: now)
        return LoadOutcome(records: records, migratedFromV1: migrated, indexChanged: changed)
    }

    /// Слияние журнала v1 (`transcripts.json`). Тела и meta пишутся ДО
    /// индекса с флагом; легаси-файл переименовывается в резервную копию.
    /// Крэш посреди — следующий запуск домерживает по id.
    private func migrateLegacy(into records: inout [FileTranscriptRecord]) -> (didRun: Bool, count: Int) {
        let fm = FileManager.default
        let legacyURL = dataFolder.appendingPathComponent(Self.legacyFileName)
        guard fm.fileExists(atPath: legacyURL.path) else {
            return (true, 0)   // мигрировать нечего — флаг можно ставить
        }
        guard let data = try? Data(contentsOf: legacyURL),
              let legacy = try? JSONDecoder().decode([FileTranscriptRecord].self, from: data) else {
            // Не читается — не трогаем файл и не ставим флаг: попробуем снова.
            NSLog("DOKA: журнал v1 \(Self.legacyFileName) не читается — миграция отложена")
            return (false, 0)
        }
        let known = Set(records.map(\.id))
        var count = 0
        for var record in legacy where !known.contains(record.id) {
            do {
                try fm.createDirectory(at: folder(for: record.id), withIntermediateDirectories: true)
                if let stored = record.result {
                    var analyses: [StoredAnalysis] = []
                    if let llm = stored.llmOutput, !llm.isEmpty {
                        analyses.append(StoredAnalysis(createdAt: record.date,
                                                       title: L("analysis.source.nexaraTitle"),
                                                       templateID: nil, source: .nexara,
                                                       markdown: llm))
                    }
                    let body = TranscriptBody(transcript: stored.withoutLLMOutput, analyses: analyses)
                    try Self.encoder().encode(body).write(to: bodyURL(record.id), options: .atomic)
                    try Data(body.plainText.utf8).write(to: textURL(record.id), options: .atomic)
                    record.summary = RecordSummary.make(from: body)
                }
                record.result = nil
                try Self.encoder().encode(record).write(to: metaURL(record.id), options: .atomic)
                records.append(record)
                count += 1
            } catch {
                NSLog("DOKA: не удалось перенести запись v1 \(record.id): \(error.localizedDescription)")
            }
        }
        // Индекс с флагом — до переименования легаси-файла.
        let file = LibraryIndexFile(version: LibraryIndexFile.currentVersion,
                                    migratedFromV1: true,
                                    records: records.sorted { $0.date > $1.date })
        guard (try? Self.encoder().encode(file).write(to: indexURL, options: .atomic)) != nil else {
            return (false, count)
        }
        let backup = dataFolder.appendingPathComponent(Self.legacyBackupName)
        try? fm.removeItem(at: backup)
        do {
            try fm.moveItem(at: legacyURL, to: backup)
            // Отметка времени переименования — от неё считается срок жизни копии.
            try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: backup.path)
        } catch {
            try? fm.removeItem(at: legacyURL)
        }
        NSLog("DOKA: журнал v1 перенесён в библиотеку: \(count) записей")
        return (true, count)
    }

    private func cleanupLegacyBackup(now: Date) {
        let backup = dataFolder.appendingPathComponent(Self.legacyBackupName)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: backup.path),
              let modified = attributes[.modificationDate] as? Date,
              now.timeIntervalSince(modified) > Self.legacyBackupLifetime else { return }
        try? FileManager.default.removeItem(at: backup)
    }

    /// Уборка на старте (фоном): корзина, недописанные архивы и папки без
    /// meta, созданные до запуска. Папки с `meta.json` не трогаются никогда.
    private func sweep(knownIDs: Set<UUID>, launch: Date) {
        let root = root
        queue.async {
            let fm = FileManager.default
            let keys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey]
            guard let items = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: keys) else { return }
            for url in items {
                let name = url.lastPathComponent
                if name.contains(".deleting-") {
                    try? fm.removeItem(at: url)
                    continue
                }
                guard let id = UUID(uuidString: name) else { continue }
                try? fm.removeItem(at: url.appendingPathComponent(Self.audioFileName + ".part"))
                let hasMeta = fm.fileExists(atPath: url.appendingPathComponent(Self.metaFileName).path)
                if !hasMeta && !knownIDs.contains(id) {
                    let modified = (try? url.resourceValues(forKeys: Set(keys)))?.contentModificationDate
                    if (modified ?? .distantPast) < launch {
                        try? fm.removeItem(at: url)
                    }
                }
            }
        }
    }

    /// id папок записей в корне библиотеки (без корзины и служебных файлов).
    private func recordFolderIDs() -> Set<UUID> {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return [] }
        return Set(names.compactMap { name in
            guard !name.contains(".") else { return nil }
            return UUID(uuidString: name)
        })
    }

    // MARK: - Служебное

    private func enqueueWrite(_ work: @escaping () throws -> Void) {
        queue.async { [self] in
            guard !frozen else {
                NSLog("DOKA: библиотека заморожена до перезапуска — запись пропущена")
                return
            }
            do {
                try work()
            } catch {
                NSLog("DOKA: запись библиотеки не удалась: \(error.localizedDescription)")
            }
        }
    }

    private static func encoder() -> JSONEncoder { JSONEncoder() }

    private static func decodeMeta(at url: URL) -> FileTranscriptRecord? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(FileTranscriptRecord.self, from: data)
    }

    private static func decodeBody(at url: URL) -> TranscriptBody? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(TranscriptBody.self, from: data)
    }
}
