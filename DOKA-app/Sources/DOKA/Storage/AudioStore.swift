import AVFoundation
import Foundation

/// Хранилище сжатого аудио истории: `<App Support>/DOKA/audio/<record-id>.m4a`.
/// Кодирует исходный WAV диктовки в AAC/m4a и чистит файлы по мере удаления записей.
///
/// Намеренно НЕ `@MainActor`: кодирование — тяжёлая CPU-работа и должно идти вне
/// главного потока. `encode` — async (исполняется на фоне), остальные методы — лёгкие
/// файловые операции, безопасно зовутся синхронно из `@MainActor`-кода (`HistoryStore`).
/// Состояние класса неизменяемо (только `dir`), операции над разными файлами независимы —
/// поэтому `@unchecked Sendable` корректен.
final class AudioStore: @unchecked Sendable {
    static let shared = AudioStore()

    private let dir: URL

    private init() {
        let base = AppDataFolder.currentURL
            .appendingPathComponent("audio", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        dir = base
    }

    /// Имя файла аудио для записи с данным id. Детерминировано — id генерируется в
    /// контроллере до кодирования, поэтому имя файла и `audioFileName` записи всегда совпадают.
    static func fileName(for id: UUID) -> String { "\(id.uuidString).m4a" }

    /// Битрейт AAC для речи: 16 кГц моно — 24 кбит/с достаточно (≈ 11 МБ на час записи).
    static let speechBitRate = 24_000

    /// Настройки AAC/m4a для речи — общие у аудио истории диктовки и у архива
    /// исходного звука файловой транскрибации (`SourceAudioArchiver`), чтобы оба
    /// архива кодировались одинаково.
    static func aacSettings(sampleRate: Double, channels: AVAudioChannelCount) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: speechBitRate
        ]
    }

    /// URL существующего файла аудио по имени, либо nil, если файла нет на диске.
    func url(forFileName name: String) -> URL? {
        let u = dir.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    /// Кодирует WAV → m4a (AAC) в `audio/<id>.m4a`. Возвращает имя файла при успехе,
    /// nil при любой ошибке (запись истории всё равно создаётся, просто без аудио).
    /// Не бросает. Тяжёлая работа идёт вне главного потока (метод nonisolated async).
    func encode(wavURL: URL, recordID: UUID) async -> String? {
        let name = Self.fileName(for: recordID)
        let outURL = dir.appendingPathComponent(name)
        do {
            let input = try AVAudioFile(forReading: wavURL)
            let settings = Self.aacSettings(sampleRate: input.fileFormat.sampleRate,
                                            channels: input.fileFormat.channelCount)
            let output = try AVAudioFile(forWriting: outURL, settings: settings)
            let format = input.processingFormat
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_384) else {
                return nil
            }
            // AVAudioFile сам конвертит PCM-буфер в AAC при записи.
            while input.framePosition < input.length {
                try input.read(into: buffer)
                if buffer.frameLength == 0 { break }
                try output.write(from: buffer)
            }
            return name
        } catch {
            NSLog("[AudioStore] кодирование m4a не удалось: \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: outURL)
            return nil
        }
    }

    /// Удаляет один файл аудио по имени (idempotent, ошибки глушит).
    func removeFile(named name: String) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
    }

    /// Пакетное удаление файлов аудио (очистка истории / пакетное удаление записей).
    func removeFiles(named names: [String]) {
        for name in names { removeFile(named: name) }
    }

    /// Удаляет все файлы аудио (кнопка «Стереть всё аудио»).
    func removeAll() {
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        for item in items { try? FileManager.default.removeItem(at: dir.appendingPathComponent(item)) }
    }

    /// Чистка осиротевших файлов: удаляет в `audio/` всё, чьё имя не входит в `keep`.
    /// Вызывается после загрузки истории — убирает файлы, оставшиеся от крашей между
    /// кодированием и сохранением json.
    func pruneOrphans(keeping keep: Set<String>) {
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        for item in items where !keep.contains(item) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(item))
        }
    }
}
