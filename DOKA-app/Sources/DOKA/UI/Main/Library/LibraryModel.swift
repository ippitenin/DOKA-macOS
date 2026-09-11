import AppKit
import Combine
import Foundation

/// Состояние секции «Библиотека». Синглтон: `MainWindowView` пересоздаёт
/// контент секции (`.id(section)`), а поиск, открытая запись, выделение и
/// документы должны это переживать. Во вью — только эфемерное (фокус, ховер).
@MainActor
final class LibraryModel: ObservableObject {
    static let shared = LibraryModel()

    /// Строка поиска как её набирают.
    @Published var query = ""
    /// Запрос, по которому отфильтрован список (через 200 мс после набора).
    @Published private(set) var appliedQuery = ""
    /// id → сниппет совпадения в тексте (для `appliedQuery`).
    @Published private(set) var textMatches: [UUID: String] = [:]
    /// Идёт поиск по текстам — заголовки уже отфильтрованы, тексты догоняют.
    @Published private(set) var isSearchingText = false
    /// Открытая запись; nil — экран списка. Документ держится сильной
    /// ссылкой: запись на экране не должна вытесняться из кэша.
    @Published private(set) var openedDocument: TranscriptDocument?
    @Published var selection: Set<UUID> = []
    /// Запись, которую переименовывают прямо в строке списка.
    @Published private(set) var renamingID: UUID?
    /// Черновик этого переименования — в модели, а не во вью: строка ленивой
    /// ленты пересоздаётся при прокрутке, а переход к другой строке или
    /// открытие записи должны сначала сохранить набранное.
    @Published var renameDraft = ""
    /// Детализация тайм-кодов: последний выбор на сессию (не настройка —
    /// нарезка локальная и не влияет на сохранённую запись).
    @Published var detail: TimestampDetail = .medium
    /// Автоследование ленты за воспроизведением.
    @Published var followPlayback = true
    /// Итог экспорта («Экспортировано: 3, пропущено: 1») — на несколько секунд.
    @Published private(set) var exportNote: String?

    var openedRecordID: UUID? { openedDocument?.recordID }

    private let store = TranscriptHistoryStore.shared
    private var cancellables = Set<AnyCancellable>()
    private var searchTask: Task<Void, Never>?
    private var noteTask: Task<Void, Never>?
    private var doneIDs: Set<UUID> = []

    /// Документы — по одному экземпляру на запись: слабая карта плюс
    /// маленький сильный LRU. Документ, на который ссылается фаза контроллера
    /// или открытая деталь, жив, поэтому два экземпляра одной записи не
    /// появятся (правки следующих фаз иначе разошлись бы).
    private var documents: [UUID: WeakDocument] = [:]
    private var recentDocuments: [TranscriptDocument] = []
    private static let recentDocumentLimit = 4
    private static let searchDebounce: DispatchQueue.SchedulerTimeType.Stride = .milliseconds(200)

    private final class WeakDocument {
        weak var value: TranscriptDocument?
        init(_ value: TranscriptDocument) { self.value = value }
    }

    private init() {
        $query
            .removeDuplicates()
            .debounce(for: Self.searchDebounce, scheduler: DispatchQueue.main)
            .sink { [weak self] query in self?.apply(query: query) }
            .store(in: &cancellables)
        // @Published отдаёт новое значение параметром (willSet).
        store.$records
            .sink { [weak self] records in self?.recordsDidChange(records) }
            .store(in: &cancellables)
        store.bodyChanged
            .sink { [weak self] _ in self?.refreshTextSearch() }
            .store(in: &cancellables)
    }

    // MARK: - Документы и навигация

    func document(for id: UUID) -> TranscriptDocument {
        let document: TranscriptDocument
        if let existing = documents[id]?.value {
            document = existing
        } else {
            document = TranscriptDocument(recordID: id)
            documents = documents.filter { $0.value.value != nil }
            documents[id] = WeakDocument(document)
        }
        recentDocuments.removeAll { $0 === document }
        recentDocuments.append(document)
        if recentDocuments.count > Self.recentDocumentLimit {
            recentDocuments.removeFirst(recentDocuments.count - Self.recentDocumentLimit)
        }
        return document
    }

    func open(_ id: UUID) {
        commitRename()
        guard openedDocument?.recordID != id else { return }
        if let current = openedDocument?.recordID {
            RecordingPlayer.shared.stopIfCurrent(current)
        }
        openedDocument = document(for: id)
    }

    func close() {
        if let current = openedDocument?.recordID {
            RecordingPlayer.shared.stopIfCurrent(current)
        }
        openedDocument = nil
    }

    /// Удаление из списка, пакетом и из детали — одна точка: выполняющуюся
    /// задачу сначала остановить (иначе она дописала бы результат в удалённую
    /// запись), плеер и открытую деталь — закрыть.
    func delete(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let controller = FileTranscriptionController.shared
        if let running = controller.runningRecordID, ids.contains(running) {
            controller.cancelTranscription()
        }
        for id in ids { RecordingPlayer.shared.stopIfCurrent(id) }
        if let opened = openedRecordID, ids.contains(opened) { close() }
        if let renaming = renamingID, ids.contains(renaming) { renamingID = nil }
        selection.subtract(ids)
        store.delete(ids)
    }

    /// Переименование из строки списка и из шапки записи. Пустое — вернуть
    /// имя файла; имя файла, оставленное как есть, своим заголовком не считается.
    func rename(_ record: FileTranscriptRecord, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if record.title == nil && trimmed == record.displayTitle { return }
        store.rename(record.id, title: trimmed)
    }

    // MARK: - Переименование в строке списка

    /// Начать переименование строки. Незаконченное переименование другой
    /// строки сначала сохраняется (кнопки не забирают фокус у поля, и
    /// сохранение по потере фокуса сюда не дошло бы).
    func beginRename(_ record: FileTranscriptRecord) {
        commitRename()
        renameDraft = record.displayTitle
        renamingID = record.id
    }

    /// Сохранить набранное (Enter, клик мимо, переход к другой строке или записи).
    func commitRename() {
        guard let id = renamingID else { return }
        renamingID = nil
        if let record = store.record(id) { rename(record, to: renameDraft) }
    }

    /// Сохранение по потере фокуса поля строки `id`: после Enter, Esc или
    /// перехода к другой строке она уже не переименовывается — повтор игнорируется.
    func commitRename(ifRenaming id: UUID) {
        guard renamingID == id else { return }
        commitRename()
    }

    func cancelRename() {
        renamingID = nil
    }

    // MARK: - Поиск

    /// Очистка крестиком — сразу, без ожидания дебаунса.
    func clearQuery() {
        query = ""
        apply(query: "")
    }

    /// Результат поиска: записи по дате (свежие сверху), у найденных по тексту —
    /// сниппет. Совпадение в заголовке сниппета не даёт: и так видно, почему
    /// запись в списке.
    func filtered(_ records: [FileTranscriptRecord]) -> [LibraryItem] {
        let sorted = records.sorted { $0.date > $1.date }
        let tokens = LibrarySearch.tokens(appliedQuery)
        guard !tokens.isEmpty else { return sorted.map { LibraryItem(record: $0, snippet: nil) } }
        return sorted.compactMap { record in
            if LibrarySearch.matches(normalizedHaystack: LibrarySearch.normalize(record.displayTitle),
                                     tokens: tokens) {
                return LibraryItem(record: record, snippet: nil)
            }
            // Совпало имя исходного файла (у записи свой заголовок или совпало
            // расширение) — показываем его, иначе строка в выдаче без причины.
            if LibrarySearch.matches(normalizedHaystack: LibrarySearch.normalize(record.fileName),
                                     tokens: tokens) {
                return LibraryItem(record: record, snippet: record.fileName)
            }
            guard let snippet = textMatches[record.id] else { return nil }
            return LibraryItem(record: record, snippet: snippet)
        }
    }

    private func apply(query: String) {
        guard query != appliedQuery else { return }
        appliedQuery = query
        // Сниппеты прошлого запроса к новому не относятся.
        textMatches = [:]
        refreshTextSearch()
    }

    /// Поиск по текстам — в фоне (актор индекса), предыдущий бросается.
    private func refreshTextSearch() {
        searchTask?.cancel()
        let query = appliedQuery
        guard !LibrarySearch.tokens(query).isEmpty else {
            textMatches = [:]
            isSearchingText = false
            return
        }
        isSearchingText = true
        let store = store
        searchTask = Task { [weak self] in
            let found = await store.searchFullText(query)
            guard !Task.isCancelled, let self else { return }
            self.textMatches = found
            self.isSearchingText = false
        }
    }

    private func recordsDidChange(_ records: [FileTranscriptRecord]) {
        let ids = Set(records.map(\.id))
        if !selection.isSubset(of: ids) { selection.formIntersection(ids) }
        if let renaming = renamingID, !ids.contains(renaming) { renamingID = nil }
        // Открытую запись удалили мимо детали (срок хранения в «Расширенных») —
        // возвращаемся к списку, а не держим экран «запись не найдена».
        if let opened = openedRecordID, !ids.contains(opened) { close() }
        // Готовых записей стало больше/меньше — их тексты могли совпасть с запросом.
        let done = Set(records.filter(\.isDone).map(\.id))
        if done != doneIDs {
            doneIDs = done
            refreshTextSearch()
        }
    }

    // MARK: - Экспорт выбранных

    /// Выбранные записи в порядке списка (свежие сверху).
    private var selectedRecords: [FileTranscriptRecord] {
        store.records.filter { selection.contains($0.id) }.sorted { $0.date > $1.date }
    }

    /// Один файл на все выбранные записи: раздел на запись, текст по спикерам
    /// (если они есть) или с тайм-кодами.
    func exportCombined(markdown: Bool) {
        let records = selectedRecords
        guard !records.isEmpty else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = markdown ? "DOKA-library.md" : "DOKA-library.txt"
        panel.canCreateDirectories = true
        if !markdown { panel.allowedContentTypes = [.plainText] }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            var entries: [LibraryExport.Entry] = []
            for record in records {
                guard let result = await exportResult(record) else { continue }
                let text = result.hasSpeakers
                    ? TranscriptFormatter.bySpeaker(result)
                    : TranscriptFormatter.textWithTimestamps(result)
                entries.append(LibraryExport.Entry(title: record.displayTitle,
                                                   meta: record.metaLine, text: text))
            }
            let content = markdown
                ? LibraryExport.combinedMarkdown(entries)
                : LibraryExport.combinedPlainText(entries)
            // Пустой файл не пишем: ни одной готовой записи среди выбранных.
            let written = !entries.isEmpty && TextFileSaver.write(content, to: url)
            showExportNote(exported: written ? entries.count : 0,
                           skipped: records.count - (written ? entries.count : 0))
        }
    }

    /// По файлу на запись в выбранную папку; имена — из заголовков, без
    /// затирания уже лежащих там файлов.
    func exportToFolder(_ format: SaveFormat) {
        let records = selectedRecords
        guard !records.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = L("library.export.folderPrompt")
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        Task {
            let existing = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            var taken = Set(existing.map { $0.lowercased() })
            var exported = 0
            for record in records {
                guard let result = await exportResult(record) else { continue }
                let name = LibraryExport.uniqueName(base: record.exportBaseName,
                                                    ext: format.fileExtension, taken: &taken)
                if TextFileSaver.write(format.text(for: result), to: folder.appendingPathComponent(name)) {
                    exported += 1
                }
            }
            showExportNote(exported: exported, skipped: records.count - exported)
        }
    }

    /// Результат записи для экспорта — тем же выходным слоем, что показ:
    /// текущая детализация и словарь для файлов, если он включён. Записи
    /// без результата (в процессе, ошибка, отмена) пропускаются.
    private func exportResult(_ record: FileTranscriptRecord) async -> TranscriptResult? {
        guard record.isDone, let body = await store.loadBody(record.id) else { return nil }
        return TranscriptOutput.prepare(body.makeResult(detail: detail))
    }

    private func showExportNote(exported: Int, skipped: Int) {
        exportNote = L("library.export.result", exported, skipped)
        noteTask?.cancel()
        noteTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.exportNote = nil
        }
    }
}

/// Строка списка: запись и (при поиске по тексту) фрагмент совпадения.
struct LibraryItem: Identifiable {
    let record: FileTranscriptRecord
    let snippet: String?

    var id: UUID { record.id }
}

/// Открыть запись библиотеки из любого места приложения.
@MainActor
enum LibraryNavigator {
    static func open(_ recordID: UUID) {
        WindowManager.shared.showLibrary(recordID: recordID)
    }

    static func showList() {
        WindowManager.shared.showLibrary(recordID: nil)
    }
}
