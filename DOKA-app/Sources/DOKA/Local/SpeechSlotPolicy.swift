import Foundation

/// Кто держит слот речевого движка `LocalEngineManager`.
///
/// Модель распознавания одна на приложение, а пользоваться ею могут сразу
/// двое: диктовка и транскрибация файла. Без учёта аренды второй либо вставал
/// в очередь за первым (у Parakeet `AsrManager` — actor, вызовы строго по
/// одному: короткая диктовка ждала часовой файл), либо выгружал чужую модель
/// посреди работы (`engine(for:)` с другой моделью → `unloadNow()`).
enum SpeechSlotHolder: CaseIterable {
    /// Транскрибация файла локальной моделью — на весь прогон.
    case fileSpeech
    /// Локальная диаризация сетевой транскрибации — только на её шаг.
    case fileDiarization
    /// Диктовка на локальном сервисе — от старта записи до конца распознавания.
    case dictation
}

/// Счётчики аренды по держателям. Чистое значение — решения менеджера
/// проверяются тестами без движков.
struct SpeechSlotLease: Equatable {
    private var counts: [SpeechSlotHolder: Int] = [:]

    var isHeld: Bool { counts.values.contains { $0 > 0 } }

    func isHeld(by holder: SpeechSlotHolder) -> Bool { (counts[holder] ?? 0) > 0 }

    /// Аренда файлом в любом виде: под ней нельзя трогать диаризатор.
    var isHeldByFile: Bool { isHeld(by: .fileSpeech) || isHeld(by: .fileDiarization) }

    mutating func begin(_ holder: SpeechSlotHolder) {
        counts[holder, default: 0] += 1
    }

    /// Лишний `end` не уводит счётчик в минус: иначе следующая аренда
    /// оказалась бы «невидимой» и не защитила бы слот.
    mutating func end(_ holder: SpeechSlotHolder) {
        let count = counts[holder] ?? 0
        counts[holder] = count > 1 ? count - 1 : nil
    }
}

/// Решения о слоте речевого движка. Без синглтонов: на вход — состояние
/// слота и аренда, на выход — что делать.
enum SpeechSlotPolicy {

    enum DictationStart: Equatable { case ok, busyFile }
    enum FileStart: Equatable { case ok, busyDictation }
    enum Unload: Equatable { case now, deferred }

    enum Load: Equatable {
        /// Нужная модель уже в слоте.
        case reuse
        /// Нужная модель уже грузится — ждать ту же задачу.
        case awaitLoading
        /// Грузить, выгрузив перед этим то, что помечено.
        case load(unloadSpeech: Bool, unloadDiarizer: Bool)
        /// Слот держит файл с ДРУГОЙ моделью: выгрузить её значит оборвать файл.
        case refuse
    }

    /// Локальная диктовка не начинается, пока файл держит речевую модель, —
    /// даже ту же самую: она встала бы в очередь за файлом и «зависла».
    /// Сетевой диктовке и шагу диаризации сетевого файла слот не мешает.
    static func dictationStart(isLocal: Bool, lease: SpeechSlotLease) -> DictationStart {
        isLocal && lease.isHeld(by: .fileSpeech) ? .busyFile : .ok
    }

    /// Обратная сторона: локальный файл не стартует поверх локальной диктовки.
    /// Сетевой файл (в том числе с локальной диаризацией) — можно: диаризатор
    /// живёт рядом с речевой моделью и её не выгружает.
    static func fileStart(isLocalRoute: Bool, lease: SpeechSlotLease) -> FileStart {
        isLocalRoute && lease.isHeld(by: .dictation) ? .busyDictation : .ok
    }

    /// Что делать `engine(for:)`. Без аренды файла — прежнее поведение:
    /// смена модели выгружает и речевой движок, и диаризатор (память).
    static func load(requested: LocalModel, loaded: LocalModel?, loading: LocalModel?,
                     lease: SpeechSlotLease) -> Load {
        if loaded == requested { return .reuse }
        if loading == requested { return .awaitLoading }
        let speechInSlot = loaded != nil || loading != nil
        if lease.isHeld(by: .fileSpeech) && speechInSlot { return .refuse }
        return .load(unloadSpeech: speechInSlot, unloadDiarizer: !lease.isHeldByFile)
    }

    /// Таймер простоя не выгружает слот, пока его кто-то держит: длинный файл
    /// распознаётся дольше 5 минут окна простоя.
    static func idleUnloadAllowed(lease: SpeechSlotLease) -> Bool { !lease.isHeld }

    /// Смена сервиса выгружает модель ушедшего сервиса — но не из-под работы:
    /// тогда выгрузка откладывается до снятия последней аренды.
    static func serviceSwitchUnload(lease: SpeechSlotLease) -> Unload {
        lease.isHeld ? .deferred : .now
    }
}
