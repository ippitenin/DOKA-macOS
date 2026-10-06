import Foundation

/// Параметры семплинга генерации. Отдельным типом, чтобы спека модели и
/// движок не расходились: у каждой модели свои рекомендованные значения.
struct LLMSampling: Sendable, Equatable {
    var temperature: Float
    var topK: Int32
    var topP: Float
    var minP: Float
    var repeatPenalty: Float
    var repeatLastN: Int32
    /// Фиксированное зерно: один и тот же вход даёт один и тот же отчёт —
    /// «Повторить» без правок не должно выдавать другой текст.
    var seed: UInt32
}

/// Языковая модель локального анализа. ЕДИНСТВЕННЫЙ источник ссылки, размера,
/// хэша и параметров генерации: смена модели — это смена `current` (файл
/// прошлой модели подчистит sweep в `LocalModelStore`).
///
/// Модель не является сервисом распознавания: в `LocalModel` её нет, значит
/// в пикер «Сервис» и в `SettingsStore.providerID` она не попадает (см.
/// `LocalAsset.llm`).
struct LLMModelSpec: Sendable, Equatable {
    /// Идентификатор для `StoredAnalysis.Source.local(modelID:)` — по нему
    /// видно, какой моделью сделан анализ, даже после смены `current`.
    let id: String
    /// Имя собственное — не локализуется (как `LocalModel.title`).
    let displayName: String
    let fileName: String
    /// Пин РЕВИЗИИ репозитория, а не `main`: содержимое `main` меняется, и
    /// хэш перестал бы сходиться.
    let url: URL
    let bytes: Int64
    let sha256: String
    /// Потолок окна контекста; фактическое `n_ctx` ограничивается ещё и
    /// обученным окном модели и доступной ОЗУ (см. `contextLimit`).
    let maxContext: Int
    /// Префилл ответа ассистента. У гибридных thinking-моделей (Qwen3.5)
    /// пустой блок `<think></think>` выключает размышления: иначе модель
    /// тратит минуты и сотни токенов на рассуждения, которые мы всё равно
    /// вырезаем.
    let assistantPrefill: String?
    let sampling: LLMSampling

    /// Текущая модель анализа. Выбрана спайком Ф0: против Qwen3-4B-Instruct-2507
    /// даёт полнее список задач при сопоставимой скорости, а гибридное внимание
    /// (Gated DeltaNet) делает KV-кэш в 4.5 раза меньше.
    static let qwen35_4b = LLMModelSpec(
        id: "qwen3.5-4b-q4km",
        displayName: "Qwen3.5 4B",
        fileName: "Qwen3.5-4B-Q4_K_M.gguf",
        url: URL(string: "https://huggingface.co/lmstudio-community/Qwen3.5-4B-GGUF/resolve/"
                 + "f9f88ac3e234be915e23811a6d28ea287bdb927e/Qwen3.5-4B-Q4_K_M.gguf")!,
        bytes: 2_707_513_696,
        sha256: "25082a7dd3776cc3c741c6347d3bd04523f05796607b3fbc32fa3a25dfa1418c",
        // 32k на маках с 16+ ГБ — замер 5.10.2026 (M5 Pro, окно 16k → 32k):
        // +0,5 ГиБ ровно на KV (32 КиБ на токен), резидентно с весами 3,3 →
        // 3,8 ГиБ, разбор ~1 250–1 550 ток/с. Одним проходом теперь идут
        // записи до ~1 ч 50 мин (~277 ток/мин русской речи); на склейке в
        // 84 мин один проход вышел быстрее частей (37 против 47 с) и заметно
        // полнее: в частях пропали решения и задачи, появились выдуманные
        // участники.
        maxContext: 32768,
        assistantPrefill: "<think>\n\n</think>\n\n",
        sampling: LLMSampling(temperature: 0.3, topK: 20, topP: 0.8, minP: 0,
                              repeatPenalty: 1.05, repeatLastN: 256, seed: 0xD0CA)
    )

    static let current: LLMModelSpec = .qwen35_4b

    /// Окно контекста на маке с малой ОЗУ. Порог 8k ставили по цифрам прошлой
    /// модели (Qwen3-4B-2507: 5 ГиБ при 16k); у Qwen3.5 16k стоило бы лишь
    /// +0,25 ГиБ (~3,3 ГиБ резидентно против ~3,05), но на живом 8-ГБ маке
    /// это не проверено — до такой проверки окно не поднимаем, длинные записи
    /// там идут через map-reduce.
    static let lowMemoryContext = 8192
    /// Порог «много памяти»: 16 ГБ по спецификации = 16 ГиБ физической памяти,
    /// сравниваем с запасом вниз.
    static let highMemoryBytes: UInt64 = 15 * 1024 * 1024 * 1024

    /// Мало памяти — на таком маке анализ соревнуется с системой за ОЗУ.
    static var isLowMemoryMac: Bool {
        ProcessInfo.processInfo.physicalMemory < highMemoryBytes
    }

    /// Потолок `n_ctx` для этого Mac (обученное окно модели учитывает движок).
    var contextLimit: Int {
        Self.isLowMemoryMac ? min(maxContext, Self.lowMemoryContext) : maxContext
    }
}

extension LLMSampling {
    /// Жадный выбор: у задач с одним верным ответом (имена, чистка текста)
    /// случайность только вредит, а один и тот же вход даёт один и тот же итог.
    static let greedy = LLMSampling(temperature: 0, topK: 1, topP: 1, minP: 0,
                                    repeatPenalty: 1, repeatLastN: 0, seed: 0)
}
