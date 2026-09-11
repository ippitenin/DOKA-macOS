import Foundation

/// Поиск по библиотеке файловых транскрибаций: нормализация, токены запроса,
/// проверка совпадения и сниппет вокруг найденного. Чистые детерминированные
/// функции (как `TranscriptFormatter` и `WordCount`) — состояние и кеш текстов
/// живут в `TranscriptTextIndex`.
///
/// Поиск — подстрокой по нормализованному тексту, все слова запроса обязательны
/// (AND). Морфологии и ранжирования нет намеренно: пользователь ищет «ту самую
/// встречу», где звучало слово, а не релевантность по корпусу.
enum LibrarySearch {

    // MARK: - Нормализация

    /// Нормализация для поиска: регистр снимается, «ё» приравнивается к «е»
    /// (в расшифровках буква ставится непредсказуемо — то есть, то нет).
    ///
    /// Посимвольная по `Character` намеренно: результат содержит РОВНО столько же
    /// символов, сколько исходник, и символ N нормализованной строки соответствует
    /// символу N исходной — на этом держится вырезка сниппета из оригинала
    /// по смещениям, найденным в нормализованной копии.
    ///
    /// `.diacriticInsensitive`/`folding` НЕ используется: он раскладывает «й»
    /// в «и» + бреве и выбрасывает знак, после чего «мой» находил бы «мои».
    static func normalize(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.utf8.count)
        for character in text {
            result.append(normalize(character))
        }
        return result
    }

    /// Нормализованные токены запроса: разбиение по пробельным символам
    /// (включая переводы строк и табы), пустые отброшены.
    static func tokens(_ query: String) -> [String] {
        normalize(query)
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
    }

    // MARK: - Совпадение

    /// Все токены (AND) встречаются в нормализованном тексте подстрокой.
    /// Пустой список токенов — «фильтра нет», совпадает всё.
    static func matches(normalizedHaystack: String, tokens: [String]) -> Bool {
        tokens.allSatisfy { byteOffset(of: $0, in: normalizedHaystack) != nil }
    }

    // MARK: - Сниппет

    /// Фрагмент исходного текста вокруг первого вхождения первого найденного
    /// токена запроса: ±`radius` символов, «…» только с обрезанной стороны,
    /// переводы строк и табы схлопнуты в один пробел. `nil` — запрос пуст
    /// или ни один токен не найден.
    static func snippet(in text: String, query: String, radius: Int = 40) -> String? {
        let tokens = tokens(query)
        guard !tokens.isEmpty else { return nil }
        return snippet(original: text, normalized: normalize(text), tokens: tokens, radius: radius)
    }

    /// Сниппет по уже нормализованному тексту — `TranscriptTextIndex` держит
    /// нормализованную копию в кеше, пересчитывать её на каждый поиск незачем.
    /// `normalized` обязан быть получен `normalize(original)`: смещения
    /// символов у них общие.
    static func snippet(original: String,
                        normalized: String,
                        tokens: [String],
                        radius: Int = 40) -> String? {
        let radius = max(0, radius)
        for token in tokens {
            guard let offset = byteOffset(of: token, in: normalized) else { continue }

            // Байтовое смещение переводим в символьное: в исходнике те же символы
            // могут занимать другое число байт (у «İ» 2 байта, у её строчной — 3),
            // общим остаётся только номер символа. Счёт идёт от начала строки
            // до вхождения — для частых слов это близко к началу, поэтому дёшево.
            let target = normalized.utf8.index(normalized.startIndex, offsetBy: offset)
            let matchStart = characterOffset(of: target, in: normalized)
            let lower = max(0, matchStart - radius)
            let upper = matchStart + token.count + radius

            let start = original.index(original.startIndex, offsetBy: lower,
                                       limitedBy: original.endIndex) ?? original.endIndex
            let end = original.index(start, offsetBy: upper - lower,
                                     limitedBy: original.endIndex) ?? original.endIndex

            // «…» ставится, только если за срезом остался настоящий текст, а не
            // хвостовые пробелы/переводы строк. Поиск останавливается на первом
            // непробельном символе, поэтому полного прохода по тексту нет.
            let cutBefore = original[..<start].contains { !$0.isWhitespace }
            let cutAfter = original[end...].contains { !$0.isWhitespace }

            let body = collapsingWhitespace(original[start..<end])
            return (cutBefore ? "…" : "") + body + (cutAfter ? "…" : "")
        }
        return nil
    }

    // MARK: - Внутреннее

    /// Нормализация одного символа. Всегда возвращает ровно один `Character` —
    /// если преобразование дало бы больше (или меньше), символ остаётся как есть.
    private static func normalize(_ character: Character) -> Character {
        let scalars = character.unicodeScalars
        if scalars.count == 1, let scalar = scalars.first {
            // Быстрый путь: подавляющее большинство символов текста — один скаляр,
            // и строить для каждого временную String незачем.
            if scalar == "ё" || scalar == "Ё" { return "е" }
            guard scalar.properties.changesWhenLowercased else { return character }
            return single(scalar.properties.lowercaseMapping) ?? character
        }
        // Составной символ (буква + комбинируемые знаки) приводится к NFC:
        // «и» + бреве из разложенного текста должно совпасть с готовой «й»,
        // а «е» + диерезис — стать «ё» и дальше «е». Байтовый поиск канонической
        // эквивалентности сам не знает.
        let lowered = String(character).lowercased().precomposedStringWithCanonicalMapping
        guard let result = single(lowered) else { return character }
        return result == "ё" ? "е" : result
    }

    private static func single(_ string: String) -> Character? {
        string.count == 1 ? string.first : nil
    }

    /// Смещение первого вхождения `needle` в байтах UTF-8 либо `nil`.
    ///
    /// Сравнение байтов, а не `Character`: сотни–тысячи расшифровок по десяткам
    /// тысяч символов проверяются на каждое нажатие клавиши в поле поиска,
    /// и `memmem` здесь на порядок быстрее посимвольного сравнения
    /// (`Character ==` каждый раз учитывает каноническую эквивалентность).
    /// UTF-8 самосинхронизируется: вхождение корректной строки не может начаться
    /// посреди многобайтового скаляра, поэтому ложных совпадений по байтам нет.
    private static func byteOffset(of needle: String, in haystack: String) -> Int? {
        guard !needle.isEmpty, needle.utf8.count <= haystack.utf8.count else { return nil }
        // withUTF8 — мутирующий: у нативных строк он ничего не копирует,
        // у мостовых (NSString) один раз делает непрерывную копию.
        var haystack = haystack
        var needle = needle
        return haystack.withUTF8 { big in
            needle.withUTF8 { little -> Int? in
                guard let bigBase = big.baseAddress,
                      let littleBase = little.baseAddress,
                      let found = memmem(bigBase, big.count, littleBase, little.count)
                else { return nil }
                return UnsafeRawPointer(found) - UnsafeRawPointer(bigBase)
            }
        }
    }

    /// Номер символа, в котором лежит `target` (с округлением вниз: вхождение
    /// токена может начаться на базовой букве составного символа, например «е»
    /// внутри «е» + ударение, — тогда номер указывает на сам этот символ).
    private static func characterOffset(of target: String.Index, in string: String) -> Int {
        var offset = 0
        var index = string.startIndex
        while index < string.endIndex {
            let next = string.index(after: index)
            if next > target { break }
            index = next
            offset += 1
        }
        return offset
    }

    /// Любые пробельные прогоны (переводы строк, табы, `\r\n`) — в один пробел,
    /// края обрезаны: сниппет — одна строка для карточки списка.
    private static func collapsingWhitespace(_ text: Substring) -> String {
        var result = ""
        result.reserveCapacity(text.utf8.count)
        var pendingSpace = false
        for character in text {
            if character.isWhitespace {
                pendingSpace = true
                continue
            }
            if pendingSpace && !result.isEmpty { result.append(" ") }
            pendingSpace = false
            result.append(character)
        }
        return result
    }
}
