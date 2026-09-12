import Foundation

/// Скачиваемый ресурс, живущий в `Application Support/DOKA/Models`.
/// Речевые модели — это сервисы распознавания (попадают в `providerID` и в
/// пикер «Сервис»), диаризатор и языковая модель анализа — нет: это
/// вспомогательные движки, которые включаются своими тумблерами при любом
/// сервисе. Поэтому расширять `LocalModel` нельзя (`allCases` строит меню
/// сервисов) — общий у них только механизм скачивания и хранения.
enum LocalAsset: Hashable {
    case speech(LocalModel)
    case diarizer
    /// Языковая модель локального ИИ-анализа (`LLMModelSpec.current`).
    case llm

    /// Ассоциированные значения не дают синтезировать `CaseIterable`.
    static var allCases: [LocalAsset] {
        LocalModel.allCases.map { .speech($0) } + [.diarizer, .llm]
    }

    /// Примерный размер скачивания — только для подписи до скачивания
    /// (после — показывается реальный размер на диске).
    var approxDownloadBytes: Int64 {
        switch self {
        case .speech(let model): return model.approxDownloadBytes
        case .diarizer: return 23_000_000
        case .llm: return LLMModelSpec.current.bytes
        }
    }

    /// Ресурс не работает на Intel. У диаризатора (pyannote + WeSpeaker)
    /// гварда Apple Silicon нет ни в FluidAudio, ни в самих моделях —
    /// на Intel он идёт через CPU. У языковой модели наоборот: x86_64-срез
    /// официального llama.cpp собран без AVX/AVX2/FMA, и Q4_K-матмулы 4B-модели
    /// на голом SSE — это десятки минут на получасовую запись.
    var requiresAppleSilicon: Bool {
        switch self {
        case .speech(let model): return model.requiresAppleSilicon
        case .diarizer: return false
        case .llm: return true
        }
    }

    /// Для логов; в UI ресурсы подписываются своими строками.
    var logName: String {
        switch self {
        case .speech(let model): return model.rawValue
        case .diarizer: return "diarizer"
        case .llm: return "llm"
        }
    }
}

/// Ошибки подготовки локального ресурса, общие для скачивания и загрузки.
enum LocalAssetError: LocalizedError {
    case notEnoughSpace(needed: String)

    var errorDescription: String? {
        switch self {
        case .notEnoughSpace(let needed): return L("analysis.error.diskSpace", needed)
        }
    }
}
