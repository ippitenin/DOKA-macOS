import Foundation
import NaturalLanguage

/// Подстраховка сетевого распознавания диктовки: решает, похож ли ответ
/// сервиса на сбой, и что делать дальше. Чистая логика — покрыта тестами;
/// второе мнение (Parakeet) и повторный запрос делает `DictationController`.
///
/// Два сбоя, оба пойманы на дублях «Губ» владельца (281 диктовка с языком
/// «Авто», Nexara whisper-1, 10–17.10.2026):
/// - **Слов слишком мало для такой длинной речи** — сервис вернул одно-два
///   предложения из 15–30 с речи (5 случаев: 0,35–0,53 слова на секунду речи,
///   у обычных диктовок — от 0,92). Повторный запрос того же файла 4 из 5
///   распознал целиком, а один сервис режет каждый раз — там выручает текст
///   Parakeet.
/// - **Чужая письменность** — русская фраза вставилась английским переводом
///   (2 случая: «Put a copy on the work table.»). Повтор распознал по-русски.
///   Настоящая английская диктовка выглядит так же, поэтому решает второе
///   мнение: Parakeet пишет на том языке, на котором говорят, а не переводит.
///
/// Сравниваются письменности, а не языки: `NLLanguageRecognizer` принимает
/// часть русских фраз за казахские, украинские или болгарские (6 из 466
/// диктовок владельца), а перевод на английский всегда меняет и алфавит.
/// Подозрителен ответ, где нет НИ ОДНОЙ буквы привычной письменности: в
/// русской фразе «Открой Figma и README» латинских букв больше, но кириллица
/// есть, и перевода тут нет.
enum RecognitionCheck {
    enum Script: Equatable {
        case cyrillic, latin, other
    }

    /// Привычный язык пользователя — по его последним диктовкам. `language` —
    /// код для явного повторного запроса, `script` — с чем сравнивать ответы.
    struct Usual: Equatable {
        let language: String
        let script: Script
    }

    enum Suspicion: Equatable {
        /// «Авто» дало текст без единой буквы той письменности, которой человек диктует.
        case unusualScript(Usual)
        /// Слов мало для такой длинной речи — сервис потерял часть записи.
        case tooFewWords
    }

    enum Verdict: Equatable {
        case keep
        /// Повторный запрос; `language` — явный язык, nil — тот же, что у первого.
        case retry(language: String?)
    }

    /// Проверка числа слов — только у записей хотя бы с таким временем речи:
    /// у коротких фраз темп скачет от паузы перед первым словом.
    static let minSpeechForWordCheck: TimeInterval = 5
    /// Слов на секунду речи ниже порога — подозрение на потерю.
    static let minWordsPerSpeechSecond = 0.7
    /// Сколько последних диктовок задают привычный язык и сколько их нужно минимум.
    static let usualSampleSize = 30
    static let usualMinimumSample = 5

    /// Привычный язык по последним диктовкам (новые — первыми). nil — истории
    /// мало, и сравнивать не с чем: такой результат не считается подозрительным.
    static func usual(fromRecentTexts texts: [String]) -> Usual? {
        let sample = texts.prefix(usualSampleSize)
        guard sample.count >= usualMinimumSample else { return nil }
        // Язык — голосованием по фразам, а не по склейке: одна длинная русская
        // фраза, которую `NLLanguageRecognizer` уверенно зовёт казахской,
        // перетягивает на себя всю склейку (9 из 400 проб по истории
        // владельца — kk, bg, uk), и повтор ушёл бы с чужим языком. По фразам
        // такая одна на 30, большинство её перекрывает. Письменность по
        // склейке надёжна: англицизмы десятков диктовок большинства не дают.
        var votes: [String: Int] = [:]
        for text in sample {
            if let code = languageCode(of: text) { votes[code, default: 0] += 1 }
        }
        // При равенстве голосов — меньший код, чтобы ответ не зависел от порядка словаря.
        guard let language = votes.max(by: { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key })?.key
        else { return nil }
        return Usual(language: language, script: script(of: sample.joined(separator: "\n")))
    }

    static func suspicion(text: String, speechSeconds: TimeInterval,
                          autoLanguage: Bool, usual: Usual?) -> Suspicion? {
        if autoLanguage, let usual, usual.script != .other {
            let found = scripts(in: text)
            if !found.isEmpty, !found.contains(usual.script) { return .unusualScript(usual) }
        }
        if speechSeconds >= minSpeechForWordCheck,
           Double(wordCount(text)) / speechSeconds < minWordsPerSpeechSecond {
            return .tooFewWords
        }
        return nil
    }

    /// Нужен ли повторный запрос. `secondOpinion` — текст Parakeet по тому же
    /// WAV; nil — модели нет или она занята, тогда повтор без перепроверки.
    static func verdict(_ suspicion: Suspicion, text: String, secondOpinion: String?) -> Verdict {
        switch suspicion {
        case .unusualScript(let usual):
            // Без второго мнения — повтор с тем же «Авто»: явный язык на
            // настоящей английской речи дал бы русский перевод.
            guard let secondOpinion else { return .retry(language: nil) }
            return scripts(in: secondOpinion).contains(usual.script) ? .retry(language: usual.language) : .keep
        case .tooFewWords:
            guard let secondOpinion else { return .retry(language: nil) }
            return muchLonger(cleaned(secondOpinion), than: text) ? .retry(language: nil) : .keep
        }
    }

    /// Итоговый текст из первого ответа, повторного и второго мнения.
    static func resolve(_ suspicion: Suspicion, first: String, retry: String?,
                        secondOpinion: String?) -> String {
        switch suspicion {
        case .unusualScript(let usual):
            guard let retry, scripts(in: retry).contains(usual.script) else { return first }
            return retry
        case .tooFewWords:
            var best = first
            if let retry, wordCount(retry) > wordCount(first) { best = retry }
            // Сервис режет эту запись при любом повторе, а Parakeet слышит её
            // целиком: потерять полдиктовки хуже, чем пунктуация попроще.
            if let secondOpinion {
                let local = cleaned(secondOpinion)
                if muchLonger(local, than: best) { return local }
            }
            return best
        }
    }

    // MARK: - Текст

    static func wordCount(_ text: String) -> Int {
        text.split { !$0.isLetter && !$0.isNumber }.count
    }

    /// Письменность по большинству букв; без букв — `.other`. Только для
    /// склейки десятков диктовок: в одной фразе «Открой Figma и README»
    /// латинских букв больше, хотя фраза русская.
    static func script(of text: String) -> Script {
        var counts: [Script: Int] = [:]
        for script in letterScripts(text) { counts[script, default: 0] += 1 }
        guard let top = counts.values.max() else { return .other }
        if counts[.cyrillic] == top { return .cyrillic }
        return counts[.latin] == top ? .latin : .other
    }

    /// Какие письменности есть в тексте; без букв («2, 3.») — пусто. Так
    /// проверяется отдельный ответ: перевод на чужой язык убирает буквы
    /// привычной письменности целиком, а русская фраза с «Figma» их сохраняет.
    static func scripts(in text: String) -> Set<Script> {
        Set(letterScripts(text))
    }

    private static func letterScripts(_ text: String) -> [Script] {
        text.unicodeScalars.filter { CharacterSet.letters.contains($0) }.map { scalar in
            switch scalar.value {
            case 0x0400...0x04FF: return .cyrillic
            case 0x0041...0x005A, 0x0061...0x007A, 0x00C0...0x024F: return .latin
            default: return .other
            }
        }
    }

    /// Код языка для запроса: «ru», «en» (у «zh-Hans» — «zh»).
    private static func languageCode(of text: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let language = recognizer.dominantLanguage, language != .undetermined else { return nil }
        return language.rawValue.split(separator: "-").first.map(String.init)
    }

    /// Второе мнение намного длиннее: вдвое и хотя бы на 8 слов.
    private static func muchLonger(_ candidate: String, than text: String) -> Bool {
        let a = wordCount(candidate), b = wordCount(text)
        return a >= 2 * b && a >= b + 8
    }

    /// Текст Parakeet без служебного `<unk>` (непонятый кусок слова).
    private static func cleaned(_ text: String) -> String {
        text.replacingOccurrences(of: "<unk>", with: "")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
