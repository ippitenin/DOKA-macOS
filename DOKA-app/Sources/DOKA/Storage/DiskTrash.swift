import Foundation

/// Корзина фонового удаления: папка (или файл) сначала мгновенно
/// переименовывается в `<имя>.deleting-<uuid>` рядом с собой, а стирается
/// потом. Переименование на том же томе атомарно: элемент исчезает сразу, а
/// прерванное стирание (kill, выход) не оставляет полупустую папку, похожую
/// на живую, — огрызок узнаётся по имени и добивается уборкой на старте.
/// Общая для библиотеки транскрибаций, локальных моделей и «Губ».
enum DiskTrash {
    static let marker = ".deleting-"

    static func isTrash(_ name: String) -> Bool { name.contains(marker) }

    /// Переименовать в корзину рядом с собой; вернуть новое место. nil —
    /// переносить нечего, либо переименование не вышло и элемент стёрт на
    /// месте (редкий путь).
    @discardableResult
    static func move(_ url: URL) -> URL? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return nil }
        let bin = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent)\(marker)\(UUID().uuidString)")
        if (try? fm.moveItem(at: url, to: bin)) != nil { return bin }
        try? fm.removeItem(at: url)
        return nil
    }

    /// Стереть корзину прямо внутри `folder` (только `*.deleting-*`, без
    /// рекурсии). Чужих элементов не трогает, поэтому её можно звать
    /// параллельно с остальной работой над папкой.
    static func empty(_ folder: URL) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { return }
        for name in names where isTrash(name) {
            try? fm.removeItem(at: folder.appendingPathComponent(name))
        }
    }
}

extension FileManager {
    /// Сколько дерево занимает на диске (выделенные блоки; скрытые файлы не
    /// в счёт). Рекурсивный stat — звать вне главного потока: у моделей это
    /// гигабайты и тысячи файлов.
    func allocatedSize(of folder: URL) -> Int64 {
        guard let enumerator = enumerator(at: folder, includingPropertiesForKeys: [.totalFileAllocatedSizeKey],
                                          options: [.skipsHiddenFiles]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            total += Int64((try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?
                .totalFileAllocatedSize ?? 0)
        }
        return total
    }
}

extension URL {
    /// Дата изменения с диска; nil — файла нет или том её не отдаёт. Уборки на
    /// старте сравнивают её с моментом запуска: свежее — работа этого запуска.
    var contentModificationDate: Date? {
        (try? resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}
