import Foundation

/// Единый источник правды о папке данных приложения (история, статистика,
/// аудио). По умолчанию — `Application Support/DOKA`; пользователь может
/// перенести её в «Расширенных» настройках. Путь хранится в UserDefaults
/// напрямую (не в SettingsStore): хелпер нужен сторам-синглтонам на самом
/// старте, до любых зависимостей. Применение смены пути — только через
/// перезапуск: сторы держат URL с инициализации.
enum AppDataFolder {
    private static let pathKey = "dataFolderPath"
    /// Имя папки данных — и дефолтной, и создаваемой внутри выбранной.
    private static let folderName = "DOKA"

    static let defaultURL: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent(folderName, isDirectory: true)

    /// Подпапка локальных моделей распознавания. ФИКСИРОВАННАЯ: всегда в
    /// Application Support, за кастомной «Папкой данных» не следует — модели
    /// (1.5+ ГБ) — перекачиваемый кеш, а не данные пользователя; перенос
    /// папки данных их не копирует и не удаляет (см. migrateToTarget).
    private static let modelsFolderName = "Models"
    static let modelsURL: URL = defaultURL
        .appendingPathComponent(modelsFolderName, isDirectory: true)

    /// Пары «губы + текст» эксперимента чтения по губам. ФИКСИРОВАННАЯ, как
    /// модели: датасет читает внешний инструмент обучения по постоянному
    /// пути, и перенос «Папки данных» не должен ни увозить его, ни стирать.
    private static let lipDataFolderName = "LipData"
    static let lipDataURL: URL = defaultURL
        .appendingPathComponent(lipDataFolderName, isDirectory: true)

    /// Подпапки, которые живут в Application Support при любой «Папке данных»:
    /// перенос их пропускает, а при возврате на путь по умолчанию они не
    /// считаются «непустой целью».
    static let fixedFolderNames: Set<String> = [modelsFolderName, lipDataFolderName]

    /// Мешает ли содержимое существующей цели переносу. Служебный мусор Finder
    /// и фиксированные папки содержимым не считаются.
    static func blocksMigration(targetContents: [String]) -> Bool {
        targetContents.contains { $0 != ".DS_Store" && !fixedFolderNames.contains($0) }
    }

    /// Действующая папка данных. Кастомный путь учитывается, только если
    /// папка реально существует (том мог быть отключён, папку могли удалить)
    /// — иначе тихий фолбэк на дефолт, приложение не должно умирать.
    static var currentURL: URL {
        guard let path = UserDefaults.standard.string(forKey: pathKey),
              !path.isEmpty else { return defaultURL }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            NSLog("DOKA: папка данных «\(path)» недоступна — используется путь по умолчанию")
            return defaultURL
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Задан ли пользовательский путь (для кнопки «Вернуть по умолчанию»).
    static var isCustom: Bool {
        canonicalPath(currentURL) != canonicalPath(defaultURL)
    }

    // MARK: - Перенос

    enum MigrationError: LocalizedError {
        case sameFolder            // цель совпадает с текущей
        case nestedFolders         // цель внутри текущей или наоборот
        case targetNotEmpty        // цель существует и непуста
        case copyFailed(Error)

        var errorDescription: String? {
            switch self {
            case .sameFolder: return L("advanced.migrate.error.same")
            case .nestedFolders: return L("advanced.migrate.error.nested")
            case .targetNotEmpty: return L("advanced.migrate.error.notEmpty")
            case .copyFailed(let error):
                return L("advanced.migrate.error.copyFailed", error.localizedDescription)
            }
        }
    }

    /// Папку данных перенесли, а приложение ещё не перезапустили.
    ///
    /// Библиотека транскрибаций на этот случай замораживается (`freeze`), но у
    /// истории диктовок, статистики и аудио своей заморозки нет: их синглтоны
    /// фиксируют путь один раз в `init` (`HistoryStore:39`, `StatsStore:74`,
    /// `AudioStore:17`) и создаются ДО переноса, поэтому продолжали бы писать
    /// в старую папку — уже удалённую либо ставшую «призрачной». Всё, что
    /// пользователь надиктовал после переноса и до перезапуска, пропадало.
    ///
    /// Флаг закрывает это на входе: новые диктовки не начинаются, пока
    /// приложение не перезапустили.
    @MainActor private(set) static var needsRestart = false

    /// Вызывается после УСПЕШНОГО переноса.
    @MainActor static func markNeedsRestart() { needsRestart = true }

    /// Переносит данные в выбранную пользователем папку и переключает путь.
    /// Если выбранная папка не называется «DOKA», данные лягут в подпапку
    /// `<выбранная>/DOKA` (не засоряем чужую папку россыпью файлов).
    /// Возвращает итоговый путь. После успеха нужен перезапуск приложения.
    @discardableResult
    static func migrate(to chosenDirectory: URL) throws -> URL {
        let target = chosenDirectory.lastPathComponent == folderName
            ? chosenDirectory
            : chosenDirectory.appendingPathComponent(folderName, isDirectory: true)
        return try migrateToTarget(target)
    }

    /// Обратный перенос в папку по умолчанию («Вернуть по умолчанию»).
    @discardableResult
    static func migrateToDefault() throws -> URL {
        try migrateToTarget(defaultURL)
    }

    /// Канонический путь для сравнения: символические ссылки (в т.ч.
    /// /private/tmp → /tmp) резолвятся по самому глубокому СУЩЕСТВУЮЩЕМУ
    /// предку, хвост приклеивается как есть. Ни standardizedFileURL, ни
    /// resolvingSymlinksInPath сами по себе не годятся: несуществующий путь
    /// они возвращают нетронутым, и существующий источник с несуществующей
    /// целью получают разные формы одного и того же пути — проверка
    /// вложенности слепнет (проверено песочным тестом).
    private static func canonicalPath(_ url: URL) -> String {
        var existing = url.standardizedFileURL
        var tail: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path),
              existing.pathComponents.count > 1 {
            tail.append(existing.lastPathComponent)
            existing = existing.deletingLastPathComponent()
        }
        var resolved = existing.resolvingSymlinksInPath()
        for component in tail.reversed() {
            resolved.appendPathComponent(component)
        }
        return resolved.path
    }

    private static func migrateToTarget(_ target: URL) throws -> URL {
        let fm = FileManager.default
        let source = currentURL
        let sourcePath = canonicalPath(source)
        let targetPath = canonicalPath(target)

        guard sourcePath != targetPath else { throw MigrationError.sameFolder }
        guard !targetPath.hasPrefix(sourcePath + "/"),
              !sourcePath.hasPrefix(targetPath + "/") else {
            throw MigrationError.nestedFolders
        }
        let targetExisted = fm.fileExists(atPath: targetPath)
        if targetExisted {
            let contents = (try? fm.contentsOfDirectory(atPath: targetPath)) ?? []
            // Служебный мусор Finder и фиксированные папки (Models, LipData) не
            // считаются содержимым: возврат на путь по умолчанию не должен
            // спотыкаться о них (и тем более стирать их).
            guard !blocksMigration(targetContents: contents) else {
                throw MigrationError.targetNotEmpty
            }
        }

        // Копирование по элементам (не папкой целиком): фиксированные подпапки
        // (Models, LipData) пропускаются — они живут на постоянном месте и не
        // должны ни уезжать при переносе, ни стираться при откате.
        var copied: [URL] = []
        do {
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
            let items = try fm.contentsOfDirectory(atPath: source.path)
            for name in items where !fixedFolderNames.contains(name) {
                let destination = target.appendingPathComponent(name)
                // Запоминаем ДО копирования: FileManager не разматывает
                // частичную копию сам, и упавший на середине элемент иначе не
                // попал бы в откат. Огрызок в цели навсегда ломал бы «Вернуть
                // по умолчанию» — он не входит в белый список `targetNotEmpty`.
                copied.append(destination)
                try fm.copyItem(at: source.appendingPathComponent(name), to: destination)
            }
        } catch {
            // Не оставляем частичную копию; существовавшую цель (с Models) не трогаем.
            if targetExisted {
                for url in copied { try? fm.removeItem(at: url) }
            } else {
                try? fm.removeItem(at: target)
            }
            throw MigrationError.copyFailed(error)
        }

        // Путь переключается только после успешного копирования.
        if targetPath == canonicalPath(defaultURL) {
            UserDefaults.standard.removeObject(forKey: pathKey)
        } else {
            UserDefaults.standard.set(targetPath, forKey: pathKey)
        }
        // Старую папку убираем best-effort (кроме фиксированных): данные уже в
        // целости на новом месте. Если внутри осталась фиксированная подпапка —
        // папка живёт дальше.
        do {
            let leftovers = try fm.contentsOfDirectory(atPath: source.path)
            for name in leftovers where !fixedFolderNames.contains(name) {
                try fm.removeItem(at: source.appendingPathComponent(name))
            }
            // Всё, кроме фиксированных, удалено выше (сбой бросил бы в catch):
            // их не было — папка пуста и убирается целиком.
            if !leftovers.contains(where: fixedFolderNames.contains) {
                try fm.removeItem(at: source)
            }
        } catch {
            NSLog("DOKA: старая папка данных не удалилась: \(error.localizedDescription)")
        }
        return target
    }
}
