import Foundation

/// Дежурные фразы, которые Whisper выдаёт на почти тишине: он учился на
/// субтитрах YouTube, где тишина в конце ролика — «Спасибо за просмотр».
/// Замер: 1 с тишины даёт «Продолжение следует...» (language=ru) или «You»
/// (автоопределение), причём сам Whisper ставит `no_speech_prob` 0.0 — по его
/// оценке такой мусор не отсеять. От тишины защищает гейт, но в тихом режиме
/// его порог низкий, и короткая пустая запись с шорохом проходила и вставляла
/// «Thank you.». Чистая функция — покрыта тестами.
///
/// Два случая: результат ЦЕЛИКОМ (или повтор одной такой фразы) — это пустая
/// запись (`isHallucination`), а фраза, приклеенная к КОНЦУ настоящей
/// диктовки, — тишина, на которой человек закончил запись
/// (`trimmingTrailingArtifacts`). Внутри фразы эти слова — обычный текст.
enum HallucinationFilter {
    /// Никогда не диктуются сами по себе — отсекаем в любом режиме.
    private static let subtitleArtifacts: [[String]] = [
        "продолжение следует",
        "субтитры сделал dimatorzok",
        "субтитры создавал dimatorzok",
        "субтитры делал dimatorzok",
        "редактор субтитров а синецкая корректор а егорова",
        "спасибо за просмотр",
        "подписывайтесь на канал",
        "thanks for watching",
        "thank you for watching",
    ].map(words)

    /// Английские дежурные фразы. Whisper выдаёт их и при language=ru: whisper-1
    /// у Nexara дописывал «Thank you.» и «you» к русским диктовкам, на тишине
    /// перед остановкой записи. Длинные — раньше: «thank you» прежде «you».
    private static let englishCourtesies: [[String]] = [
        "thank you",
        "thanks",
        "you",
        "bye",
    ].map(words)

    /// Днём «Спасибо» вслух — нормальная короткая диктовка (ответ в чате), её
    /// не трогаем. В тихом режиме шёпот от шороха по громкости не отличить
    /// (у настоящих шёпотных фраз 0,2–0,3 с над порогом, у шороха — столько же),
    /// поэтому там такая фраза целиком — почти наверняка тишина.
    private static let quietOnlyArtifacts: [[String]] = [
        "спасибо",
        "спасибо за внимание",
    ].map(words) + englishCourtesies

    /// `language` — язык диктовки из настроек: при явно выбранном НЕанглийском
    /// языке английская дежурная фраза целиком — тишина в любом режиме
    /// («you» на записи с 0,4 с речи при language=ru).
    static func isHallucination(_ text: String, quiet: Bool, language: String? = nil) -> Bool {
        let tokens = words(text)
        guard !tokens.isEmpty else { return false }
        var candidates = subtitleArtifacts
        if quiet {
            candidates += quietOnlyArtifacts
        } else if isExplicitNonEnglish(language) {
            candidates += englishCourtesies
        }
        return candidates.contains { isRepetition(tokens, of: $0) }
    }

    /// Срезает дежурные фразы с КОНЦА настоящей диктовки: «…мало ли что вдруг.
    /// Thank you.», «…сделать? you», «…приложу Продолжение следует...».
    /// Английская фраза срезается, только если перед ней кириллическое слово:
    /// «I love you» и английский текст не трогаются. Знаки конца предложения
    /// перед хвостом остаются, висячие запятая и тире — уходят. Текст, который
    /// весь состоит из дежурной фразы, возвращается как есть — это случай
    /// `isHallucination`.
    static func trimmingTrailingArtifacts(_ text: String) -> String {
        var result = text
        while let cut = trailingArtifactStart(in: result) {
            result = String(result[..<cut])
            while let last = result.last, last.isWhitespace || danglingSeparators.contains(last) {
                result.removeLast()
            }
        }
        return result
    }

    private static let danglingSeparators: Set<Character> = [",", ";", ":", "-", "–", "—"]

    /// Начало дежурной фразы в конце текста, если перед ней есть другой текст.
    private static func trailingArtifactStart(in text: String) -> String.Index? {
        let tokens = wordTokens(text)
        let words = tokens.map(\.word)
        for phrase in subtitleArtifacts where words.count > phrase.count && words.suffix(phrase.count).elementsEqual(phrase) {
            return tokens[words.count - phrase.count].range.lowerBound
        }
        // Английские — подряд идущей серией («Thank you. Thank you.»): перед
        // всей серией должно стоять русское слово.
        var start = words.count
        matching: while start > 0 {
            for phrase in englishCourtesies where start >= phrase.count
                && words[(start - phrase.count)..<start].elementsEqual(phrase) {
                start -= phrase.count
                continue matching
            }
            break
        }
        guard start < words.count, start > 0, isCyrillic(words[start - 1]) else { return nil }
        return tokens[start].range.lowerBound
    }

    private static func isExplicitNonEnglish(_ language: String?) -> Bool {
        guard let language, language != "auto" else { return false }
        return !language.lowercased().hasPrefix("en")
    }

    private static func isCyrillic(_ word: String) -> Bool {
        word.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }
    }

    /// Слова без регистра, ё = е, без пунктуации: «А.Синецкая» → «а синецкая».
    private static func words(_ text: String) -> [String] {
        wordTokens(text).map(\.word)
    }

    /// Слова вместе с их местом в исходной строке — по нему режется хвост.
    private static func wordTokens(_ text: String) -> [(word: String, range: Range<String.Index>)] {
        var tokens: [(word: String, range: Range<String.Index>)] = []
        func append(_ range: Range<String.Index>) {
            tokens.append((text[range].lowercased().replacingOccurrences(of: "ё", with: "е"), range))
        }
        var start: String.Index?
        for index in text.indices {
            if text[index].isLetter || text[index].isNumber {
                if start == nil { start = index }
            } else if let wordStart = start {
                append(wordStart..<index)
                start = nil
            }
        }
        if let wordStart = start { append(wordStart..<text.endIndex) }
        return tokens
    }

    /// `tokens` — это `phrase`, повторённая один или несколько раз.
    private static func isRepetition(_ tokens: [String], of phrase: [String]) -> Bool {
        guard !phrase.isEmpty, tokens.count % phrase.count == 0 else { return false }
        return stride(from: 0, to: tokens.count, by: phrase.count).allSatisfy {
            Array(tokens[$0..<$0 + phrase.count]) == phrase
        }
    }
}
