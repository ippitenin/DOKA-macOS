import Foundation

/// Правило словаря замен: «что» → «на что».
struct ReplacementRule: Codable, Identifiable, Equatable {
    var id = UUID()
    var from: String
    var to: String
    var enabled = true
    /// Искать и внутри слов — прежнее поведение подстроки (нужно правилам-
    /// нормализаторам вроде «ё» → «е»). По умолчанию правило срабатывает
    /// только на целое слово.
    var matchInsideWords = false
    /// Ловить и падежные формы последнего слова: «телеграм» → Telegram
    /// срабатывает и на «телеграме», «телеграмом». Действует, только когда
    /// замена не кончается кириллической буквой (см. `ReplacementEngine`).
    var matchWordForms = true

    private enum CodingKeys: String, CodingKey {
        case id, from, to, enabled, matchInsideWords, matchWordForms
    }
}

extension ReplacementRule {
    /// Ручной декодер: синтезированный Decodable не подставляет значения по
    /// умолчанию для отсутствующих ключей — старый словарь без
    /// `matchInsideWords` уронил бы декод всего массива, и `SettingsStore`
    /// молча обнулил бы словарь пользователя. В расширении — чтобы остался
    /// синтезированный memberwise-init.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        from = try c.decode(String.self, forKey: .from)
        to = try c.decode(String.self, forKey: .to)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        matchInsideWords = try c.decodeIfPresent(Bool.self, forKey: .matchInsideWords) ?? false
        matchWordForms = try c.decodeIfPresent(Bool.self, forKey: .matchWordForms) ?? true
    }
}

/// Применяет словарь замен к готовой транскрипции перед вставкой.
///
/// Совпадение — по целому слову: граница проверяется только с той стороны,
/// где шаблон начинается или кончается символом слова (буква или цифра любой
/// письменности). Шаблон, который сам начинается или кончается пунктуацией,
/// пробелом или эмодзи, на этом краю срабатывает где угодно — пользователь
/// сам включил разделитель в правило («э-э, » → «»). Как и у `\b` в
/// регулярках, дефис и апостроф — разделители: «кто» → «who» превратит
/// «кто-то» в «who-то».
///
/// Регистр замены — как в правиле, кроме одного случая: найденное начинается
/// с заглавной, замена — со строчной, и это начало предложения (или правило
/// однобуквенное). Тогда первая буква замены поднимается: «Stories тоже
/// сделаем» с «stories» → «сторис» даёт «Сторис тоже сделаем».
///
/// Формы слова (`matchWordForms`): последнее слово шаблона — кириллица с
/// основой от 4 букв (слово без конечной гласной, «ь» или «й»), а замена не
/// кончается кириллической буквой. Тогда совпадением считается основа плюс
/// одно падежное окончание, и окончание отбрасывается: «в телеграме» →
/// «в Telegram». В кириллическую замену окончание не переносится («машиной» →
/// «автомобилой» было бы хуже) — такие правила ловят только точное слово.
/// Порог основы бережёт короткие шаблоны: «МД» не поймает «мда».
enum ReplacementEngine {
    static func apply(_ text: String, rules: [ReplacementRule]) -> String {
        var result = text
        // Длинные шаблоны первыми, чтобы короткие не разрывали длинные.
        let active = rules
            .filter { $0.enabled && !$0.from.isEmpty }
            .sorted { $0.from.count > $1.from.count }
        // Отсев: правило, чьего шаблона нет в тексте даже без учёта регистра,
        // пропускается одним `memmem` по байтам — без него системный словарь
        // (сотни правил) на расшифровке в 100 тыс. знаков шёл секунды: каждое
        // правило сканировало текст поиском с учётом регистра.
        var lowered = Array(text.lowercased().utf8)
        for rule in active {
            let probe = Array((formsStem(of: rule) ?? rule.from).lowercased().utf8)
            guard contains(lowered, probe) else { continue }
            let replaced = replaceAll(in: result, rule: rule)
            if replaced != result {
                result = replaced
                lowered = Array(result.lowercased().utf8)
            }
        }
        return result
    }

    private static func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty else { return true }
        return haystack.withUnsafeBytes { h in
            needle.withUnsafeBytes { n in
                memmem(h.baseAddress, h.count, n.baseAddress, n.count) != nil
            }
        }
    }

    /// Символ «слова» для проверки границ: буква или цифра любой письменности
    /// (`Character` — кластер графем, «й» с комбинирующим знаком — одна буква).
    static func isWordCharacter(_ c: Character) -> Bool {
        c.isLetter || c.isNumber
    }

    /// Один проход правила. Строка пересобирается без переиспользования
    /// индексов после мутации: вставленный текст не сканируется повторно —
    /// нет ни крашей на устаревших индексах, ни бесконечных циклов при
    /// to ⊇ from. Границы проверяются по ИСХОДНОЙ строке прохода.
    private static func replaceAll(in text: String, rule: ReplacementRule) -> String {
        // С формами ищется шаблон до основы, окончание проверяется после.
        let stem = formsStem(of: rule)
        let pattern = stem ?? rule.from
        let needsLeft = !rule.matchInsideWords && (rule.from.first.map(isWordCharacter) ?? false)
        let needsRight = !rule.matchInsideWords && (rule.from.last.map(isWordCharacter) ?? false)

        var output = ""
        var copiedUpTo = text.startIndex
        var searchFrom = text.startIndex
        while searchFrom < text.endIndex,
              let found = text.range(of: pattern, options: [.caseInsensitive],
                                     range: searchFrom..<text.endIndex) {
            let leftOK = !needsLeft
                || found.lowerBound == text.startIndex
                || !isWordCharacter(text[text.index(before: found.lowerBound)])
            let end: String.Index?
            if stem != nil {
                end = endOfForm(in: text, at: found.upperBound)
                    .flatMap { formExceptions.contains(text[found.lowerBound..<$0].lowercased()) ? nil : $0 }
            } else if !needsRight || found.upperBound == text.endIndex || !isWordCharacter(text[found.upperBound]) {
                end = found.upperBound
            } else {
                end = nil
            }
            if leftOK, let end {
                output += text[copiedUpTo..<found.lowerBound]
                output += casedReplacement(rule, matched: text[found.lowerBound..<end], in: text)
                copiedUpTo = end
                searchFrom = end
            } else {
                // Не с upperBound: иначе пропустится перекрывающееся валидное
                // совпадение («дада да» с правилом «да» → «нет»).
                searchFrom = text.index(after: found.lowerBound)
            }
        }
        output += text[copiedUpTo...]
        return output
    }

    /// Замена с заглавной, если найденное начинается с заглавной, а замена —
    /// со строчной, и совпадение открывает предложение или правило из одного
    /// символа («Ёлка» с «ё» → «е» — «Елка»). В середине предложения — как в
    /// правиле: Whisper пишет «вышел Reels» с заглавной и там, а правило
    /// «Reels» → «рилс» просит строчную. Повторный проход ничего не меняет:
    /// результат начинается с заглавной, и подъём ему не нужен.
    private static func casedReplacement(_ rule: ReplacementRule, matched: Substring,
                                         in text: String) -> String {
        guard let first = rule.to.first, first.isLowercase,
              matched.first?.isUppercase == true,
              rule.from.count == 1 || opensSentence(text, at: matched.startIndex) else { return rule.to }
        return first.uppercased() + rule.to.dropFirst()
    }

    /// Начало предложения: перед позицией — начало текста, конец предложения
    /// (`.`, `!`, `?`, `…`) или перевод строки; пробелы и открывающие кавычки
    /// и скобки между ними не в счёт. После двоеточия — не начало.
    static func opensSentence(_ text: String, at index: String.Index) -> Bool {
        var i = index
        while i > text.startIndex {
            i = text.index(before: i)
            let c = text[i]
            if c.isNewline || sentenceEnds.contains(c) { return true }
            if c.isWhitespace || openers.contains(c) { continue }
            return false
        }
        return true
    }

    // MARK: - Формы слова

    /// Шаблон до основы последнего слова, если правило ловит формы; nil —
    /// только точное совпадение. «телеграм» → «телеграм», «фигма» → «фигм»,
    /// «гугл клауд» → «гугл клауд»; «МД», «апи», «дока» — nil (основа < 4).
    static func formsStem(of rule: ReplacementRule) -> String? {
        guard rule.matchWordForms, !rule.matchInsideWords,
              !(rule.to.last.map(isCyrillicLetter) ?? false),
              let lastWord = rule.from.split(whereSeparator: \.isWhitespace).last,
              rule.from.last.map(isCyrillicLetter) ?? false,
              lastWord.allSatisfy(isCyrillicLetter) else { return nil }
        let dropped = lastWord.last.map { stemEndings.contains(Character($0.lowercased())) } ?? false
        guard lastWord.count - (dropped ? 1 : 0) >= minStemLength else { return nil }
        return String(rule.from.dropLast(dropped ? 1 : 0))
    }

    /// Конец формы после основы: самое длинное окончание из списка (или
    /// пустое), за которым граница слова. nil — после основы идёт что-то
    /// другое («телеграм|ма», «телеграм|ный»).
    private static func endOfForm(in text: String, at start: String.Index) -> String.Index? {
        let tail = text[start...].prefix(3).lowercased()
        for ending in endings where tail.hasPrefix(ending) {
            let end = text.index(start, offsetBy: ending.count)
            if end == text.endIndex || !isWordCharacter(text[end]) { return end }
        }
        return nil
    }

    static func isCyrillicLetter(_ c: Character) -> Bool {
        guard let scalar = c.unicodeScalars.first, c.unicodeScalars.count == 1 else { return false }
        return (0x0410...0x044F).contains(scalar.value) || scalar == "ё" || scalar == "Ё"
    }

    /// Формы, которые на деле — другие слова: «гугли», «гуглю» — глагол
    /// «гуглить», а не «Google». Найдены проверкой орфографией macOS по всем
    /// формам системного словаря; шаблоны, у которых таких форм много
    /// («убер» — «уберём»), в словарь просто не входят.
    static let formExceptions: Set<String> = ["гугли", "гуглю", "гугля"]

    static let minStemLength = 4
    /// Конечные буквы, которые основа теряет: «фигма» → «фигм», «эксель» → «эксел».
    private static let stemEndings: Set<Character> = ["а", "я", "о", "е", "ё", "ы", "и", "у", "ю", "й", "ь"]
    /// Падежные окончания, от длинных к коротким; пустое — сама основа.
    private static let endings: [String] = [
        "ами", "ями",
        "ом", "ем", "ём", "ой", "ей", "ою", "ею", "ов", "ев", "ам", "ям", "ах", "ях",
        "а", "я", "о", "е", "ё", "ы", "и", "у", "ю", "й", "ь",
        "",
    ]

    private static let sentenceEnds: Set<Character> = [".", "!", "?", "…"]
    private static let openers: Set<Character> = ["«", "\"", "„", "“", "(", "["]
}
