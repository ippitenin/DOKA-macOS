import CryptoKit
import Foundation

/// Скачивание одного большого файла модели по HTTPS: прогресс, докачка после
/// обрыва сети, проверка размера и SHA-256, атомарная установка.
///
/// Своя реализация, а не `WhisperKit.download`/`AsrModels.download`: те ходят
/// в HuggingFace Hub за деревом репозитория, а нам нужен один конкретный файл
/// с пином ревизии и проверкой хэша — модель ИИ-анализа весит 2.5 ГБ, и
/// молча установленный огрызок обошёлся бы пользователю повторной закачкой.
enum HTTPModelDownloader {
    struct Request: Sendable {
        let url: URL
        let expectedBytes: Int64
        /// hex, нижний регистр.
        let sha256: String
        /// Куда положить готовый файл (папка создаётся, если её нет).
        let destination: URL
    }

    enum Failure: LocalizedError {
        case http(Int)
        case sizeMismatch(expected: Int64, got: Int64)
        case checksumMismatch
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .http(let code): return L("analysis.error.http", code)
            case .sizeMismatch: return L("analysis.error.checksum")
            case .checksumMismatch: return L("analysis.error.checksum")
            case .writeFailed(let reason): return L("error.localLoadFailed", reason)
            }
        }
    }

    /// Сколько раз пробуем возобновить закачку после обрыва и с какими паузами.
    private static let retryDelays: [Duration] = [.seconds(2), .seconds(5), .seconds(10),
                                                  .seconds(20), .seconds(30)]

    /// Доля прогресса, отданная скачиванию; остаток — проверка хэша (на
    /// 2.5 ГБ это заметные секунды, и замершая на 100 % шкала выглядела бы
    /// зависанием).
    private static let downloadShare = 0.98

    /// Качает файл и устанавливает его в `destination`. Отмена задачи
    /// прерывает закачку и убирает временный файл.
    static func download(_ request: Request,
                         progress: @escaping @Sendable (Double) -> Void) async throws {
        let fm = FileManager.default
        let folder = request.destination.deletingLastPathComponent()
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)

        // Отдельное имя на попытку: параллельная (ошибочно запущенная) закачка
        // не должна писать в тот же файл. Огрызки подчищает sweep на старте.
        let staging = folder.appendingPathComponent("\(stagingPrefix)\(UUID().uuidString).part")
        defer { try? fm.removeItem(at: staging) }

        var resumeData: Data?
        var attempt = 0
        while true {
            do {
                try await fetch(request, into: staging, resumeData: resumeData) {
                    progress($0 * downloadShare)
                }
                break
            } catch let error as ResumableError {
                try Task.checkCancellation()
                guard attempt < retryDelays.count else { throw error.underlying }
                resumeData = error.resumeData
                try await Task.sleep(for: retryDelays[attempt])
                attempt += 1
            }
        }

        let size = ((try? fm.attributesOfItem(atPath: staging.path)[.size]) as? NSNumber)?.int64Value ?? 0
        guard size == request.expectedBytes else {
            throw Failure.sizeMismatch(expected: request.expectedBytes, got: size)
        }

        let digest = try await sha256(of: staging)
        guard digest == request.sha256.lowercased() else { throw Failure.checksumMismatch }
        progress(1)

        // Установка — последним шагом: до этого момента `destination` не
        // существует, и `isOnDisk` не примет огрызок за готовую модель.
        try? fm.removeItem(at: request.destination)
        do {
            try fm.moveItem(at: staging, to: request.destination)
        } catch {
            throw Failure.writeFailed(error.localizedDescription)
        }
    }

    /// Префикс временного файла закачки. Публичный: sweep на старте ищет
    /// огрызки по нему же.
    static let stagingPrefix = ".incoming-"

    /// Огрызки прошлых закачек (kill приложения посреди скачивания).
    /// `newerThan` отсекает файл, который качается ПРЯМО СЕЙЧАС: sweep идёт
    /// фоновой задачей со старта, а пользователь может нажать «Скачать»
    /// раньше, чем она доберётся до папки.
    static func sweepLeftovers(in folder: URL, newerThan cutoff: Date) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: folder.path) else { return }
        for name in items where name.hasPrefix(stagingPrefix) {
            let url = folder.appendingPathComponent(name)
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            guard let modified, modified < cutoff else { continue }
            try? fm.removeItem(at: url)
        }
    }

    // MARK: - Одна попытка

    /// Ошибка, после которой имеет смысл возобновить закачку с того же места.
    private struct ResumableError: Error {
        let underlying: Error
        let resumeData: Data?
    }

    private static func fetch(_ request: Request, into staging: URL, resumeData: Data?,
                              progress: @escaping @Sendable (Double) -> Void) async throws {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 6 * 3600
        config.waitsForConnectivity = true
        let delegate = DownloadDelegate(destination: staging, expectedBytes: request.expectedBytes,
                                        progress: progress)
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let task = resumeData.map { session.downloadTask(withResumeData: $0) }
            ?? session.downloadTask(with: request.url)

        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    delegate.continuation = continuation
                    task.resume()
                }
            } onCancel: {
                // Отмена пользователем: resumeData не нужны — частичный файл
                // удаляется, состояние возвращается в «не скачана».
                task.cancel()
            }
        } catch {
            try Task.checkCancellation()
            // Сеть оборвалась — пробуем продолжить с того же места.
            let resume = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
            if error is Failure { throw error }
            throw ResumableError(underlying: error, resumeData: resume)
        }
    }

    /// Делегат живёт, пока живёт сессия; продолжение возобновляется ровно один
    /// раз — `didFinishDownloadingTo` и `didCompleteWithError` приходят оба.
    private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        private let destination: URL
        private let expectedBytes: Int64
        private let progress: @Sendable (Double) -> Void
        private let lock = NSLock()
        private var stored: CheckedContinuation<Void, Error>?
        private var finished = false
        private var lastPercent = -1

        var continuation: CheckedContinuation<Void, Error>? {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }

        init(destination: URL, expectedBytes: Int64,
             progress: @escaping @Sendable (Double) -> Void) {
            self.destination = destination
            self.expectedBytes = expectedBytes
            self.progress = progress
        }

        private func finish(_ result: Result<Void, Error>) {
            let continuation: CheckedContinuation<Void, Error>? = lock.withLock {
                guard !finished else { return nil }
                finished = true
                let c = stored
                stored = nil
                return c
            }
            continuation?.resume(with: result)
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                        totalBytesExpectedToWrite: Int64) {
            // Размер из заголовка бывает -1 (chunked) — тогда считаем от
            // ожидаемого размера файла из спеки.
            let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : expectedBytes
            guard total > 0 else { return }
            // Квантование до процента: колбэк приходит на каждый чанк, а на
            // той стороне — перерисовка SwiftUI.
            let percent = Int(Double(totalBytesWritten) / Double(total) * 100)
            let changed: Bool = lock.withLock {
                guard percent > lastPercent else { return false }
                lastPercent = percent
                return true
            }
            guard changed else { return }
            progress(min(max(Double(totalBytesWritten) / Double(total), 0), 1))
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didFinishDownloadingTo location: URL) {
            // Система удалит временный файл сразу после возврата из метода,
            // поэтому переносим СИНХРОННО, прямо здесь.
            if let response = downloadTask.response as? HTTPURLResponse,
               !(200...299).contains(response.statusCode) {
                finish(.failure(Failure.http(response.statusCode)))
                return
            }
            do {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: location, to: destination)
                finish(.success(()))
            } catch {
                finish(.failure(Failure.writeFailed(error.localizedDescription)))
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error {
                finish(.failure(error))
            } else {
                // Успех уже зафиксирован в didFinishDownloadingTo; если нет —
                // ответ без тела, это ошибка.
                finish(.failure(Failure.http(0)))
            }
        }
    }

    // MARK: - Хэш

    /// Флаг отмены для detached-задачи: она НЕ наследует отмену родителя,
    /// и `Task.checkCancellation()` внутри неё был бы мёртвым кодом.
    private final class CancelFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isCancelled: Bool { lock.withLock { value } }
        func cancel() { lock.withLock { value = true } }
    }

    /// SHA-256 потоком кусками по 8 МБ: держать 2.5 ГБ в памяти нельзя.
    /// Считается в отдельной задаче — это чистый CPU на десяток секунд, и на
    /// вызывающем исполнителе (главный актор) он заморозил бы интерфейс.
    /// Отмена пробрасывается флагом: иначе «Отмена» на 98 % ждала бы
    /// дохеширования всех 2,5 ГБ и успевала установить модель до отката.
    private static func sha256(of url: URL) async throws -> String {
        let flag = CancelFlag()
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) {
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                var hasher = SHA256()
                while true {
                    if flag.isCancelled { throw CancellationError() }
                    guard let chunk = try handle.read(upToCount: 8 * 1024 * 1024),
                          !chunk.isEmpty else { break }
                    hasher.update(data: chunk)
                }
                return hasher.finalize().map { String(format: "%02x", $0) }.joined()
            }.value
        } onCancel: {
            flag.cancel()
        }
    }
}
