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

    private enum CodingKeys: String, CodingKey {
        case id, from, to, enabled, matchInsideWords
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
enum ReplacementEngine {
    static func apply(_ text: String, rules: [ReplacementRule]) -> String {
        var result = text
        // Длинные шаблоны первыми, чтобы короткие не разрывали длинные.
        let active = rules
            .filter { $0.enabled && !$0.from.isEmpty }
            .sorted { $0.from.count > $1.from.count }
        for rule in active {
            result = replaceAll(in: result, rule: rule)
        }
        return result
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
        let needsLeft = !rule.matchInsideWords && (rule.from.first.map(isWordCharacter) ?? false)
        let needsRight = !rule.matchInsideWords && (rule.from.last.map(isWordCharacter) ?? false)

        var output = ""
        var copiedUpTo = text.startIndex
        var searchFrom = text.startIndex
        while searchFrom < text.endIndex,
              let found = text.range(of: rule.from, options: [.caseInsensitive],
                                     range: searchFrom..<text.endIndex) {
            let leftOK = !needsLeft
                || found.lowerBound == text.startIndex
                || !isWordCharacter(text[text.index(before: found.lowerBound)])
            let rightOK = !needsRight
                || found.upperBound == text.endIndex
                || !isWordCharacter(text[found.upperBound])
            if leftOK && rightOK {
                output += text[copiedUpTo..<found.lowerBound]
                output += casedReplacement(rule, matched: text[found], in: text)
                copiedUpTo = found.upperBound
                searchFrom = found.upperBound
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

    private static let sentenceEnds: Set<Character> = [".", "!", "?", "…"]
    private static let openers: Set<Character> = ["«", "\"", "„", "“", "(", "["]
}
