import XCTest
@testable import DOKA

/// Поиск по библиотеке транскрибаций: нормализация должна быть терпимой
/// к регистру и «ё», но не склеивать разные буквы («й» ≠ «и»), а сниппет —
/// вырезаться из оригинала ровно там, где найдено совпадение.
final class LibrarySearchTests: XCTestCase {

    // MARK: - Нормализация и токены

    func testNormalizeLowercasesAndFoldsYo() {
        XCTAssertEqual(LibrarySearch.normalize("ЁЖ и Ёлка, ПРИВЕТ World"), "еж и елка, привет world")
    }

    func testNormalizeKeepsShortI() {
        XCTAssertEqual(LibrarySearch.normalize("МОЙ"), "мой")
    }

    func testNormalizePreservesCharacterCount() {
        let text = "İstanbul ЁЖ е\u{301}сли и\u{306} 👍🏽 ß"
        XCTAssertEqual(LibrarySearch.normalize(text).count, text.count)
    }

    func testTokensSplitOnAnyWhitespaceAndDropEmpty() {
        XCTAssertEqual(LibrarySearch.tokens("  Раз\tдва\n ТРИ  "), ["раз", "два", "три"])
        XCTAssertEqual(LibrarySearch.tokens("Ёлка"), ["елка"])
        XCTAssertEqual(LibrarySearch.tokens(" \n\t "), [])
        XCTAssertEqual(LibrarySearch.tokens(""), [])
    }

    // MARK: - Совпадение

    private func matches(_ text: String, _ query: String) -> Bool {
        LibrarySearch.matches(normalizedHaystack: LibrarySearch.normalize(text),
                              tokens: LibrarySearch.tokens(query))
    }

    func testMatchIsCaseInsensitive() {
        XCTAssertTrue(matches("Встреча с КЛИЕНТОМ", "клиентом"))
        XCTAssertTrue(matches("встреча с клиентом", "КЛИЕНТОМ"))
        XCTAssertTrue(matches("Quarterly Report", "quarterly"))
    }

    func testYoAndYeAreInterchangeable() {
        XCTAssertTrue(matches("Ёлка в лесу", "елка"))
        XCTAssertTrue(matches("елка в лесу", "ёлка"))
        XCTAssertTrue(matches("ЕЛКА", "Ёлка"))
    }

    func testDecomposedYoMatchesYe() {
        // «е» + комбинируемый диерезис — та же «ё», только разложенная.
        XCTAssertTrue(matches("е\u{308}лка", "елка"))
    }

    func testShortIIsNotPlainI() {
        XCTAssertFalse(matches("мои вещи", "мой"))
        XCTAssertFalse(matches("мой дом", "мои"))
        XCTAssertTrue(matches("мой дом", "мой"))
    }

    func testDecomposedShortIStillDiffersFromPlainI() {
        // «и» + бреве канонически равно «й»: находится запросом «мой», но не «мои».
        let decomposed = "мои\u{306}"
        XCTAssertTrue(matches(decomposed, "мой"))
        XCTAssertFalse(matches(decomposed, "мои"))
    }

    func testAllTokensAreRequired() {
        XCTAssertTrue(matches("обсудили бюджет и сроки проекта", "сроки бюджет"))
        XCTAssertFalse(matches("обсудили бюджет и сроки проекта", "бюджет отпуск"))
    }

    func testTokenMatchesAsSubstring() {
        XCTAssertTrue(matches("договорились о встрече", "договор"))
    }

    func testEmptyTokensMatchEverything() {
        XCTAssertTrue(LibrarySearch.matches(normalizedHaystack: "что угодно", tokens: []))
        XCTAssertTrue(LibrarySearch.matches(normalizedHaystack: "", tokens: []))
    }

    func testNothingMatchesInEmptyText() {
        XCTAssertFalse(matches("", "слово"))
    }

    // MARK: - Сниппет

    func testSnippetInMiddleHasEllipsisOnBothSides() {
        let text = "0123456789ключ0123456789"
        XCTAssertEqual(LibrarySearch.snippet(in: text, query: "ключ", radius: 3), "…789ключ012…")
    }

    func testSnippetAtStartHasNoLeadingEllipsis() {
        let text = "ключ0123456789"
        XCTAssertEqual(LibrarySearch.snippet(in: text, query: "ключ", radius: 3), "ключ012…")
    }

    func testSnippetAtEndHasNoTrailingEllipsis() {
        let text = "0123456789ключ"
        XCTAssertEqual(LibrarySearch.snippet(in: text, query: "ключ", radius: 3), "…789ключ")
    }

    func testShortTextHasNoEllipsis() {
        XCTAssertEqual(LibrarySearch.snippet(in: "короткий ключ", query: "ключ"), "короткий ключ")
    }

    func testTrailingWhitespaceAfterCutDoesNotAddEllipsis() {
        let text = "0123ключ  \n\n "
        XCTAssertEqual(LibrarySearch.snippet(in: text, query: "ключ", radius: 2), "…23ключ")
    }

    func testSnippetCollapsesNewlinesAndTabs() {
        let text = "первая\n\nвторая\tключ\r\nтретья"
        XCTAssertEqual(LibrarySearch.snippet(in: text, query: "ключ"), "первая вторая ключ третья")
    }

    func testSnippetKeepsOriginalCaseAndYo() {
        XCTAssertEqual(LibrarySearch.snippet(in: "Встреча с КЛИЕНТОМ", query: "клиентом"),
                       "Встреча с КЛИЕНТОМ")
        XCTAssertEqual(LibrarySearch.snippet(in: "Ёлка", query: "елка"), "Ёлка")
    }

    func testSnippetUsesFirstFoundToken() {
        let text = "0123456789ключ0123456789"
        XCTAssertEqual(LibrarySearch.snippet(in: text, query: "отсутствует ключ", radius: 3),
                       "…789ключ012…")
    }

    func testSnippetUsesFirstOccurrence() {
        let text = "ключ 0123456789 ключ"
        // Срез «ключ » обрезается по краям — пробел перед «…» не остаётся.
        XCTAssertEqual(LibrarySearch.snippet(in: text, query: "ключ", radius: 1), "ключ…")
    }

    func testSnippetOffsetsSurviveLowercaseThatChangesByteLength() {
        // «İ» — 2 байта UTF-8, её строчная «i̇» (i + U+0307) — 3 байта и два
        // скаляра, но тоже ОДИН символ. Смещение по байтам или скалярам уехало бы.
        XCTAssertEqual(LibrarySearch.normalize("İ").count, 1)
        let text = "İİİİİ ключ"
        XCTAssertEqual(LibrarySearch.snippet(in: text, query: "ключ", radius: 2), "…İ ключ")
    }

    func testSnippetAfterComposedCharactersKeepsOffsets() {
        // Составные символы (буква + ударение, эмодзи с модификатором) — по одному
        // Character, но по нескольку скаляров.
        let text = "е\u{301}е\u{301}👍🏽👍🏽 ключ"
        XCTAssertEqual(LibrarySearch.snippet(in: text, query: "ключ", radius: 2), "…👍🏽 ключ")
    }

    func testSnippetIsNilWhenNothingFoundOrQueryEmpty() {
        XCTAssertNil(LibrarySearch.snippet(in: "какой-то текст", query: "отсутствует"))
        XCTAssertNil(LibrarySearch.snippet(in: "какой-то текст", query: ""))
        XCTAssertNil(LibrarySearch.snippet(in: "какой-то текст", query: "  \n"))
        XCTAssertNil(LibrarySearch.snippet(in: "", query: "слово"))
    }
}

/// Кеш и ленивая подгрузка текстов в индексе: диск читается один раз на запись,
/// отмена не роняет поиск.
final class TranscriptTextIndexTests: XCTestCase {

    /// Потокобезопасный счётчик вызовов загрузчика (загрузчик — `@Sendable`).
    private final class LoadCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var counts: [UUID: Int] = [:]

        func hit(_ id: UUID) {
            lock.lock()
            counts[id, default: 0] += 1
            lock.unlock()
        }

        func count(_ id: UUID) -> Int {
            lock.lock()
            defer { lock.unlock() }
            return counts[id, default: 0]
        }

        var total: Int {
            lock.lock()
            defer { lock.unlock() }
            return counts.values.reduce(0, +)
        }
    }

    private func makeIndex(_ texts: [UUID: String]) -> (TranscriptTextIndex, LoadCounter) {
        let counter = LoadCounter()
        let index = TranscriptTextIndex { id in
            counter.hit(id)
            return texts[id]
        }
        return (index, counter)
    }

    func testSearchFindsMatchesWithSnippets() async {
        let a = UUID(), b = UUID()
        let (index, _) = makeIndex([a: "Обсудили бюджет проекта", b: "Планёрка по срокам"])

        let result = await index.search("бюджет", among: [a, b])
        XCTAssertEqual(result, [a: "Обсудили бюджет проекта"])

        let yo = await index.search("планерка", among: [a, b])
        XCTAssertEqual(yo, [b: "Планёрка по срокам"])
    }

    func testSearchRequiresAllTokens() async {
        let a = UUID(), b = UUID()
        let (index, _) = makeIndex([a: "бюджет и сроки", b: "только бюджет"])
        let result = await index.search("сроки бюджет", among: [a, b])
        XCTAssertEqual(Set(result.keys), [a])
    }

    func testSearchIsLimitedToRequestedIds() async {
        let a = UUID(), b = UUID()
        let (index, _) = makeIndex([:])
        await index.update(a, text: "ключ")
        await index.update(b, text: "ключ")
        let result = await index.search("ключ", among: [b])
        XCTAssertEqual(Set(result.keys), [b])
    }

    func testEmptyQueryReturnsNothingAndDoesNotLoad() async {
        let a = UUID()
        let (index, counter) = makeIndex([a: "текст"])
        let result = await index.search("   ", among: [a])
        XCTAssertTrue(result.isEmpty)
        XCTAssertEqual(counter.total, 0)
    }

    func testLoaderIsCalledOncePerId() async {
        let a = UUID(), b = UUID()
        let (index, counter) = makeIndex([a: "первая запись", b: "вторая запись"])

        _ = await index.search("запись", among: [a, b])
        _ = await index.search("первая", among: [a, b])
        _ = await index.search("отсутствует", among: [a, b])

        XCTAssertEqual(counter.count(a), 1)
        XCTAssertEqual(counter.count(b), 1)
    }

    func testMissingTextIsNotCachedAsAbsent() async {
        let a = UUID()
        let (index, counter) = makeIndex([:])
        _ = await index.search("слово", among: [a])
        _ = await index.search("слово", among: [a])
        // Текста нет — загрузчик спрашивается снова: файл мог появиться позже.
        XCTAssertEqual(counter.count(a), 2)
    }

    func testUpdateBypassesLoaderAndReplacesText() async {
        let a = UUID()
        let (index, counter) = makeIndex([a: "старый текст"])

        await index.update(a, text: "новый текст")
        let fresh = await index.search("новый", among: [a])
        let stale = await index.search("старый", among: [a])

        XCTAssertEqual(fresh, [a: "новый текст"])
        XCTAssertTrue(stale.isEmpty)
        XCTAssertEqual(counter.count(a), 0)
    }

    func testRemoveDropsCachedText() async {
        let a = UUID(), b = UUID()
        let (index, counter) = makeIndex([:])
        await index.update(a, text: "ключ")
        await index.update(b, text: "ключ")

        await index.remove([a])
        let result = await index.search("ключ", among: [a, b])

        // У удалённой записи текста больше нет ни в кеше, ни у загрузчика.
        XCTAssertEqual(Set(result.keys), [b])
        XCTAssertEqual(counter.count(a), 1)
        XCTAssertEqual(counter.count(b), 0)
    }

    func testRemoveAllResetsCache() async {
        let a = UUID()
        let (index, counter) = makeIndex([a: "ключ"])

        _ = await index.search("ключ", among: [a])
        await index.removeAll()
        let result = await index.search("ключ", among: [a])

        XCTAssertEqual(result, [a: "ключ"])
        XCTAssertEqual(counter.count(a), 2)
    }

    func testCancelledSearchStopsWithoutCrashing() async {
        let ids = (0..<50).map { _ in UUID() }
        let texts = Dictionary(uniqueKeysWithValues: ids.map { ($0, "ключ") })
        let (index, counter) = makeIndex(texts)

        let task = Task { () -> [UUID: String] in
            // Отмена ДО вызова — детерминированно: проверка идёт перед первой записью.
            withUnsafeCurrentTask { $0?.cancel() }
            return await index.search("ключ", among: ids)
        }
        let result = await task.value

        XCTAssertTrue(result.isEmpty)
        XCTAssertEqual(counter.total, 0)

        // Индекс после отмены остаётся рабочим.
        let after = await index.search("ключ", among: ids)
        XCTAssertEqual(after.count, ids.count)
    }
}
