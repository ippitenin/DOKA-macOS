import Foundation
import WhisperKit
import FluidAudio

/// Скачивание и состояние локальных ресурсов (речевые модели, диаризатор,
/// языковая модель ИИ-анализа).
/// Всё живёт в ФИКСИРОВАННОЙ папке `Application Support/DOKA/Models`
/// (`AppDataFolder.modelsURL`) и НЕ переезжает вместе с «Папкой данных»:
/// это перекачиваемый кеш, а не данные пользователя — перенос 1.5+ ГБ сделал
/// бы миграцию папки блокирующей.
@MainActor
final class LocalModelStore: ObservableObject {
    static let shared = LocalModelStore()

    enum ModelState: Equatable {
        case notDownloaded
        case downloading(Double)   // прогресс 0…1
        case preparing             // прогрев: первая CoreML-компиляция под чип
        case ready(Int64)          // размер на диске в байтах
        case failed(String)
    }

    @Published private(set) var states: [LocalAsset: ModelState] = [:]

    private var downloadTasks: [LocalAsset: Task<Void, Never>] = [:]

    /// Последний известный размер ресурса на диске; считается фоном
    /// (`refreshSize`), до готовности показывается примерный размер скачивания.
    private var knownSizes: [LocalAsset: Int64] = [:]

    private init() {
        for asset in LocalAsset.allCases {
            if Self.isOnDisk(asset) {
                states[asset] = .ready(readySize(asset))
                refreshSize(asset)
            } else {
                states[asset] = .notDownloaded
            }
        }
        // Осиротевшие папки незавершённого фонового удаления (kill приложения
        // во время стирания модели) и огрызки прерванной закачки языковой
        // модели — подчищаем, они только занимают диск. Заодно удаляется файл
        // ПРОШЛОЙ языковой модели, если `LLMModelSpec.current` сменилась.
        Task.detached(priority: .utility) {
            Self.sweepDeleteLeftovers()
            Self.sweepLLMFolder()
        }
    }

    // MARK: - Пути

    /// База скачивания WhisperKit; HubApi раскладывает внутрь по схеме
    /// `models/<владелец>/<репозиторий>/<вариант>`.
    nonisolated static let whisperBase = AppDataFolder.modelsURL
        .appendingPathComponent("whisper", isDirectory: true)

    /// Итоговая папка модели Whisper (файлы .mlmodelc + config).
    nonisolated static let whisperModelFolder = whisperBase
        .appendingPathComponent("models/argmaxinc/whisperkit-coreml", isDirectory: true)
        .appendingPathComponent(LocalModel.whisperKitVariant, isDirectory: true)

    /// Папка моделей Parakeet. Имя — НЕ произвольное: FluidAudio срезает у
    /// переданного пути последний компонент и приписывает имя репозитория
    /// (и в `download`, и в `load`, и в `modelsExist`), поэтому файлы всё
    /// равно оказываются в `Models/parakeet-tdt-0.6b-v3`. Пока константа
    /// указывала на `Models/parakeet`, подсчёт размера давал 0, а удаление
    /// модели было no-op — папки с таким именем на диске не существует.
    nonisolated static let parakeetFolder = AppDataFolder.modelsURL
        .appendingPathComponent("parakeet-tdt-0.6b-v3", isDirectory: true)

    /// Папка диаризатора. Здесь наоборот: `OfflineDiarizerModels.load`
    /// передаёт путь в ModelHub как есть, и тот создаёт внутри подпапку
    /// репозитория — см. `diarizerModelFolder`.
    nonisolated static let diarizerFolder = AppDataFolder.modelsURL
        .appendingPathComponent("diarizer", isDirectory: true)

    /// Фактическая папка с файлами диаризатора (проверено стендом).
    nonisolated static let diarizerModelFolder = diarizerFolder
        .appendingPathComponent("speaker-diarization", isDirectory: true)

    /// Папка языковой модели анализа. Скачиваем её сами (`HTTPModelDownloader`),
    /// поэтому раскладка простая: один GGUF-файл по имени из спеки.
    nonisolated static let llmFolder = AppDataFolder.modelsURL
        .appendingPathComponent("llm", isDirectory: true)

    nonisolated static var llmFile: URL {
        llmFolder.appendingPathComponent(LLMModelSpec.current.fileName)
    }

    private nonisolated static func rootFolder(for asset: LocalAsset) -> URL {
        switch asset {
        case .speech(.whisper): return whisperBase
        case .speech(.parakeet): return parakeetFolder
        case .diarizer: return diarizerFolder
        case .llm: return llmFolder
        }
    }

    // MARK: - Состояние

    /// Файлы ресурса на месте (независимо от того, загружен ли он в память).
    func isDownloaded(_ asset: LocalAsset) -> Bool {
        switch states[asset] {
        case .ready, .preparing: return true
        default: return false
        }
    }

    func isDownloaded(_ model: LocalModel) -> Bool { isDownloaded(.speech(model)) }

    func state(for asset: LocalAsset) -> ModelState {
        states[asset] ?? .notDownloaded
    }

    func state(for model: LocalModel) -> ModelState { state(for: .speech(model)) }

    /// Проверка файлов на диске (без обращения к состоянию в памяти).
    private static func isOnDisk(_ asset: LocalAsset) -> Bool {
        let fm = FileManager.default
        switch asset {
        case .speech(.whisper):
            // Ключевые компоненты варианта; частично скачанная папка не считается.
            return fm.fileExists(atPath: whisperModelFolder.appendingPathComponent("AudioEncoder.mlmodelc").path)
                && fm.fileExists(atPath: whisperModelFolder.appendingPathComponent("TextDecoder.mlmodelc").path)
        case .speech(.parakeet):
            return AsrModels.modelsExist(at: parakeetFolder, version: .v3)
        case .diarizer:
            // Свой аналог `modelsExist` — у офлайнового диаризатора такого API нет.
            return diarizerRequiredFiles.allSatisfy {
                fm.fileExists(atPath: diarizerModelFolder.appendingPathComponent($0).path)
            }
        case .llm:
            // Дешёвый stat: хэш проверен при установке, пересчитывать 2.5 ГБ
            // на каждом запуске нельзя. Размер отсекает огрызок с чужим именем.
            let size = ((try? fm.attributesOfItem(atPath: llmFile.path)[.size]) as? NSNumber)?.int64Value
            return size == LLMModelSpec.current.bytes
        }
    }

    /// Состав офлайнового диаризатора (VBx): четыре модели + параметры PLDA.
    private nonisolated static let diarizerRequiredFiles = [
        ModelNames.OfflineDiarizer.segmentationFile,
        ModelNames.OfflineDiarizer.fbankFile,
        ModelNames.OfflineDiarizer.embeddingFile,
        ModelNames.OfflineDiarizer.pldaRhoFile,
        ModelNames.OfflineDiarizer.pldaParameters
    ]

    /// Размер для состояния `.ready`: последний посчитанный, до него — оценка.
    private func readySize(_ asset: LocalAsset) -> Int64 {
        knownSizes[asset] ?? asset.approxDownloadBytes
    }

    /// Пересчитывает размер ресурса фоновым обходом папки: рекурсивный stat
    /// многогигабайтного дерева на главном потоке блокировал бы запуск
    /// приложения (первое обращение к синглтону — в `applicationDidFinishLaunching`).
    private func refreshSize(_ asset: LocalAsset) {
        Task.detached(priority: .utility) {
            let size = Self.sizeOnDisk(asset)
            await MainActor.run {
                let store = LocalModelStore.shared
                store.knownSizes[asset] = size
                if case .ready = store.state(for: asset) {
                    store.states[asset] = .ready(size)
                }
            }
        }
    }

    private nonisolated static func sizeOnDisk(_ asset: LocalAsset) -> Int64 {
        directorySize(rootFolder(for: asset))
    }

    private nonisolated static func directorySize(_ url: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: url,
                                             includingPropertiesForKeys: [.totalFileAllocatedSizeKey],
                                             options: [.skipsHiddenFiles]) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let size = (try? fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?
                .totalFileAllocatedSize ?? 0
            total += Int64(size)
        }
        return total
    }

    // MARK: - Скачивание

    /// Прогресс-синк для Sendable-колбэков SDK: пропускает на главный актёр
    /// только смену целого процента — URLSession шлёт колбэки на каждый чанк,
    /// и без квантования перерисовка SwiftUI дёргалась бы сотни раз в секунду.
    /// Синглтон напрямую, без захвата слабого self из внешней задачи.
    private final class ProgressSink: @unchecked Sendable {
        private let asset: LocalAsset
        private let lock = NSLock()
        private var lastPercent = -1

        init(asset: LocalAsset) { self.asset = asset }

        /// Вход — уже извлечённая дробь: у WhisperKit прогресс `Foundation.Progress`,
        /// у FluidAudio — собственный `DownloadProgress`, общего типа нет.
        /// Прогресс не пятится: диаризатор грузит модели двумя проходами
        /// (разные compute units у FBank), и вторая шкала снова стартует с середины.
        func report(fraction: Double) {
            let percent = Int(fraction * 100)
            lock.lock()
            let changed = percent > lastPercent
            if changed { lastPercent = percent }
            lock.unlock()
            guard changed else { return }
            Task { @MainActor [asset] in
                LocalModelStore.shared.updateProgress(asset, fraction)
            }
        }
    }

    func download(_ model: LocalModel) { download(.speech(model)) }

    func download(_ asset: LocalAsset) {
        // Барьер платформы здесь, а не только в `.disabled` кнопки: любой
        // другой путь к скачиванию не должен качать неподдерживаемую модель.
        guard !asset.requiresAppleSilicon || LocalModel.isAppleSiliconMac else {
            states[asset] = .failed(L("service.local.intelUnsupported"))
            return
        }
        if case .downloading = state(for: asset) { return }
        states[asset] = .downloading(0)

        let task = Task { [weak self] in
            do {
                let sink = ProgressSink(asset: asset)
                switch asset {
                case .speech(.whisper):
                    _ = try await WhisperKit.download(
                        variant: LocalModel.whisperKitVariant,
                        downloadBase: Self.whisperBase,
                        progressCallback: { sink.report(fraction: $0.fractionCompleted) }
                    )
                case .speech(.parakeet):
                    _ = try await AsrModels.download(
                        to: Self.parakeetFolder,
                        progressHandler: { sink.report(fraction: $0.fractionCompleted) }
                    )
                case .diarizer:
                    // У офлайнового диаризатора скачивание и загрузка — один
                    // вызов; загруженные модели тут не нужны, их возьмёт прогрев.
                    _ = try await OfflineDiarizerModels.load(
                        from: Self.diarizerFolder,
                        progressHandler: { sink.report(fraction: $0.fractionCompleted) }
                    )
                case .llm:
                    let spec = LLMModelSpec.current
                    try Self.checkFreeSpace(for: spec.bytes)
                    try await HTTPModelDownloader.download(
                        .init(url: spec.url, expectedBytes: spec.bytes,
                              sha256: spec.sha256, destination: Self.llmFile),
                        progress: { sink.report(fraction: $0) }
                    )
                }
                try Task.checkCancellation()
                self?.finishDownload(asset)
            } catch {
                // SDK может обернуть отмену в свою ошибку — ловим оба вида.
                if error is CancellationError || Task.isCancelled {
                    self?.cleanupAfterCancel(asset)
                } else {
                    NSLog("DOKA: скачивание \(asset.logName) не удалось: \(error.localizedDescription)")
                    Self.removePartial(asset)
                    self?.states[asset] = .failed(error.localizedDescription)
                }
            }
            self?.downloadTasks[asset] = nil
        }
        downloadTasks[asset] = task
    }

    func cancelDownload(_ model: LocalModel) { cancelDownload(.speech(model)) }

    func cancelDownload(_ asset: LocalAsset) {
        downloadTasks[asset]?.cancel()
    }

    private func updateProgress(_ asset: LocalAsset, _ fraction: Double) {
        // Не перетираем финальные состояния запоздавшим колбэком.
        if case .downloading = state(for: asset) {
            states[asset] = .downloading(min(max(fraction, 0), 1))
        }
    }

    private func finishDownload(_ asset: LocalAsset) {
        guard Self.isOnDisk(asset) else {
            Self.removePartial(asset)
            states[asset] = .failed(L("service.local.downloadIncomplete"))
            return
        }
        states[asset] = .ready(readySize(asset))
        refreshSize(asset)
        // Прогрев сразу после скачивания: первая CoreML-компиляция под чип
        // уходит в статус «Подготовка модели…», а не в первую диктовку.
        switch asset {
        case .speech(let model):
            Task { await LocalEngineManager.shared.prewarm(model) }
        case .diarizer:
            Task { await LocalEngineManager.shared.prewarmDiarizer() }
        case .llm:
            // Без прогрева: тащить 2.5 ГБ в ОЗУ сразу после скачивания незачем,
            // Metal-кернелы компилируются при первой загрузке за секунды —
            // они уйдут в статус «Подготовка…» первого анализа.
            break
        }
    }

    private func cleanupAfterCancel(_ asset: LocalAsset) {
        // Частично скачанные файлы убираем, чтобы не притворялись готовой моделью.
        Self.removePartial(asset)
        knownSizes[asset] = nil
        states[asset] = .notDownloaded
    }

    /// Убирает папку ресурса с диска: мгновенное переименование на том же томе
    /// плюс фоновое удаление — синхронное стирание многогигабайтного дерева
    /// на главном потоке замораживало бы UI ровно в момент клика.
    private static func removePartial(_ asset: LocalAsset) {
        let fm = FileManager.default
        let folder = rootFolder(for: asset)
        guard fm.fileExists(atPath: folder.path) else { return }
        let trash = folder.deletingLastPathComponent()
            .appendingPathComponent("\(folder.lastPathComponent).deleting-\(UUID().uuidString)")
        do {
            try fm.moveItem(at: folder, to: trash)
            Task.detached(priority: .utility) {
                try? FileManager.default.removeItem(at: trash)
            }
        } catch {
            // Переименование не удалось — удаляем на месте (редкий путь).
            try? fm.removeItem(at: folder)
        }
    }

    /// Свободного места должно хватить на файл плюс запас: скачивание
    /// «под завязку» оставило бы систему без места под своп и кэши.
    private static func checkFreeSpace(for bytes: Int64) throws {
        let folder = AppDataFolder.modelsURL
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let free = (try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
        // Тома, не отдающие ёмкость, не блокируем — закачка упадёт сама.
        guard let free else { return }
        let needed = bytes + 1_000_000_000
        guard free < needed else { return }
        throw LocalAssetError.notEnoughSpace(
            needed: ByteCountFormatter.string(fromByteCount: needed, countStyle: .file))
    }

    /// В папке языковой модели остаётся ровно текущая модель: огрызки
    /// прерванной закачки и файл прошлой `LLMModelSpec.current` — мусор
    /// на гигабайты.
    private nonisolated static func sweepLLMFolder() {
        let fm = FileManager.default
        // Порог — момент запуска: то, что появилось уже в этой сессии, трогать
        // нельзя (пользователь мог нажать «Скачать» раньше, чем дошла очередь
        // до фонового sweep).
        let launched = Date(timeIntervalSinceNow: -ProcessInfo.processInfo.systemUptime)
        let cutoff = max(launched, Date(timeIntervalSinceNow: -Self.sweepGrace))
        HTTPModelDownloader.sweepLeftovers(in: llmFolder, newerThan: cutoff)
        guard let items = try? fm.contentsOfDirectory(atPath: llmFolder.path) else { return }
        let keep = LLMModelSpec.current.fileName
        for name in items where name != keep && !name.hasPrefix(".") {
            let url = llmFolder.appendingPathComponent(name)
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            guard let modified, modified < cutoff else { continue }
            try? fm.removeItem(at: url)
        }
    }

    /// Сколько времени от старта считаем «своей» сессией, если аптайм системы
    /// меньше (Mac только что загрузился): файл свежее этого порога не трогаем.
    private nonisolated static let sweepGrace: TimeInterval = 5 * 60

    /// Осиротевшие папки `*.deleting-*` после kill во время фонового удаления.
    private nonisolated static func sweepDeleteLeftovers() {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: AppDataFolder.modelsURL.path) else { return }
        for name in items where name.contains(".deleting-") {
            try? fm.removeItem(at: AppDataFolder.modelsURL.appendingPathComponent(name))
        }
    }

    // MARK: - Прогрев и удаление

    func markPreparing(_ model: LocalModel, _ preparing: Bool) {
        markPreparing(.speech(model), preparing)
    }

    /// Переводит ресурс в «Подготовка…» на время первой CoreML-компиляции
    /// (вызывается менеджером движков), затем обратно в «Готова».
    func markPreparing(_ asset: LocalAsset, _ preparing: Bool) {
        if preparing {
            if case .ready = state(for: asset) { states[asset] = .preparing }
        } else if case .preparing = state(for: asset) {
            // Размер известен с прошлого `.ready` — файлы между «Готова» и
            // «Подготовка…» не менялись, пересчёт папки не нужен.
            states[asset] = .ready(readySize(asset))
        }
    }

    func delete(_ model: LocalModel) { delete(.speech(model)) }

    func delete(_ asset: LocalAsset) {
        cancelDownload(asset)
        switch asset {
        case .speech(let model): LocalEngineManager.shared.unloadIfCurrent(model)
        case .diarizer: LocalEngineManager.shared.unloadDiarizer()
        case .llm:
            // Сначала остановить анализ: он держит модель в памяти, а
            // переименование папки из-под живого mmap оставило бы его без
            // файла на следующем обращении.
            AnalysisController.shared.cancelIfRunning()
            LocalEngineManager.shared.unloadLLM()
        }
        Self.removePartial(asset)
        knownSizes[asset] = nil
        states[asset] = .notDownloaded
    }
}
