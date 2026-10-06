import Foundation

/// Подсказки ИИ по спикерам записи: настоящие имена говорящих (по
/// представлениям и обращениям в разговоре) и спикеры-дубликаты, на которых
/// разметка по голосу разделила одного человека. По смыслу — как у Memento.
///
/// Разделение труда — по замеру на Qwen3.5-4B: модель хорошо НАХОДИТ имена,
/// но путается, КОМУ они принадлежат (отдала имя упомянутого третьего
/// человека и пропустила обращение с ответом). Поэтому модель только
/// выписывает имена, прозвучавшие как представление или обращение, а
/// принадлежность решает код по правилам (`attribute`): «меня зовут Х» —
/// говорящий; обращение в последней фразе реплики — тот, кто отвечает
/// следом; обращение в начале ответа — тот, кому отвечают; простое
/// упоминание — никому. Дубликаты спикеров — тоже код, а не модель: в замере
/// она предложила склеить двух разных людей с разными именами. Признак
/// разреза надёжнее: реплика одной метки обрывается без точки, а следующая
/// метка продолжает её со строчной буквы. Ничего не меняется без
/// подтверждения пользователя.
enum SpeakerNameSuggester {
    /// Спикер записи в том виде, в каком его видит модель.
    struct Speaker: Equatable {
        /// Канонический id (после слияний) — его переименовывают и сливают.
        let id: String
        /// Метка во входе модели: «S1», «S2»…
        let tag: String
        let label: String
        let hasCustomName: Bool
        let segmentCount: Int
    }

    struct Prepared: Equatable {
        let speakers: [Speaker]
        let lines: [TranscriptLLMInput.Line]
    }

    struct NameSuggestion: Equatable, Identifiable {
        let speakerID: String
        let name: String
        /// Цитата-доказательство из расшифровки; nil — модель не привела.
        let quote: String?
        /// Тайм-код строки с доказательством, секунды.
        let time: Double?

        var id: String { "name:\(speakerID)" }
    }

    struct MergeSuggestion: Equatable, Identifiable {
        /// Кого вливаем — спикер с меньшим числом реплик.
        let sourceID: String
        /// Куда — спикер с бОльшим числом реплик (его имя и цвет остаются).
        let targetID: String
        /// Место разреза: конец одной реплики и начало следующей.
        var quote: String? = nil
        var time: Double? = nil

        var id: String { "merge:\(sourceID)>\(targetID)" }
    }

    struct Suggestions: Equatable {
        var names: [NameSuggestion] = []
        var merges: [MergeSuggestion] = []

        var isEmpty: Bool { names.isEmpty && merges.isEmpty }
    }

    /// Резерв ответа: имена и пары — это сотня-другая токенов.
    static let answerTokens = 512
    /// Запас на системный промпт и разметку чата.
    static let promptOverheadTokens = 900

    // MARK: - Вход

    /// Вход модели из результата С ПРАВКАМИ (до словаря замен) и полосы
    /// спикеров. nil — подсказывать нечего: спикеров нет.
    static func prepare(result: TranscriptResult, roster: [SpeakerInfo]) -> Prepared? {
        guard !roster.isEmpty else { return nil }
        var tags: [String: String] = [:]
        let speakers = roster.enumerated().map { index, info in
            let tag = "S\(index + 1)"
            tags[info.id] = tag
            return Speaker(id: info.id, tag: tag, label: info.label,
                           hasCustomName: info.hasCustomName, segmentCount: info.segmentCount)
        }
        // Тот же построитель строк, что у анализа: склейка подряд идущих
        // реплик и санитизация. Спикеры подменены метками, правок нет —
        // поэтому подпись строки и есть метка.
        let tagged = result.segments.map {
            TranscriptSegment(speaker: $0.speaker.flatMap { tags[$0] }, start: $0.start, end: $0.end, text: $0.text)
        }
        let plain = TranscriptResult(fullText: result.fullText, language: result.language,
                                     duration: result.duration, segments: tagged, rawSegments: tagged,
                                     words: [], llmOutput: nil)
        let input = TranscriptLLMInput.build(title: "", result: plain)
        guard !input.isEmpty else { return nil }
        return Prepared(speakers: speakers, lines: input.lines)
    }

    /// Сколько первых строк влезает в бюджет токенов. Строки не режутся:
    /// реплика — минимальная единица. Пустой результат — не влезает ничего.
    static func fittingLineCount(tokenCounts: [Int], budget: Int) -> Int {
        var used = 0
        for (index, count) in tokenCounts.enumerated() {
            // +1 — перевод строки между репликами.
            used += count + 1
            if used > budget { return index }
        }
        return tokenCounts.count
    }

    // MARK: - Промпт

    static func messages(for prepared: Prepared, lineCount: Int? = nil) -> [LLMMessage] {
        let lines = prepared.lines.prefix(lineCount ?? prepared.lines.count)
        let roster = prepared.speakers.map { speaker -> String in
            var row = "\(speaker.tag) — \(replicas(speaker.segmentCount))"
            if speaker.hasCustomName {
                row += ", имя уже задано пользователем: «\(TranscriptLLMInput.sanitize(speaker.label))»"
            }
            return row
        }.joined(separator: "\n")

        let system = """
        Ты находишь в расшифровке разговора имена говорящих. Отвечай только JSON, \
        без пояснений и без Markdown.
        """
        let user = """
        Расшифровка разговора. Говорящие обозначены метками S1, S2 и т. д. — их расставила \
        автоматическая разметка по голосу.

        Говорящие:
        \(roster)

        Выпиши ВСЕ имена людей, которые звучат в разговоре как:
        - представление («меня зовут Аня», «я Игорь», «это Паша»);
        - обращение к собеседнику («Паша, а ты что думаешь?», «Спасибо, Игорь», «Да, Анна»).
        Для каждого случая — имя ровно так, как оно прозвучало, и тайм-код строки. Одно имя может \
        встретиться несколько раз — выпиши каждый раз. Имена тех, о ком только говорят в третьем \
        лице («Марина пришлёт отчёт»), не выписывай. Названия компаний, городов и продуктов — не имена.

        Формат ответа:
        {"names":[{"name":"Аня","time":"0:42"},{"name":"Паша","time":"1:05"}]}

        Расшифровка:
        \(lines.map(\.rendered).joined(separator: "\n"))
        """
        return [LLMMessage(role: .system, content: system), LLMMessage(role: .user, content: user)]
    }

    private static func replicas(_ count: Int) -> String {
        let mod10 = count % 10, mod100 = count % 100
        let word: String
        if mod10 == 1 && mod100 != 11 {
            word = "реплика"
        } else if (2...4).contains(mod10) && !(12...14).contains(mod100) {
            word = "реплики"
        } else {
            word = "реплик"
        }
        return "\(count) \(word)"
    }

    // MARK: - Разбор ответа

    /// Тайм-код из ответа модели не читается: правила `attribute` сами
    /// проходят по всем строкам, где имя звучит, и берут время оттуда.
    private struct RawAnswer: Decodable {
        struct Name: Decodable {
            let name: String?
        }
        let names: [Lossy<Name>]?
    }

    /// Ответ модели → проверенные предложения. Всё сомнительное отбрасывается
    /// молча: лишнее предложение хуже пропущенного.
    static func parse(_ output: String, prepared: Prepared) -> Suggestions {
        let raw = firstJSONObject(in: output)
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode(RawAnswer.self, from: $0) }
        let names = raw.map { Self.names(from: $0, prepared: prepared) } ?? []
        return Suggestions(names: names, merges: continuationMerges(prepared: prepared, names: names))
    }

    private static func names(from raw: RawAnswer, prepared: Prepared) -> [NameSuggestion] {
        let byTag = Dictionary(prepared.speakers.map { ($0.tag.uppercased(), $0) }, uniquingKeysWith: { a, _ in a })

        // Кандидаты от модели: уникальные имена.
        var candidates: [String] = []
        for entry in (raw.names ?? []).compactMap(\.value) {
            guard let name = cleanName(entry.name),
                  !candidates.contains(where: { $0.lowercased() == name.lowercased() }) else { continue }
            candidates.append(name)
        }
        // Каждому спикеру — имя с самым сильным доказательством.
        var best: [String: (attribution: Attribution, order: Int)] = [:]
        for (order, name) in candidates.enumerated() {
            guard let attribution = attribute(name: name, lines: prepared.lines),
                  let speaker = byTag[attribution.tag.uppercased()],
                  !speaker.hasCustomName, name != speaker.label else { continue }
            if let current = best[speaker.id], current.attribution.score >= attribution.score { continue }
            best[speaker.id] = (attribution, order)
        }
        return best.sorted { $0.value.order < $1.value.order }.map { id, entry in
            NameSuggestion(speakerID: id, name: entry.attribution.name,
                           quote: cleanQuote(entry.attribution.quote), time: entry.attribution.time)
        }
    }

    // MARK: - Дубликаты

    /// Пары спикеров, на которых разметка разрезала одного человека: реплика
    /// одной метки кончается без точки, следующая метка начинается со
    /// строчной буквы. Спикеры с разными именами (заданными пользователем или
    /// найденными правилами) — разные люди, их не склеиваем. Цель — у кого
    /// больше реплик, поровну — кто появился раньше; каждый спикер — не
    /// больше чем в одной паре.
    static func continuationMerges(prepared: Prepared, names: [NameSuggestion]) -> [MergeSuggestion] {
        let byTag = Dictionary(prepared.speakers.map { ($0.tag, $0) }, uniquingKeysWith: { a, _ in a })
        let order = Dictionary(uniqueKeysWithValues: prepared.speakers.enumerated().map { ($1.id, $0) })
        var known: [String: String] = [:]
        for speaker in prepared.speakers where speaker.hasCustomName { known[speaker.id] = speaker.label }
        for suggestion in names { known[suggestion.speakerID] = suggestion.name }

        struct Cut { var count: Int; let quote: String; let time: Double; let first: Int }
        var cuts: [Set<String>: Cut] = [:]
        let lines = prepared.lines
        for index in lines.indices.dropLast() {
            let a = lines[index], b = lines[index + 1]
            guard let ta = a.speaker, let tb = b.speaker, ta != tb,
                  let sa = byTag[ta], let sb = byTag[tb],
                  endsOpen(a.text), startsLowercase(b.text) else { continue }
            let key: Set<String> = [sa.id, sb.id]
            if cuts[key] == nil {
                let quote = "…" + a.text.split(separator: " ").suffix(4).joined(separator: " ")
                    + " / " + b.text.split(separator: " ").prefix(4).joined(separator: " ") + "…"
                cuts[key] = Cut(count: 0, quote: quote, time: b.start, first: index)
            }
            cuts[key]?.count += 1
        }

        var merges: [MergeSuggestion] = []
        var used = Set<String>()
        for (pair, cut) in cuts.sorted(by: { ($0.value.count, -$0.value.first) > ($1.value.count, -$1.value.first) }) {
            let members = pair.compactMap { id in prepared.speakers.first { $0.id == id } }
            guard members.count == 2, !members.contains(where: { used.contains($0.id) }) else { continue }
            if let first = known[members[0].id], let second = known[members[1].id],
               first.lowercased() != second.lowercased() { continue }
            let sorted = members.sorted {
                ($0.segmentCount, -(order[$0.id] ?? 0)) > ($1.segmentCount, -(order[$1.id] ?? 0))
            }
            merges.append(MergeSuggestion(sourceID: sorted[1].id, targetID: sorted[0].id,
                                          quote: cut.quote, time: cut.time))
            used.formUnion(pair)
        }
        return merges
    }

    /// Реплика оборвана: в конце нет точки, вопроса, восклицания или многоточия.
    private static func endsOpen(_ text: String) -> Bool {
        guard let last = text.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "»\"”)")).last else { return false }
        return !".!?…".contains(last)
    }

    /// Начинается со строчной буквы (ведущие тире и кавычки не в счёт).
    private static func startsLowercase(_ text: String) -> Bool {
        guard let first = text.first(where: { $0.isLetter }) else { return false }
        return first.isLowercase
    }

    /// Предел длины имени — тот же, что у переименования вручную.
    static var maxNameLength: Int { TranscriptEdits.maxNameLength }

    /// Заглушки вместо имени: модель иногда пишет их, когда имени нет.
    private static let placeholderNames: Set<String> = [
        "неизвестно", "неизвестный", "нет", "не указано", "спикер", "говорящий", "участник",
        "unknown", "none", "null", "n/a", "speaker", "участница", "собеседник", "ведущий"
    ]

    private static func cleanName(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let name = TranscriptEdits.normalizeName(TranscriptLLMInput.sanitize(raw))
            .trimmingCharacters(in: CharacterSet(charactersIn: "«»\"'“”.,:;!?"))
        guard !name.isEmpty, name.count <= maxNameLength else { return nil }
        guard name.split(separator: " ").count <= 4 else { return nil }
        guard name.contains(where: \.isLetter), !name.contains(where: \.isNumber) else { return nil }
        let lowered = name.lowercased()
        guard !placeholderNames.contains(lowered),
              !lowered.hasPrefix("спикер "), !lowered.hasPrefix("speaker ") else { return nil }
        return name
    }

    private static func cleanQuote(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let quote = TranscriptEdits.normalizeText(TranscriptLLMInput.sanitize(raw))
            .trimmingCharacters(in: CharacterSet(charactersIn: "«»\"“”"))
        guard !quote.isEmpty else { return nil }
        return quote.count > 160 ? String(quote.prefix(160)) + "…" : quote
    }

    // MARK: - Кому принадлежит имя

    /// Итог правил: метка спикера, сила доказательства и где оно прозвучало.
    struct Attribution: Equatable {
        let tag: String
        let name: String
        let score: Int
        let quote: String
        let time: Double
    }

    /// Слова перед именем, после которых это представление: «меня зовут
    /// Аня», «my name is…». Засчитывается только точная форма имени: «зовут
    /// Анну» — не про себя.
    private static let introMarkers: Set<String> = ["зовут", "звать", "name", "is"]
    /// Короткие маркеры («я Игорь», «это Паша», «I'm Paul») — только если
    /// имя закрывает фразу или отбито запятой: «это Марина сделала» — не
    /// представление.
    private static let shortIntroMarkers: Set<String> = ["я", "это", "i'm", "im", "am"]
    /// Представление весит больше обращения: человек сам назвал себя.
    static let introductionScore = 3
    static let addressScore = 1

    /// Кому принадлежит имя — по всем строкам, где оно звучит. Голоса:
    /// представление — говорящему этой строки; обращение в последней фразе
    /// реплики («…Игорь, расскажешь?») — тому, кто говорит следом; обращение
    /// в первой фразе («Да, Анна. Сборка готова…») — тому, кому отвечают
    /// (говорившему перед этим). Упоминание без обращения голоса не даёт.
    /// Ничья — не угадываем.
    static func attribute(name: String, lines: [TranscriptLLMInput.Line]) -> Attribution? {
        guard let nameWord = words(name).first?.text else { return nil }
        var votes: [String: Int] = [:]
        var evidence: [String: (score: Int, quote: String, time: Double)] = [:]

        func vote(_ tag: String?, _ score: Int, _ sentence: String, _ time: Double) {
            guard let tag else { return }
            votes[tag, default: 0] += score
            if (evidence[tag]?.score ?? 0) < score { evidence[tag] = (score, sentence, time) }
        }

        for (index, line) in lines.enumerated() {
            guard let speaker = line.speaker else { continue }
            let previous = lines[..<index].last { $0.speaker != nil && $0.speaker != speaker }?.speaker
            let next = lines[(index + 1)...].first { $0.speaker != nil }?.speaker.flatMap { $0 == speaker ? nil : $0 }
            let sentences = splitSentences(line.text)
            for (sentenceIndex, sentence) in sentences.enumerated() {
                let tokens = words(sentence)
                for (tokenIndex, token) in tokens.enumerated() where sameName(token.text, nameWord) {
                    let before = tokens[max(0, tokenIndex - 2)..<tokenIndex].map { $0.text.lowercased() }
                    let exact = token.text.lowercased() == nameWord.lowercased()
                    let standsAlone = tokenIndex == tokens.count - 1 || token.punctuation.hasPrefix(",")
                    if exact, before.contains(where: introMarkers.contains)
                        || (standsAlone && before.last.map(shortIntroMarkers.contains) == true) {
                        vote(speaker, introductionScore, sentence, line.start)
                        continue
                    }
                    // Обращение отбито запятой: «Игорь, …» в начале фразы или
                    // «…, Игорь.» в конце.
                    let opens = tokenIndex == 0 && token.punctuation.hasPrefix(",")
                    let closes = tokenIndex == tokens.count - 1 && tokenIndex > 0
                        && tokens[tokenIndex - 1].punctuation.hasPrefix(",")
                    guard opens || closes else { continue }
                    let isLast = sentenceIndex == sentences.count - 1
                    let isFirst = sentenceIndex == 0
                    let asks = sentence.hasSuffix("?")
                    if isLast && (!isFirst || asks) {
                        vote(next, addressScore, sentence, line.start)
                    } else if isFirst {
                        vote(previous, addressScore, sentence, line.start)
                    }
                }
            }
        }
        let ranked = votes.sorted { $0.value > $1.value }
        guard let top = ranked.first, top.value > 0,
              ranked.count == 1 || ranked[1].value < top.value,
              let proof = evidence[top.key] else { return nil }
        return Attribution(tag: top.key, name: name, score: top.value, quote: proof.quote, time: proof.time)
    }

    /// Слово и знаки препинания сразу за ним.
    private struct Word {
        let text: String
        let punctuation: String
    }

    private static func words(_ text: String) -> [Word] {
        var result: [Word] = []
        var current = ""
        var punctuation = ""
        var ended = false
        for character in text {
            if character.isLetter || character.isNumber || character == "'" || character == "’" {
                if ended {
                    result.append(Word(text: current, punctuation: punctuation))
                    current = ""
                    punctuation = ""
                    ended = false
                }
                current.append(character)
            } else if !current.isEmpty {
                ended = true
                if !character.isWhitespace { punctuation.append(character) }
            }
        }
        if !current.isEmpty { result.append(Word(text: current, punctuation: punctuation)) }
        return result
    }

    /// Фразы реплики: по «.», «!», «?», «…» с пробелом после.
    private static func splitSentences(_ text: String) -> [String] {
        var sentences: [String] = []
        var current = ""
        var previous: Character?
        for character in text {
            if character.isWhitespace, let previous, ".!?…".contains(previous) {
                let trimmed = current.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { sentences.append(trimmed) }
                current = ""
            } else {
                current.append(character)
            }
            previous = character
        }
        let tail = current.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { sentences.append(tail) }
        return sentences
    }

    /// То же имя с поправкой на падеж: «Игорь» — «Игорю», «Анна» — «Анну».
    /// Разные имена с общим началом («Аня» — «Анна») не совпадают.
    static func sameName(_ word: String, _ name: String) -> Bool {
        let a = Array(word.lowercased().replacingOccurrences(of: "ё", with: "е"))
        let b = Array(name.lowercased().replacingOccurrences(of: "ё", with: "е"))
        guard !a.isEmpty, !b.isEmpty else { return false }
        if a == b { return true }
        guard b.count >= 4, abs(a.count - b.count) <= 2 else { return false }
        var common = 0
        while common < min(a.count, b.count), a[common] == b[common] { common += 1 }
        return common >= max(3, b.count - 2) && common >= min(a.count, b.count) - 2
    }

    /// Первый сбалансированный объект `{…}` в тексте: модель может обернуть
    /// JSON в ```json или дописать фразу до или после.
    static func firstJSONObject(in text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < text.endIndex {
            let character = text[index]
            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
            } else if character == "\"" {
                inString = true
            } else if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 { return String(text[start...index]) }
            }
            index = text.index(after: index)
        }
        return nil
    }
}
