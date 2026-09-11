import Foundation

/// Полнотекстовый поиск по библиотеке файловых транскрибаций.
///
/// Стор библиотеки держит в памяти только лёгкий индекс записей (метаданные),
/// полные тексты лежат на диске отдельными `text.txt` — десятки мегабайт
/// расшифровок незачем грузить на старте ради списка. Поэтому текст записи
/// подгружается ЛЕНИВО, при первом поиске, через переданный `loader`,
/// и дальше живёт в кеше: повторные поиски (набор запроса по буквам) диск
/// уже не трогают.
///
/// Поиск — подстрокой по нормализованному тексту (`LibrarySearch`). Для сотен–
/// тысяч записей полный проход занимает миллисекунды, поэтому SQLite/FTS
/// с его миграциями и отдельным файлом базы здесь не нужен.
///
/// Actor — чтобы чтение файлов и проход по текстам шли мимо главного потока,
/// а кеш не требовал ручных блокировок. Внутри `search` нет `await`, поэтому
/// переупорядочивания (reentrancy) посреди прохода не бывает.
actor TranscriptTextIndex {
    /// Кеш одной записи: исходный текст нужен для вырезки сниппета,
    /// нормализованный — для самого поиска. Держатся оба, чтобы не
    /// нормализовать заново на каждое нажатие клавиши.
    private struct Entry {
        let original: String
        let normalized: String

        init(_ text: String) {
            original = text
            normalized = LibrarySearch.normalize(text)
        }
    }

    private let loader: @Sendable (UUID) -> String?
    private var entries: [UUID: Entry] = [:]

    /// `loader` возвращает полный текст записи (стор читает её `text.txt`)
    /// либо `nil`, если текста нет.
    init(loader: @escaping @Sendable (UUID) -> String?) {
        self.loader = loader
    }

    /// Текст записи появился или изменился — кладётся в кеш сразу, без чтения диска.
    func update(_ id: UUID, text: String) {
        entries[id] = Entry(text)
    }

    func remove(_ ids: Set<UUID>) {
        for id in ids {
            entries[id] = nil
        }
    }

    /// Сброс кеша целиком (например, после переноса «Папки данных»):
    /// следующие поиски заново подгрузят тексты через `loader`.
    func removeAll() {
        entries.removeAll()
    }

    /// Ищет запрос среди записей `ids` (порядок не важен) и возвращает
    /// id → сниппет для тех, где встретились ВСЕ слова запроса.
    /// Пустой запрос — пустой словарь: «без фильтра» решает вызывающий.
    ///
    /// Отмена кооперативная: между записями проверяется `Task.isCancelled`,
    /// и проход прекращается — при быстром наборе предыдущий поиск бросается,
    /// не дочитав библиотеку. Результат отменённого поиска неполный,
    /// вызывающий обязан его отбросить.
    func search(_ query: String, among ids: [UUID]) -> [UUID: String] {
        let tokens = LibrarySearch.tokens(query)
        guard !tokens.isEmpty else { return [:] }

        var found: [UUID: String] = [:]
        for id in ids {
            if Task.isCancelled { break }
            guard let entry = entry(for: id),
                  LibrarySearch.matches(normalizedHaystack: entry.normalized, tokens: tokens),
                  let snippet = LibrarySearch.snippet(original: entry.original,
                                                      normalized: entry.normalized,
                                                      tokens: tokens)
            else { continue }
            found[id] = snippet
        }
        return found
    }

    /// Запись из кеша либо ленивая подгрузка. Отсутствие текста НЕ кешируется:
    /// файл может появиться позже (запись ещё дописывается), и «запомненное
    /// отсутствие» спрятало бы её от поиска до перезапуска.
    private func entry(for id: UUID) -> Entry? {
        if let cached = entries[id] { return cached }
        guard let text = loader(id) else { return nil }
        let entry = Entry(text)
        entries[id] = entry
        return entry
    }
}
