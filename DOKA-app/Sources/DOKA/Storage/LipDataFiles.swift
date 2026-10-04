import Foundation

/// Файловый слой пар «губы + текст». Раскладка `LipData/` (фиксированный путь,
/// рядом с `Models`, за «Папкой данных» не следует):
///
///     pending/<UUID>/raw.mp4       сырое видео (пишется во время записи)
///     pending/<UUID>/capture.json  журнал кадров — маркер «камера дописала»
///     pending/<UUID>/audio.wav     жёсткая ссылка на WAV диктовки
///     pending/<UUID>/job.json      подпись — маркер «диктовка зафиксирована»
///     takes/<UUID>/clip.mp4        итог (`clip.mp4.part` — пока кодируется)
///     takes/<UUID>/meta.json       источник правды пары, пишется ПОСЛЕДНИМ
///     stats.json                   счётчики отбраковки
///     *.deleting-<uuid>            корзина
///
/// Инструмент обучения читает только `takes/*/meta.json` и `clip.mp4`.
/// Методы синхронные и НЕ потокобезопасные: вызывающий держит их на одной
/// последовательной очереди (`LipDataStore`) — отсюда `@unchecked Sendable`. Исключение — `linkAudio`,
/// которую зовут с главного потока до удаления WAV.
final class LipDataFiles: @unchecked Sendable {
    let root: URL
    private let fm = FileManager.default

    /// Дубль готов к обработке, когда есть все четыре файла.
    static let readyFiles = ["raw.mp4", "capture.json", "audio.wav", "job.json"]

    init(root: URL = AppDataFolder.lipDataURL) {
        self.root = root
    }

    var pendingRoot: URL { root.appendingPathComponent("pending", isDirectory: true) }
    var takesRoot: URL { root.appendingPathComponent("takes", isDirectory: true) }
    private var statsURL: URL { root.appendingPathComponent("stats.json") }

    func pendingFolder(_ id: UUID) -> URL { pendingRoot.appendingPathComponent(id.uuidString, isDirectory: true) }
    func takeFolder(_ id: UUID) -> URL { takesRoot.appendingPathComponent(id.uuidString, isDirectory: true) }

    func rawVideoURL(_ id: UUID) -> URL { pendingFolder(id).appendingPathComponent("raw.mp4") }
    func audioURL(_ id: UUID) -> URL { pendingFolder(id).appendingPathComponent("audio.wav") }
    private func jobURL(_ id: UUID) -> URL { pendingFolder(id).appendingPathComponent("job.json") }
    private func captureURL(_ id: UUID) -> URL { pendingFolder(id).appendingPathComponent("capture.json") }

    /// Куда кодировать клип; папка пары создаётся здесь.
    func clipPartURL(_ id: UUID) -> URL {
        let folder = takeFolder(id)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("clip.mp4.part")
    }

    // MARK: - Сырьё

    /// Жёсткая ссылка на WAV диктовки (копия, если ссылка не вышла): сразу
    /// после фиксации `DictationController.settle` удалит исходник. Временная
    /// папка и Application Support лежат на одном томе — операция мгновенная.
    func linkAudio(_ wav: URL, into id: UUID) throws {
        let destination = audioURL(id)
        try? fm.removeItem(at: destination)
        do {
            try fm.linkItem(at: wav, to: destination)
        } catch {
            try fm.copyItem(at: wav, to: destination)
        }
    }

    /// Записать заказ, только если сырьё ещё на месте (его могли выбросить).
    func writeJob(_ job: LipJob, for id: UUID) throws {
        guard fm.fileExists(atPath: pendingFolder(id).path) else { return }
        try LipTakeMeta.encoder.encode(job).write(to: jobURL(id), options: .atomic)
    }

    func readJob(_ id: UUID) -> LipJob? {
        guard let data = try? Data(contentsOf: jobURL(id)) else { return nil }
        return try? LipTakeMeta.decoder.decode(LipJob.self, from: data)
    }

    func readCaptureLog(_ id: UUID) -> LipCaptureLog? {
        guard let data = try? Data(contentsOf: captureURL(id)) else { return nil }
        return try? JSONDecoder().decode(LipCaptureLog.self, from: data)
    }

    func isReady(_ id: UUID) -> Bool {
        let folder = pendingFolder(id)
        return Self.readyFiles.allSatisfy { fm.fileExists(atPath: folder.appendingPathComponent($0).path) }
    }

    // MARK: - Итог

    /// `clip.mp4.part` → `clip.mp4`, затем `meta.json`, затем сырьё в корзину.
    /// false — сырья уже нет (пока кодировалось, удалили всё): клип выбрасывается.
    @discardableResult
    func commit(id: UUID, meta: LipTakeMeta) throws -> Bool {
        let folder = takeFolder(id)
        guard fm.fileExists(atPath: pendingFolder(id).path) else {
            trash(folder)
            return false
        }
        let clip = folder.appendingPathComponent("clip.mp4")
        try? fm.removeItem(at: clip)
        try fm.moveItem(at: clipPartURL(id), to: clip)
        try LipTakeMeta.encoder.encode(meta).write(to: folder.appendingPathComponent("meta.json"),
                                                   options: .atomic)
        trash(pendingFolder(id))
        return true
    }

    /// Дубль не стал парой — сырьё и недописанный клип уходят.
    func reject(id: UUID) {
        trash(pendingFolder(id))
        let folder = takeFolder(id)
        if !fm.fileExists(atPath: folder.appendingPathComponent("meta.json").path) {
            trash(folder)
        }
    }

    // MARK: - Уборка и удаление

    /// Уборка на старте. Трогает только то, что старше запуска (свежее — это
    /// идущая запись). Возвращает дубли, готовые к обработке: их обработка не
    /// успела до выхода и доделывается сейчас.
    func sweep(launch: Date) -> [UUID] {
        emptyTrash()
        var resumable: [UUID] = []
        for folder in children(pendingRoot) where isOlder(folder, than: launch) {
            if let id = UUID(uuidString: folder.lastPathComponent), isReady(id) {
                resumable.append(id)
            } else {
                trash(folder)
            }
        }
        for folder in children(takesRoot) {
            let meta = folder.appendingPathComponent("meta.json")
            let part = folder.appendingPathComponent("clip.mp4.part")
            if fm.fileExists(atPath: meta.path) {
                if fm.fileExists(atPath: part.path), isOlder(part, than: launch) {
                    try? fm.removeItem(at: part)
                }
            } else if isOlder(folder, than: launch),
                      !resumable.contains(where: { $0.uuidString == folder.lastPathComponent }) {
                trash(folder)
            }
        }
        emptyTrash()
        return resumable
    }

    /// «Удалить всё»: пары, сырьё, счётчики. Сам корень остаётся — на него
    /// может смотреть симлинк инструмента обучения. Здесь — только мгновенные
    /// переименования в корзину: стирание гигабайтов на очереди ввода-вывода
    /// задержало бы выход приложения. Корзину стирает `emptyTrash` отдельно
    /// (вызывающий — фоном), недостёртое добьёт уборка на старте.
    func deleteAll() {
        moveToTrash(takesRoot)
        moveToTrash(pendingRoot)
        try? fm.removeItem(at: statsURL)
    }

    func readStats() -> LipStats {
        guard let data = try? Data(contentsOf: statsURL),
              let stats = try? JSONDecoder().decode(LipStats.self, from: data) else { return LipStats() }
        return stats
    }

    func writeStats(_ stats: LipStats) {
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(stats) else { return }
        try? data.write(to: statsURL, options: .atomic)
    }

    /// Сколько пар по режимам и сколько всё занимает на диске.
    func summary() -> (voice: Int, whisper: Int, silent: Int, bytes: Int64) {
        var voice = 0, whisper = 0, silent = 0
        for folder in children(takesRoot) {
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("meta.json")),
                  let mode = try? LipTakeMeta.decoder.decode(ModeOnly.self, from: data).mode else { continue }
            switch mode {
            case .voice: voice += 1
            case .whisper: whisper += 1
            case .silent: silent += 1
            }
        }
        return (voice, whisper, silent, directorySize(root))
    }

    /// Для сводки достаточно режима — остальные поля не декодируем.
    private struct ModeOnly: Decodable { let mode: LipMode }

    /// Удаление — сначала мгновенный rename в корзину, потом стирание: прерванное
    /// стирание не оставит полупустую папку, похожую на живую.
    private func trash(_ url: URL) {
        if let moved = moveToTrash(url) {
            try? fm.removeItem(at: moved)
        }
    }

    /// Переименовать в корзину; nil — нечего переносить. Не вышло переименовать —
    /// стереть на месте.
    @discardableResult
    private func moveToTrash(_ url: URL) -> URL? {
        guard fm.fileExists(atPath: url.path) else { return nil }
        let target = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).deleting-\(UUID().uuidString)")
        if (try? fm.moveItem(at: url, to: target)) != nil { return target }
        try? fm.removeItem(at: url)
        return nil
    }

    /// Стереть корзину. Трогает только `*.deleting-*`, поэтому её можно звать
    /// с любой очереди параллельно с очередью ввода-вывода.
    func emptyTrash() {
        for parent in [root, pendingRoot, takesRoot] {
            for item in children(parent) where item.lastPathComponent.contains(".deleting-") {
                try? fm.removeItem(at: item)
            }
        }
    }

    private func children(_ folder: URL) -> [URL] {
        (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey],
                                     options: [.skipsHiddenFiles])) ?? []
    }

    private func isOlder(_ url: URL, than date: Date) -> Bool {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return (modified ?? .distantPast) < date
    }

    private func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey],
                                             options: [.skipsHiddenFiles]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            total += Int64((try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?
                .totalFileAllocatedSize ?? 0)
        }
        return total
    }
}
