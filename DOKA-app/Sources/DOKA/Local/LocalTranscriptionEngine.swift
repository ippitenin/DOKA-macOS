import Foundation

/// Результат локальной файловой транскрипции до маппинга в `TranscriptResult`:
/// сегменты и слова в типах DOKA, чтобы работали перенарезка детализации
/// (`TranscriptSegmentSplitter`) и все экспорты (`TranscriptFormatter`).
struct LocalFileTranscription {
    let fullText: String
    let language: String?
    let segments: [TranscriptSegment]
    let words: [TranscriptWord]
}

/// Движок локальной транскрипции: загруженная в память модель одного типа.
/// Реализации держат тяжёлые CoreML-объекты; создание дешёвое, `load()` —
/// дорогая (первый раз — CoreML-компиляция под чип, минуты).
@MainActor
protocol LocalTranscriptionEngine: AnyObject {
    var model: LocalModel { get }
    func load() async throws
    /// Диктовка: WAV 16 кГц mono → чистый текст. Кооперативная отмена —
    /// результат отменённой задачи никому не нужен.
    func transcribeDictation(wavURL: URL, language: String?) async throws -> String
    /// Файловая транскрибация: WAV 16 кГц mono (после `AudioFileDecoder`) →
    /// сегменты с тайм-кодами и слова.
    func transcribeFile(wavURL: URL, language: String?) async throws -> LocalFileTranscription
    func unload()
}

enum LocalEngineError: LocalizedError {
    case modelMissing
    case loadFailed(String)

    var errorDescription: String? {
        switch self {
        case .modelMissing: return L("error.localModelMissing")
        case .loadFailed(let reason): return L("error.localLoadFailed", reason)
        }
    }
}

/// Владелец загруженного движка: один на приложение, ленивая загрузка,
/// выгрузка после простоя (модель держит ~2 ГБ ОЗУ). Повторные диктовки в
/// окне простоя — мгновенные, без повторной загрузки с диска.
@MainActor
final class LocalEngineManager {
    static let shared = LocalEngineManager()

    /// Пауза простоя до выгрузки модели из памяти.
    static let idleUnloadDelay: Duration = .seconds(5 * 60)

    private var engine: LocalTranscriptionEngine?
    /// Идущая загрузка: модель и её задача меняются только вместе.
    private var loading: (model: LocalModel, task: Task<LocalTranscriptionEngine, Error>)?
    private var idleTask: Task<Void, Never>?

    /// Диаризатор живёт РЯДОМ с речевым движком, а не вместо него: разделение
    /// по спикерам идёт следом за распознаванием того же файла.
    private var diarizerEngine: LocalDiarizer?
    private var diarizerLoading: Task<LocalDiarizer, Error>?

    /// Языковая модель анализа — со своим таймером простоя и НЕ в
    /// `unloadNow()`: её выгрузка не должна быть побочным эффектом смены
    /// сервиса распознавания или начала диктовки (см. `llmEngine`).
    private var llm: LocalLLMEngine?
    private var llmLoading: Task<LocalLLMEngine, Error>?
    private var llmIdleTask: Task<Void, Never>?
    /// Сколько операций сейчас ДЕРЖАТ языковую модель. Таймер простоя
    /// отсчитывается только при нуле: анализ длинной записи идёт много
    /// проходов подряд, и без аренды выгрузка срабатывала бы посреди него —
    /// следующий проход упал бы с «модель не загружена».
    private var llmUseCount = 0

    /// Языковая модель держит 3–5 ГБ ОЗУ — окно простоя короче, чем у речи.
    static let llmIdleUnloadDelay: Duration = .seconds(3 * 60)

    private init() {}

    /// Возвращает готовый движок, при необходимости загружая модель.
    /// Повторный вызов во время загрузки (прогрев + диктовка) ждёт ту же задачу.
    func engine(for model: LocalModel) async throws -> LocalTranscriptionEngine {
        if let engine, engine.model == model {
            touch()
            return engine
        }
        if let loading, loading.model == model {
            let shared = try await loading.task.value
            touch()
            return shared
        }
        unloadNow()
        guard LocalModelStore.shared.isDownloaded(model) else {
            throw LocalEngineError.modelMissing
        }

        let task = Task<LocalTranscriptionEngine, Error> {
            let newEngine: LocalTranscriptionEngine
            switch model {
            case .whisper: newEngine = WhisperLocalEngine()
            case .parakeet: newEngine = ParakeetLocalEngine()
            }
            // Статус «Подготовка модели…» на время загрузки/компиляции.
            LocalModelStore.shared.markPreparing(model, true)
            defer { LocalModelStore.shared.markPreparing(model, false) }
            do {
                try await newEngine.load()
            } catch {
                throw LocalEngineError.loadFailed(error.localizedDescription)
            }
            return newEngine
        }
        loading = (model, task)
        // Снимаем регистрацию ТОЛЬКО свою: безусловный `loading = nil` затирал
        // запись другого запроса (пользователь сменил модель, пока шла
        // загрузка), и следующий вызов грузил ту же модель второй раз.
        defer { if loading?.task == task { loading = nil } }
        let newEngine = try await task.value
        // Пока грузились, слот мог занять другой запрос или его могли
        // освободить (удаление модели, смена сервиса). Поставить движок сейчас
        // значило бы держать в памяти 1,6 ГБ модели, которую уже никто не ждёт,
        // — в том числе модели, файлы которой уже удалены с диска. Отмена
        // задачи от этого не спасает: у `load()` WhisperKit и FluidAudio
        // кооперативных точек отмены нет, она доходит до конца.
        guard loading?.task == task else {
            newEngine.unload()
            throw CancellationError()
        }
        engine = newEngine
        touch()
        return newEngine
    }

    /// Прогрев сразу после скачивания: первая CoreML-компиляция под чип
    /// занимает минуты — прячем её за статусом «Подготовка модели…», чтобы
    /// первая диктовка не выглядела зависанием. Заодно WhisperKit кэширует
    /// токенайзер с HuggingFace (сеть нужна один раз — сразу после
    /// скачивания она точно есть).
    func prewarm(_ model: LocalModel) async {
        _ = try? await engine(for: model)
    }

    /// Готовый диаризатор, при необходимости загружая модели. Параллельные
    /// вызовы (прогрев после скачивания + запуск транскрибации) ждут одну задачу.
    func diarizer() async throws -> LocalDiarizer {
        if let diarizerEngine, diarizerEngine.isLoaded {
            touch()
            return diarizerEngine
        }
        if let diarizerLoading {
            let shared = try await diarizerLoading.value
            touch()
            return shared
        }
        guard LocalModelStore.shared.isDownloaded(.diarizer) else {
            throw LocalEngineError.modelMissing
        }

        let task = Task<LocalDiarizer, Error> {
            let engine = LocalDiarizer()
            LocalModelStore.shared.markPreparing(.diarizer, true)
            defer { LocalModelStore.shared.markPreparing(.diarizer, false) }
            do {
                try await engine.load()
            } catch {
                throw LocalEngineError.loadFailed(error.localizedDescription)
            }
            return engine
        }
        diarizerLoading = task
        defer { if diarizerLoading == task { diarizerLoading = nil } }
        let engine = try await task.value
        guard diarizerLoading == task else {
            engine.unload()
            throw CancellationError()
        }
        diarizerEngine = engine
        touch()
        return engine
    }

    func prewarmDiarizer() async {
        _ = try? await diarizer()
    }

    // MARK: - Языковая модель анализа

    /// Готовая языковая модель; при необходимости грузит её. Параллельные
    /// вызовы ждут одну задачу — как у речевого движка и диаризатора.
    func llmEngine() async throws -> LocalLLMEngine {
        if let llm, await llm.isLoaded {
            touchLLM()
            return llm
        }
        if let llmLoading {
            let shared = try await llmLoading.value
            touchLLM()
            return shared
        }
        guard LocalModelStore.shared.isDownloaded(.llm) else {
            throw LocalEngineError.modelMissing
        }
        // На маке с 8 ГБ языковая модель и речевая вместе уводят систему
        // в своп: освобождаем распознавание заранее, оно перезагрузится
        // к следующей диктовке.
        if LLMModelSpec.isLowMemoryMac { unloadNow() }

        let task = Task<LocalLLMEngine, Error> {
            let engine = LocalLLMEngine()
            // «Подготовка модели…»: первая загрузка компилирует встроенные
            // Metal-кернелы (около 12 секунд), и без статуса это выглядело бы
            // зависанием кнопки «Проанализировать».
            LocalModelStore.shared.markPreparing(.llm, true)
            defer { LocalModelStore.shared.markPreparing(.llm, false) }
            do {
                try await engine.load()
            } catch let error as LLMError {
                throw error
            } catch {
                throw LocalEngineError.loadFailed(error.localizedDescription)
            }
            return engine
        }
        llmLoading = task
        defer { if llmLoading == task { llmLoading = nil } }
        let engine = try await task.value
        // Пока шла загрузка, модель могли удалить: `unloadLLM` отменяет
        // задачу, но у `load()` кооперативных точек отмены нет — она доходит
        // до конца. Установить движок сейчас значило бы держать в памяти
        // 2,5 ГБ весов и mmap уже удалённого файла.
        guard llmLoading == task else {
            await engine.unload()
            throw CancellationError()
        }
        llm = engine
        touchLLM()
        return engine
    }

    /// Взять модель в работу: пока аренда не отдана, таймер простоя молчит.
    /// Парный вызов `endLLMUse()` обязателен — ставить его в `defer`.
    func beginLLMUse() {
        llmUseCount += 1
        llmIdleTask?.cancel()
        llmIdleTask = nil
    }

    func endLLMUse() {
        llmUseCount = max(0, llmUseCount - 1)
        if llmUseCount == 0 { touchLLM() }
    }

    /// Продлевает окно простоя языковой модели. Таймер отдельный: диктовка
    /// не должна держать модель анализа в памяти, а анализ — речевую.
    func touchLLM() {
        llmIdleTask?.cancel()
        // Пока модель в работе, окно простоя не запускаем вовсе: его перезапустит
        // `endLLMUse()`.
        guard llmUseCount == 0 else { llmIdleTask = nil; return }
        llmIdleTask = Task { [weak self] in
            try? await Task.sleep(for: Self.llmIdleUnloadDelay)
            guard !Task.isCancelled else { return }
            self?.unloadLLM()
        }
    }

    func unloadLLM() {
        llmIdleTask?.cancel()
        llmIdleTask = nil
        llmUseCount = 0
        llmLoading?.cancel()
        llmLoading = nil
        // Выгрузка идёт на исполнителе актора: если генерация ещё идёт, она
        // отработает до конца, и только потом освободятся указатели.
        if let llm {
            Task { await llm.unload() }
            self.llm = nil
        }
    }

    /// Языковая модель загружена в память (для политики «диктовка важнее»).
    var isLLMLoaded: Bool { llm != nil || llmLoading != nil }

    func unloadDiarizer() {
        // Как `unloadLLM`: отменяем и НЕЗАВЕРШЁННУЮ загрузку, иначе она
        // доедет и поставит модели, которых на диске уже нет.
        diarizerLoading?.cancel()
        diarizerLoading = nil
        diarizerEngine?.unload()
        diarizerEngine = nil
    }

    /// Продлевает окно простоя; вызывать после каждого использования движка.
    func touch() {
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: Self.idleUnloadDelay)
            guard !Task.isCancelled else { return }
            self?.unloadNow()
        }
    }

    func unloadNow() {
        idleTask?.cancel()
        idleTask = nil
        loading?.task.cancel()
        loading = nil
        engine?.unload()
        engine = nil
        unloadDiarizer()
    }

    /// Выгрузка, если слот ЗАНЯТ этой моделью — загруженной либо загружаемой.
    /// Проверять только `engine` нельзя: во время загрузки он ещё nil, и
    /// удаление модели в этот момент оказывалось no-op — задача доезжала и
    /// ставила движок для модели, помеченной «не скачана», держа её в памяти.
    func unloadIfCurrent(_ model: LocalModel) {
        if engine?.model == model || loading?.model == model { unloadNow() }
    }
}
