import Foundation

/// Имена раскладки `LipData/` — один источник для камеры (`LipTake`) и
/// файлового слоя (`LipDataFiles`). Это и договор с WISLIP: его импортёр
/// читает `takes/*/meta.json` и `clip.mp4`.
enum LipDataLayout {
    static let pending = "pending"
    static let takes = "takes"
    static let rawVideo = "raw.mp4"
    static let captureLog = "capture.json"
    static let audio = "audio.wav"
    static let job = "job.json"
    static let clip = "clip.mp4"
    static let meta = "meta.json"
    static let stats = "stats.json"
}

/// Дубль губ: одна диктовка, снятая камерой. Токен едет вместе с записью
/// звука (`RecordedDictation.lipTake`) до решения о её судьбе.
struct LipTake: Equatable, Hashable {
    let id: UUID
    /// Корень сырья; тесты подставляют временную папку.
    let pendingRoot: URL

    init(id: UUID, pendingRoot: URL = LipTake.pendingRoot) {
        self.id = id
        self.pendingRoot = pendingRoot
    }

    /// Папка сырья дубля: `LipData/pending/<id>/`.
    var folder: URL { pendingRoot.appendingPathComponent(id.uuidString, isDirectory: true) }
    var rawVideoURL: URL { folder.appendingPathComponent(LipDataLayout.rawVideo) }
    var captureLogURL: URL { folder.appendingPathComponent(LipDataLayout.captureLog) }

    static var pendingRoot: URL {
        AppDataFolder.lipDataURL.appendingPathComponent(LipDataLayout.pending, isDirectory: true)
    }
}

/// Журнал захвата дубля (`capture.json`): что камера реально записала в
/// `raw.mp4` и где было лицо. Пишется, когда файл дописан, — это маркер
/// «камера закончила».
struct LipCaptureLog: Codable, Equatable, Sendable {
    struct Frame: Codable, Equatable, Sendable {
        /// Метка кадра в `raw.mp4`, секунды от первого кадра.
        var t: Double
        /// Хост-время кадра (секунды mach) — для сшивки с WAV.
        var host: Double
        /// Средняя яркость кадра 0…255 — для отсечения прогрева экспозиции.
        var luma: Double
    }

    struct Face: Codable, Equatable, Sendable {
        var host: Double
        /// Бокс самого крупного лица в пикселях кадра: x, y (от верхнего левого
        /// угла), ширина, высота. nil — лица нет.
        var box: [Double]?
        /// Сколько лиц в кадре.
        var count: Int
    }

    /// Эффекты камеры, которые включает сам пользователь в Пункте управления:
    /// они меняют картинку и могут сбить трекер лиц при обучении.
    struct Effects: Codable, Equatable, Sendable {
        var centerStage: Bool
        var portrait: Bool
        var studioLight: Bool
        var backgroundReplacement: Bool
        var reactions: Bool

        /// Ни одного эффекта — до того, как известны формат и настройки камеры.
        static let none = Effects(centerStage: false, portrait: false, studioLight: false,
                                  backgroundReplacement: false, reactions: false)
    }

    var frameWidth: Int
    var frameHeight: Int
    var camera: String
    var frames: [Frame]
    var faces: [Face]
    var droppedFrames: Int
    /// Сбой камеры посреди дубля (отключили, забрали, ошибка сессии).
    var failed: Bool
    var effects: Effects
}

/// Режим речи пары — папка, по которой WISLIP разбивает замеры.
enum LipMode: String, Codable, Sendable {
    case voice
    case whisper
    /// Беззвучные фразы — зарезервировано под окно «Тренировка».
    case silent

    /// По снимку тихого режима на старте записи (`RecordedDictation.quiet`).
    init(quiet: Bool) { self = quiet ? .whisper : .voice }
}

/// Подпись к дубле: сказанный текст и откуда он. Текст — результат
/// распознавания ПОСЛЕ фильтра галлюцинаций и ДО словаря замен: нужно то,
/// что сказано, а не то, во что текст превратил словарь.
struct LipCaption: Equatable {
    let text: String
    let language: String
    let provider: String
    let model: String
    let historyID: UUID
}

/// Заказ на обработку дубля (`job.json`): подпись и всё о записи звука.
/// Пишется при фиксации диктовки — маркер «в работу».
struct LipJob: Codable, Equatable, Sendable {
    var text: String
    var language: String
    var provider: String
    var model: String
    var historyID: UUID
    var date: Date
    var duration: Double
    var speechSeconds: Double
    var quietSpeechSeconds: Double
    var quiet: Bool
    var microphone: String?
    /// nil — аудиодвижок не дал хост-времени (пара будет отброшена).
    var hostStart: Double?
    var inputLatency: Double
    var speechOnset: Double?
    var maxClockDrift: Double

    var timing: RecordingTiming? {
        hostStart.map {
            RecordingTiming(hostStart: $0, inputLatency: inputLatency, speechOnset: speechOnset,
                            maxClockDrift: maxClockDrift)
        }
    }
}

/// `meta.json` пары, версия 1 — договор с импортёром WISLIP (Python).
/// Менять поля — только вместе с `schemaVersion` и импортёром.
struct LipTakeMeta: Codable, Equatable, Sendable {
    static let currentSchema = 1

    struct Video: Codable, Equatable, Sendable {
        var width: Int
        var height: Int
        var fps: Int
        /// Окно шкалы WAV, где видео настоящее (вне — повтор крайнего кадра).
        var validFrom: Double
        var validTo: Double
        var faceCoverage: Double
        /// Пропуски лица дольше 0,2 с: [[начало, конец], …] по шкале WAV.
        var faceGaps: [[Double]]
        /// Кроп в пикселях кадра камеры: x, y (сверху слева), ширина, высота.
        var cropRect: [Int]
        var cameraFrame: [Int]
        var camera: String
        var measuredFps: Double
        var droppedFrames: Int
        var multiFaceFrames: Int
        /// Всегда false: в файле кадр как видит камера.
        var mirrored: Bool
        var effects: LipCaptureLog.Effects
    }

    struct Audio: Codable, Equatable, Sendable {
        var sampleRate: Int
        var codec: String
        var inputLatency: Double
        var maxClockDrift: Double
        var microphone: String?
    }

    var schemaVersion: Int
    var id: UUID
    var date: Date
    /// "dictation"; "training" — зарезервировано под окно «Тренировка».
    var source: String
    var mode: LipMode
    var text: String
    var language: String
    var provider: String
    var model: String
    var historyID: UUID?
    var duration: Double
    var speechSeconds: Double
    var quietSpeechSeconds: Double
    var speechOnset: Double?
    var quiet: Bool
    var video: Video
    var audio: Audio
    var appVersion: String

    /// Даты — ISO 8601 строкой: секунды от 2001 года (умолчание
    /// `JSONEncoder`) Python не прочитает.
    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// Счётчики, которых нет в самих парах (`stats.json`): почему дубли не стали
/// парами и сколько пар начато камерой позже речи.
struct LipStats: Codable, Equatable, Sendable {
    var rejected: [String: Int] = [:]
    var headMissing = 0
}
