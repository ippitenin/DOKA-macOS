import Foundation

/// Фраза окна «Тренировка»: что показать и откуда она.
struct LipTrainingPhrase: Equatable, Hashable, Sendable {
    /// Откуда фраза; `rawValue` идёт в поле `model` пары (`LipCaption.training`).
    enum Origin: String, Sendable {
        /// Предложение из истории диктовок — своя лексика.
        case history
        /// Готовый список, рабочие фразы.
        case work
        /// Готовый список, бытовые фразы.
        case everyday

        /// Подпись в карточке фразы.
        var title: String {
            switch self {
            case .history: return L("training.origin.history")
            case .work: return L("training.origin.work")
            case .everyday: return L("training.origin.everyday")
            }
        }
    }

    let text: String
    let origin: Origin
}

/// Источники фраз тренировки — история диктовок и готовый список
/// (`Resources/TrainingPhrases.ru.txt`). Чистая логика.
///
/// Фраза проговаривается одними губами, поэтому годится не всякая: цифры и
/// латиницу губами однозначно не прочесть («пять» или «5», «DOKA» или
/// «дока»), а длинная фраза не уложится в 13 секунд дубля.
enum LipTrainingPhrases {
    static let minWords = 3
    static let maxWords = 12
    static let maxCharacters = 90

    /// Годится ли фраза: 3–12 слов, не длиннее 90 символов, только кириллица,
    /// пробелы и простая пунктуация.
    static func isSuitable(_ text: String) -> Bool {
        guard !text.isEmpty, text.count <= maxCharacters else { return false }
        for scalar in text.unicodeScalars {
            if isCyrillicLetter(scalar) || scalar.properties.isWhitespace
                || allowedPunctuation.contains(scalar) { continue }
            return false
        }
        let words = text.split(whereSeparator: \.isWhitespace).filter { $0.contains(where: \.isLetter) }
        return (minWords...maxWords).contains(words.count)
    }

    private static let allowedPunctuation: Set<Unicode.Scalar> = [
        ",", ".", "!", "?", "…", "-", "‐", "–", "—", ":", ";", "«", "»", "\"", "„", "“", "”", "(", ")",
    ]

    private static func isCyrillicLetter(_ scalar: Unicode.Scalar) -> Bool {
        (0x0410...0x044F).contains(scalar.value) || scalar == "ё" || scalar == "Ё"
    }

    /// Ключ сравнения фраз: регистр и «ё» не важны, пунктуация тоже — «Ещё
    /// раз!» и «еще раз» одна фраза. Основа — нормализация поиска библиотеки.
    static func normalize(_ text: String) -> String {
        let letters = LibrarySearch.normalize(text).map { $0.isLetter ? $0 : " " }
        return String(letters).split(separator: " ").joined(separator: " ")
    }

    /// Предложения из текстов истории, годные для тренировки, без повторов,
    /// в порядке первого появления.
    static func fromHistory(_ texts: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for text in texts {
            for sentence in sentences(text) where isSuitable(sentence) {
                if seen.insert(normalize(sentence)).inserted { result.append(sentence) }
            }
        }
        return result
    }

    /// Деление на предложения: после `.`, `!`, `?`, `…` (подряд идущие
    /// знаки остаются с предложением) и по переводу строки.
    static func sentences(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        var afterTerminator = false
        func flush() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { result.append(trimmed) }
            current = ""
        }
        for character in text {
            if character.isNewline {
                flush()
                afterTerminator = false
                continue
            }
            let isTerminator = terminators.contains(character)
            if afterTerminator, !isTerminator {
                flush()
            }
            current.append(character)
            afterTerminator = isTerminator
        }
        flush()
        return result
    }

    private static let terminators: Set<Character> = [".", "!", "?", "…"]

    // MARK: - Готовый список

    /// Разбор файла списка: `#` — комментарий, `[work]`/`[everyday]` —
    /// раздел, остальные непустые строки — фразы раздела. Строки до первого
    /// раздела не учитываются.
    static func parseBuiltin(_ contents: String) -> [LipTrainingPhrase] {
        var origin: LipTrainingPhrase.Origin?
        var phrases: [LipTrainingPhrase] = []
        for line in contents.split(whereSeparator: \.isNewline) {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.isEmpty || text.hasPrefix("#") { continue }
            if text.hasPrefix("["), text.hasSuffix("]") {
                origin = LipTrainingPhrase.Origin(rawValue: String(text.dropFirst().dropLast()))
                continue
            }
            if let origin { phrases.append(LipTrainingPhrase(text: text, origin: origin)) }
        }
        return phrases
    }

    /// Готовый список из бандла. Только русский: модель губ WISLIP русская,
    /// и в английском интерфейсе фразы те же.
    static func builtin(bundle: Bundle = .module) -> [LipTrainingPhrase] {
        guard let url = bundle.url(forResource: "TrainingPhrases.ru", withExtension: "txt"),
              let contents = try? String(contentsOf: url, encoding: .utf8) else {
            NSLog("DOKA: тренировка — список фраз не найден в бандле")
            return []
        }
        return parseBuiltin(contents)
    }
}
