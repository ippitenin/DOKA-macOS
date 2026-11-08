import Darwin
import Foundation

/// Какие файлы агент вправе отдать в `transcribe_file`. Чистая логика над
/// файловой системой (тестируется на временной папке).
///
/// Зачем: с разрешением «Распознавать файлы» (включено по умолчанию) агент
/// мог бы назвать путь к звуку, который DOKA хранит сама, — архиву записи
/// библиотеки, аудио истории, клипу губ (в нём весь звук диктовки) или
/// временному WAV неудачной диктовки — и прочитать его расшифровку как
/// «свою», мимо «Читать библиотеку» и «Историю диктовки».
///
/// Сравнение — по идентификатору папки (устройство + inode), а не по строке
/// пути: APFS по умолчанию не различает регистр, а симлинки и `..` ведут в те
/// же папки под другими именами. Проверяется уже разрешённый путь, и
/// распознаётся тоже он — подменить симлинк между проверкой и чтением нельзя.
enum AgentPathPolicy {
    enum Verdict: Equatable {
        /// Можно: настоящий путь без симлинков.
        case allowed(String)
        case missing
        /// Папка, FIFO, устройство: FIFO с расширением `.wav` подвесил бы
        /// распознавание навсегда.
        case notRegularFile
        /// Файл DOKA — агенту нельзя.
        case protected
    }

    struct FileID: Hashable {
        let device: dev_t
        let inode: ino_t
    }

    /// - Parameters:
    ///   - protectedRoots: папки, всё внутри которых закрыто (данные DOKA).
    ///   - protectedPrefixDirectory: папка, где закрыты файлы с именем на
    ///     `protectedPrefix` (временная папка и `doka-*.wav`).
    static func check(path: String, protectedRoots: [URL],
                      protectedPrefixDirectory: URL? = nil, protectedPrefix: String = "doka-") -> Verdict {
        guard let resolved = realPath(path) else { return .missing }
        var info = stat()
        guard stat(resolved, &info) == 0 else { return .missing }
        guard info.st_mode & S_IFMT == S_IFREG else { return .notRegularFile }

        let roots = Set(protectedRoots.compactMap { fileID($0.path) })
        var directory = (resolved as NSString).deletingLastPathComponent
        if let prefixDirectory = protectedPrefixDirectory,
           let prefixID = fileID(prefixDirectory.path),
           fileID(directory) == prefixID,
           (resolved as NSString).lastPathComponent.lowercased().hasPrefix(protectedPrefix.lowercased()) {
            return .protected
        }
        while true {
            if let id = fileID(directory), roots.contains(id) { return .protected }
            guard directory != "/", !directory.isEmpty else { break }
            directory = (directory as NSString).deletingLastPathComponent
        }
        return .allowed(resolved)
    }

    /// Папки с данными DOKA: папка по умолчанию (там же `Models` и `LipData`),
    /// выбранная «Папка данных» и папка прежнего приложения Whisper.
    static var dokaRoots: [URL] {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return [AppDataFolder.defaultURL, AppDataFolder.currentURL,
                appSupport.appendingPathComponent("Whisper", isDirectory: true)]
    }

    static func fileID(_ path: String) -> FileID? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return FileID(device: info.st_dev, inode: info.st_ino)
    }

    private static func realPath(_ path: String) -> String? {
        guard let pointer = realpath(path, nil) else { return nil }
        defer { free(pointer) }
        return String(cString: pointer)
    }
}
