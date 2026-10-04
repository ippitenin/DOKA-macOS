import Foundation

/// Дубль губ: одна диктовка, снятая камерой. Токен едет вместе с записью
/// звука (`RecordedDictation.lipTake`) до решения о её судьбе.
struct LipTake: Equatable, Hashable {
    let id: UUID

    /// Папка сырья дубля: `LipData/pending/<id>/`.
    var folder: URL { Self.pendingRoot.appendingPathComponent(id.uuidString, isDirectory: true) }
    var rawVideoURL: URL { folder.appendingPathComponent("raw.mp4") }
    var captureLogURL: URL { folder.appendingPathComponent("capture.json") }

    static var pendingRoot: URL {
        AppDataFolder.lipDataURL.appendingPathComponent("pending", isDirectory: true)
    }
}

/// Журнал захвата дубля (`capture.json`): что камера реально записала в
/// `raw.mp4` и где было лицо. Пишется, когда файл дописан, — это маркер
/// «камера закончила».
struct LipCaptureLog: Codable, Equatable {
    struct Frame: Codable, Equatable {
        /// Метка кадра в `raw.mp4`, секунды от первого кадра.
        var t: Double
        /// Хост-время кадра (секунды mach) — для сшивки с WAV.
        var host: Double
        /// Средняя яркость кадра 0…255 — для отсечения прогрева экспозиции.
        var luma: Double
    }

    struct Face: Codable, Equatable {
        var host: Double
        /// Бокс самого крупного лица в пикселях кадра: x, y (от верхнего левого
        /// угла), ширина, высота. nil — лица нет.
        var box: [Double]?
        /// Сколько лиц в кадре.
        var count: Int
    }

    /// Эффекты камеры, которые включает сам пользователь в Пункте управления:
    /// они меняют картинку и могут сбить трекер лиц при обучении.
    struct Effects: Codable, Equatable {
        var centerStage: Bool
        var portrait: Bool
        var studioLight: Bool
        var backgroundReplacement: Bool
        var reactions: Bool
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
