import Foundation

/// Пользовательские правки готовой транскрибации — слой поверх неизменного
/// машинного результата (`StoredTranscript`: `rawSegments` + `words`).
/// Хранятся в `TranscriptBody.edits` и применяются в одной точке —
/// `TranscriptResult.withEdits(_:detail:)` (через неё же идёт `withDetail`).
/// Через неё проходят показ, копирование, экспорт, текст для поиска и вход
/// анализа, поэтому обходить её нельзя.
///
/// Якорь правки — диапазон индексов ИСХОДНЫХ слов (`EditAnchor.words`), а для
/// сегментов без слов — индекс исходного сегмента (`.segment`). Слова — самая
/// мелкая единица, устойчивая во времени, поэтому адрес не зависит от нарезки:
/// правка переживает любую смену детализации, а «вернуть» = удалить правку.
/// Чистые детерминированные функции (как `TranscriptSegmentSplitter`).
struct TranscriptEdits: Codable, Equatable {
    /// Канонический id спикера → имя, заданное пользователем.
    var speakerNames: [String: String] = [:]
    /// id → id, в который он влит. Цепочки транзитивны; циклов нет по
    /// построению — `merge` пишет только канонические id.
    var speakerMerges: [String: String] = [:]
    /// Правки текста: НЕпересекающиеся, по возрастанию якоря.
    var textEdits: [TextEdit] = []
    /// Переназначенные реплики: НЕпересекающиеся, по возрастанию якоря.
    /// Спикер — сырой id цели: после «Отделить» переназначение на влитого
    /// снова показывает его самого.
    var speakerOverrides: [SpeakerOverride] = []
    /// Счётчик правок: растёт на каждое изменение, включая сброс, — по нему
    /// анализ поймёт, что расшифровку меняли после него.
    var revision = 0

    init() {}

    private enum CodingKeys: String, CodingKey {
        case speakerNames, speakerMerges, textEdits, speakerOverrides, revision
    }

    /// Каждое поле декодируется независимо, массивы — поэлементно: битая
    /// правка не должна стоить остальных (и тем более расшифровки — см.
    /// `TranscriptBody`). Пересекающиеся якоря и пустые тексты отбрасываются:
    /// по построению их не бывает, а с ними и материализация, и валидация
    /// адресов слепнут.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        speakerNames = (try? c.decodeIfPresent([String: String].self, forKey: .speakerNames)) ?? [:]
        speakerMerges = (try? c.decodeIfPresent([String: String].self, forKey: .speakerMerges)) ?? [:]
        let texts = (try? c.decodeIfPresent([Lossy<TextEdit>].self, forKey: .textEdits))?
            .compactMap(\.value) ?? []
        textEdits = Self.nonOverlapping(texts.filter { !Self.tokens($0.text).isEmpty }, anchor: \.anchor)
        let overrides = (try? c.decodeIfPresent([Lossy<SpeakerOverride>].self, forKey: .speakerOverrides))?
            .compactMap(\.value) ?? []
        speakerOverrides = Self.nonOverlapping(overrides, anchor: \.anchor)
        revision = (try? c.decodeIfPresent(Int.self, forKey: .revision)) ?? 0
    }

    /// Правок нет (счётчик не в счёт: после сброса он остаётся).
    var isEmpty: Bool {
        speakerNames.isEmpty && speakerMerges.isEmpty && !hasContentEdits
    }

    /// Правки содержимого реплик (не имён) — их не перенести на другую
    /// расшифровку того же файла.
    var hasContentEdits: Bool {
        !textEdits.isEmpty || !speakerOverrides.isEmpty
    }

    /// Совпадают ли правки по содержанию, без учёта счётчика.
    func hasSameContent(as other: TranscriptEdits) -> Bool {
        var copy = self
        copy.revision = other.revision
        return copy == other
    }

    /// Элементы с непересекающимися якорями по возрастанию; при пересечении
    /// остаётся первый.
    static func nonOverlapping<T>(_ items: [T], anchor: (T) -> EditAnchor) -> [T] {
        let sorted = items.sorted { anchor($0).sortKey < anchor($1).sortKey }
        var result: [T] = []
        var lastUpper = Int.min
        var segments = Set<Int>()
        for item in sorted {
            switch anchor(item) {
            case .words(let range):
                guard range.lowerBound >= lastUpper else { continue }
                lastUpper = range.upperBound
            case .segment(let index):
                guard segments.insert(index).inserted else { continue }
            }
            result.append(item)
        }
        return result
    }
}

/// Адрес правки в координатах исходного результата.
enum EditAnchor: Hashable, Codable {
    /// `[lower, upper)` в ИСХОДНОМ массиве `words`.
    case words(Range<Int>)
    /// Исходный сегмент без слов (Nexara с анализом ИИ, сегмент в тишине).
    case segment(Int)

    private enum CodingKeys: String, CodingKey { case w, s }

    /// Компактно: `{"w":[lo,hi]}` или `{"s":i}`.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let bounds = try c.decodeIfPresent([Int].self, forKey: .w) {
            guard bounds.count == 2, bounds[0] >= 0, bounds[0] < bounds[1] else {
                throw DecodingError.dataCorruptedError(forKey: .w, in: c,
                                                       debugDescription: "некорректный диапазон слов")
            }
            self = .words(bounds[0]..<bounds[1])
        } else {
            let index = try c.decode(Int.self, forKey: .s)
            guard index >= 0 else {
                throw DecodingError.dataCorruptedError(forKey: .s, in: c,
                                                       debugDescription: "отрицательный индекс сегмента")
            }
            self = .segment(index)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .words(let range): try c.encode([range.lowerBound, range.upperBound], forKey: .w)
        case .segment(let index): try c.encode(index, forKey: .s)
        }
    }

    func intersects(_ other: EditAnchor) -> Bool {
        switch (self, other) {
        case (.words(let a), .words(let b)): return a.overlaps(b)
        case (.segment(let a), .segment(let b)): return a == b
        default: return false
        }
    }

    /// Порядок хранения: сначала диапазоны слов по началу, потом сегменты.
    var sortKey: (Int, Int) {
        switch self {
        case .words(let range): return (0, range.lowerBound)
        case .segment(let index): return (1, index)
        }
    }
}

/// Новый текст для диапазона исходных слов (или бессловного сегмента).
struct TextEdit: Codable, Equatable {
    let anchor: EditAnchor
    /// Нормализованный текст: без краевых пробелов, пробельные схлопнуты.
    let text: String
}

/// Переназначение реплики (или её части) другому спикеру.
struct SpeakerOverride: Codable, Equatable {
    let anchor: EditAnchor
    let speaker: String
}

/// Адрес отображаемого сегмента в координатах исходного результата — одинаков
/// на любой детализации. Вью передаёт в правку его, а не индекс строки: адрес
/// переживает перенарезку между открытием редактора и сохранением.
struct EditTarget: Equatable {
    /// Исходный сегмент, из которого взят отображаемый.
    let rawIndex: Int
    /// Слова сегмента, расширенные до ЦЕЛЫХ задетых правок текста: у токенов
    /// правки нет соответствия исходным словам, поэтому правка неделима.
    let anchor: EditAnchor
    /// Сырой id спикера исходного сегмента.
    let originalSpeaker: String?
    let isSpeakerOverridden: Bool
    /// Задетые правки текста — для валидации адреса и склейки.
    var absorbed: [TextEdit] = []
    /// Токены задетой правки ДО начала сегмента…
    var prefix = ""
    /// …и ПОСЛЕ его конца: новая правка вбирает их, чтобы не потерять.
    var suffix = ""
    /// Исходный текст якоря: тултип «Исходный текст» и распознавание возврата.
    var originalText = ""

    var isTextEdited: Bool { !absorbed.isEmpty }
}

/// Слово материализованного результата: исходное (индекс в `words`) или
/// токен правки текста (индекс правки в `textEdits`, номер токена).
enum WordOrigin: Equatable {
    case original(Int)
    case edit(Int, token: Int)
}

/// «Эффективные исходные» куски — вход сплиттера: исходные сегменты с
/// применёнными правками текста, разрезанные по сменам спикера.
struct MaterializedTranscript {
    let segments: [TranscriptSegment]
    /// Слова каждого куска, включая синтетические токены правок.
    let buckets: [[TranscriptWord]]
    /// Происхождение слов куска — параллельно `buckets`.
    let origins: [[WordOrigin]]
    /// Кусок → исходный сегмент.
    let rawIndex: [Int]
    /// Слова каждого исходного сегмента (`assignWordRanges`).
    let rawWordRanges: [Range<Int>]
    /// Токены применённых правок текста по индексу правки.
    let editTokens: [Int: [String]]
    /// Полный текст с правками; nil — текст не правили (берётся `fullText`
    /// сервера). От детализации не зависит.
    let editedFullText: String?
}

// MARK: - Спикеры: имена и слияние

extension TranscriptEdits {
    /// Предел длины имени — тот же, что у ролей Nexara.
    static let maxNameLength = SpeakerRolesParser.maxNameLength

    /// Имя, как его сохранят: без краевых пробелов, любые пробельные символы
    /// (включая переводы строк) схлопнуты в один пробел. Длину не режет —
    /// поповер показывает ошибку, а `rename` обрезает на всякий случай.
    static func normalizeName(_ name: String) -> String {
        normalizeText(name)
    }

    /// Канонический id: проход по цепочке слияний. Лимит шагов — защита от
    /// цикла в битых данных (сами операции циклов не создают).
    func canonical(_ id: String) -> String {
        var current = id
        var steps = 0
        while let next = speakerMerges[current], next != current, steps <= speakerMerges.count {
            current = next
            steps += 1
        }
        return current
    }

    /// Имя, заданное пользователем для спикера (с учётом слияния); nil — нет.
    func customName(for id: String) -> String? {
        speakerNames[canonical(id)]
    }

    /// Отображаемое имя спикера: своё или «Спикер N» канонического id.
    func label(for id: String) -> String {
        let key = canonical(id)
        return speakerNames[key] ?? SpeakerName.displayName(for: key)
    }

    /// Собственное имя id без учёта слияния — для пункта «Отделить».
    func ownLabel(for id: String) -> String {
        speakerNames[id] ?? SpeakerName.displayName(for: id)
    }

    /// Переименование. Пустое имя (или имя по умолчанию) возвращает
    /// «Спикер N»; слишком длинное обрезается до предела.
    mutating func rename(_ id: String, to name: String) {
        let key = canonical(id)
        let normalized = String(Self.normalizeName(name).prefix(Self.maxNameLength))
        if normalized.isEmpty || normalized == SpeakerName.displayName(for: key) {
            speakerNames[key] = nil
        } else {
            speakerNames[key] = normalized
        }
    }

    /// Слияние: `id` (со всеми, кто уже влит в него) становится `target`.
    /// Если у цели своего имени нет, она наследует имя влитого.
    mutating func merge(_ id: String, into target: String) {
        let source = canonical(id)
        let destination = canonical(target)
        guard source != destination else { return }
        speakerMerges[source] = destination
        if speakerNames[destination] == nil, let name = speakerNames[source] {
            speakerNames[destination] = name
        }
    }

    /// Отделить: удаляется только прямая связь `id`, влитые в него остаются с ним.
    mutating func unmerge(_ id: String) {
        speakerMerges[id] = nil
    }

    /// Все id, которые сейчас разрешаются в `id` (кроме него самого).
    func mergedIDs(into id: String) -> [String] {
        let key = canonical(id)
        return speakerMerges.keys
            .filter { $0 != key && canonical($0) == key }
            .sorted()
    }

    /// Все id, которые хоть где-то встречаются: исходные, переназначения,
    /// обе стороны слияний и имена. Новый спикер не должен получить id
    /// слитого (вышло бы неявное слияние) или чужое оставшееся имя.
    func knownSpeakerIDs(rawSegments: [TranscriptSegment]) -> Set<String> {
        var ids = Set(rawSegments.compactMap(\.speaker))
        ids.formUnion(speakerOverrides.map(\.speaker))
        ids.formUnion(speakerMerges.keys)
        ids.formUnion(speakerMerges.values)
        ids.formUnion(speakerNames.keys)
        return ids
    }
}

// MARK: - Переназначение реплик

extension TranscriptEdits {
    /// Назначить отображаемый сегмент спикеру. Диапазон цели вырезается из
    /// прежних переназначений (они делятся), затем вставляется новое — если
    /// спикер не совпал с исходным: совпадение и есть возврат. Якорь цели уже
    /// расширен до целых правок текста, поэтому правка никогда не пересекает
    /// границу спикеров.
    mutating func setSpeaker(_ speaker: String, at target: EditTarget) {
        cutSpeakerOverrides(target.anchor)
        guard canonical(speaker) != target.originalSpeaker.map(canonical) else { return }
        speakerOverrides.append(SpeakerOverride(anchor: target.anchor, speaker: speaker))
        speakerOverrides.sort { $0.anchor.sortKey < $1.anchor.sortKey }
    }

    /// «Вернуть исходного спикера» — вырезать переназначения из диапазона цели.
    mutating func revertSpeaker(at target: EditTarget) {
        cutSpeakerOverrides(target.anchor)
    }

    private mutating func cutSpeakerOverrides(_ cut: EditAnchor) {
        var result: [SpeakerOverride] = []
        for override in speakerOverrides {
            switch (override.anchor, cut) {
            case (.words(let own), .words(let removed)) where own.overlaps(removed):
                if own.lowerBound < removed.lowerBound {
                    result.append(SpeakerOverride(anchor: .words(own.lowerBound..<removed.lowerBound),
                                                  speaker: override.speaker))
                }
                if removed.upperBound < own.upperBound {
                    result.append(SpeakerOverride(anchor: .words(removed.upperBound..<own.upperBound),
                                                  speaker: override.speaker))
                }
            case (.segment(let own), .segment(let removed)) where own == removed:
                continue
            default:
                result.append(override)
            }
        }
        speakerOverrides = result
    }
}

// MARK: - Правка текста

extension TranscriptEdits {
    /// Текст, как его сохранят: без краевых пробелов, пробельные (включая
    /// переводы строк из Option+Return) схлопнуты в один пробел.
    static func normalizeText(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Токены текста по тому же правилу, что `joinWords`: одиночная
    /// пунктуация приклеивается к предыдущему слову. Поэтому сплиттер видит
    /// правленый текст так же, как исходные слова (границы предложений).
    static func tokens(_ text: String) -> [String] {
        var tokens: [String] = []
        for part in text.split(whereSeparator: \.isWhitespace) {
            let token = String(part)
            if !tokens.isEmpty, token.allSatisfy({ $0.isPunctuation || $0.isSymbol }) {
                tokens[tokens.count - 1] += token
            } else {
                tokens.append(token)
            }
        }
        return tokens
    }

    /// Синтетические тайминги токенов правки. При том же числе токенов —
    /// тайминги исходных слов 1:1 (исправленная опечатка сохраняет точные
    /// тайм-коды), иначе отрезок `[first.start, last.end]` делится
    /// пропорционально длине токена + 1: монотонно и строго внутри отрезка.
    static func synthesizeWords(_ tokens: [String],
                                replacing original: ArraySlice<TranscriptWord>) -> [TranscriptWord] {
        guard let first = original.first, let last = original.last, !tokens.isEmpty else { return [] }
        if tokens.count == original.count {
            return zip(tokens, original).map { TranscriptWord(text: $0, start: $1.start, end: $1.end) }
        }
        let start = first.start
        let span = max(last.end, start) - start
        let weights = tokens.map { Double($0.count + 1) }
        let total = weights.reduce(0, +)
        var words: [TranscriptWord] = []
        var accumulated = 0.0
        for (index, token) in tokens.enumerated() {
            let wordStart = start + span * accumulated / total
            accumulated += weights[index]
            let wordEnd = index == tokens.count - 1 ? start + span : start + span * accumulated / total
            words.append(TranscriptWord(text: token, start: wordStart, end: wordEnd))
        }
        return words
    }

    /// Адрес ещё соответствует правкам: все задетые правки на месте без
    /// изменений и нет других правок текста в его диапазоне. Устаревший адрес
    /// (открытый редактор, пока реплику правили иначе) отвергается — данные
    /// не портятся.
    func isValid(_ target: EditTarget) -> Bool {
        for edit in target.absorbed where !textEdits.contains(edit) { return false }
        for edit in textEdits where edit.anchor.intersects(target.anchor) && !target.absorbed.contains(edit) {
            return false
        }
        return true
    }

    /// Новый текст отображаемого сегмента. Задетые правки заменяются одной на
    /// весь якорь; их токены за границами сегмента сохраняются
    /// (`prefix`/`suffix`). Текст, совпавший с исходным, — это возврат.
    /// Пустой текст запрещён: реплика исчезла бы, и вернуть её было бы нечем.
    mutating func setText(_ text: String, at target: EditTarget) {
        let body = Self.normalizeText(text)
        guard !body.isEmpty else { return }
        let full = Self.normalizeText([target.prefix, body, target.suffix].joined(separator: " "))
        textEdits.removeAll { $0.anchor.intersects(target.anchor) }
        guard full != Self.normalizeText(target.originalText) else { return }
        textEdits.append(TextEdit(anchor: target.anchor, text: full))
        textEdits.sort { $0.anchor.sortKey < $1.anchor.sortKey }
    }

    /// «Вернуть исходный текст» — задетые правки удаляются целиком. Если
    /// правка видна и в соседней строке (правили на «Средней», смотрим на
    /// «Подробной»), вернётся и соседняя часть: у токенов правки нет
    /// соответствия исходным словам.
    mutating func revertText(at target: EditTarget) {
        textEdits.removeAll { $0.anchor.intersects(target.anchor) }
    }
}

// MARK: - Материализация

extension TranscriptEdits {
    /// Исходники с применёнными правками — вход сплиттера. Слова раздаются
    /// исходным сегментам тем же `assignWordRanges`, что и без правок; правки
    /// текста подставляют свои токены вместо слов якоря; каждый сегмент
    /// режется на куски по сменам спикера. Без правок результат побитно равен
    /// исходникам — регресс-гарантия. O(слов).
    func materialize(rawSegments: [TranscriptSegment],
                     words: [TranscriptWord]) -> MaterializedTranscript {
        let ranges = TranscriptSegmentSplitter.assignWordRanges(words, to: rawSegments)

        var wordEdits: [Int: Int] = [:]       // начало якоря → индекс правки
        var segmentEdits: [Int: Int] = [:]
        var editTokens: [Int: [String]] = [:]
        for (index, edit) in textEdits.enumerated() {
            let tokens = Self.tokens(edit.text)
            guard !tokens.isEmpty else { continue }
            switch edit.anchor {
            case .words(let range): wordEdits[range.lowerBound] = index
            case .segment(let segment): segmentEdits[segment] = index
            }
            editTokens[index] = tokens
        }

        var wordOverrides: [(range: Range<Int>, speaker: String)] = []
        var segmentOverrides: [Int: String] = [:]
        for override in speakerOverrides {
            switch override.anchor {
            case .words(let range): wordOverrides.append((range, override.speaker))
            case .segment(let index): segmentOverrides[index] = override.speaker
            }
        }
        // Индексы слов растут монотонно — переназначения обходятся одним указателем.
        var cursor = 0
        func overriddenSpeaker(at index: Int) -> String? {
            while cursor < wordOverrides.count, wordOverrides[cursor].range.upperBound <= index {
                cursor += 1
            }
            guard cursor < wordOverrides.count, wordOverrides[cursor].range.contains(index) else { return nil }
            return wordOverrides[cursor].speaker
        }

        var segments: [TranscriptSegment] = []
        var buckets: [[TranscriptWord]] = []
        var origins: [[WordOrigin]] = []
        var rawIndex: [Int] = []
        var textChanged = false

        for (r, raw) in rawSegments.enumerated() {
            let range = ranges[r]
            guard !range.isEmpty else {
                // Сегмент без слов — целиком, со своими правками.
                let edit = segmentEdits[r].map { textEdits[$0] }
                if edit != nil { textChanged = true }
                segments.append(TranscriptSegment(speaker: (segmentOverrides[r] ?? raw.speaker).map(canonical),
                                                  start: raw.start, end: raw.end,
                                                  text: edit?.text ?? raw.text))
                buckets.append([])
                origins.append([])
                rawIndex.append(r)
                continue
            }

            // Эффективные слова сегмента: исходные и токены правок.
            var effective: [TranscriptWord] = []
            var wordOrigins: [WordOrigin] = []
            var speakers: [String?] = []
            var usedEdits: [Int] = []
            var i = range.lowerBound
            while i < range.upperBound {
                if let k = wordEdits[i], case .words(let editRange) = textEdits[k].anchor,
                   let tokens = editTokens[k] {
                    if editRange.upperBound <= range.upperBound {
                        // Спикер токенов — спикер первого исходного слова правки.
                        let speaker = (overriddenSpeaker(at: i) ?? raw.speaker).map(canonical)
                        effective += Self.synthesizeWords(tokens, replacing: words[editRange])
                        wordOrigins += tokens.indices.map { .edit(k, token: $0) }
                        speakers += Array(repeating: speaker, count: tokens.count)
                        usedEdits.append(k)
                        i = editRange.upperBound
                        continue
                    }
                    NSLog("DOKA: правка текста выходит за исходный сегмент \(r) — пропущена")
                }
                effective.append(words[i])
                wordOrigins.append(.original(i))
                speakers.append((overriddenSpeaker(at: i) ?? raw.speaker).map(canonical))
                i += 1
            }
            if !usedEdits.isEmpty { textChanged = true }

            var runs: [Range<Int>] = []
            var runStart = 0
            for offset in 1...speakers.count where offset == speakers.count || speakers[offset] != speakers[runStart] {
                runs.append(runStart..<offset)
                runStart = offset
            }

            for run in runs {
                let runWords = Array(effective[run])
                let runOrigins = Array(wordOrigins[run])
                let segment: TranscriptSegment
                if runs.count == 1 {
                    // Один кусок: границы сервера. Текст: (a) без правок — серверный
                    // (пунктуация сохраняется); (b) правка на все слова — её текст;
                    // (c) иначе — из эффективных слов.
                    let text: String
                    if usedEdits.isEmpty {
                        text = raw.text
                    } else if usedEdits.count == 1, textEdits[usedEdits[0]].anchor == .words(range) {
                        text = textEdits[usedEdits[0]].text
                    } else {
                        text = TranscriptSegmentSplitter.joinWords(runWords)
                    }
                    segment = TranscriptSegment(speaker: speakers[run.lowerBound],
                                                start: raw.start, end: raw.end, text: text)
                } else {
                    // Смена спикера внутри сегмента: границы из слов; текст —
                    // правки, если кусок ровно её токены, иначе из слов.
                    segment = TranscriptSegment(speaker: speakers[run.lowerBound],
                                                start: runWords[0].start,
                                                end: runWords[runWords.count - 1].end,
                                                text: Self.wholeEditText(runOrigins, textEdits: textEdits,
                                                                         editTokens: editTokens)
                                                    ?? TranscriptSegmentSplitter.joinWords(runWords))
                }
                segments.append(segment)
                buckets.append(runWords)
                origins.append(runOrigins)
                rawIndex.append(r)
            }
        }
        return MaterializedTranscript(segments: segments, buckets: buckets, origins: origins,
                                      rawIndex: rawIndex, rawWordRanges: ranges, editTokens: editTokens,
                                      editedFullText: textChanged
                                          ? segments.map(\.text).joined(separator: " ")
                                          : nil)
    }

    /// Текст правки, если слова куска — ровно все её токены.
    private static func wholeEditText(_ origins: [WordOrigin], textEdits: [TextEdit],
                                      editTokens: [Int: [String]]) -> String? {
        guard case .edit(let k, 0)? = origins.first, let tokens = editTokens[k],
              origins.count == tokens.count,
              case .edit(k, tokens.count - 1)? = origins.last else { return nil }
        return textEdits[k].text
    }

    /// Адреса отображаемых сегментов: исходный сегмент, диапазон исходных
    /// слов, расширенный до целых задетых правок, и сами эти правки.
    func targets(for parts: [TranscriptSegmentSplitter.SplitPart],
                 in materialized: MaterializedTranscript,
                 rawSegments: [TranscriptSegment],
                 words: [TranscriptWord]) -> [EditTarget] {
        parts.map { part in
            let r = materialized.rawIndex[part.piece]
            let raw = rawSegments[r]
            let pieceOrigins = materialized.origins[part.piece]
            guard !pieceOrigins.isEmpty, !part.words.isEmpty else {
                let anchor = EditAnchor.segment(r)
                return EditTarget(rawIndex: r, anchor: anchor, originalSpeaker: raw.speaker,
                                  isSpeakerOverridden: speakerOverrides.contains { $0.anchor == anchor },
                                  absorbed: textEdits.filter { $0.anchor == anchor },
                                  originalText: raw.text)
            }

            let slice = pieceOrigins[part.words]
            var lower = Int.max
            var upper = Int.min
            var absorbed: [Int] = []
            for origin in slice {
                switch origin {
                case .original(let index):
                    lower = min(lower, index)
                    upper = max(upper, index + 1)
                case .edit(let k, _):
                    if absorbed.last != k { absorbed.append(k) }
                    if case .words(let range) = textEdits[k].anchor {
                        lower = min(lower, range.lowerBound)
                        upper = max(upper, range.upperBound)
                    }
                }
            }
            var prefix = ""
            var suffix = ""
            if case .edit(let k, let token)? = slice.first, token > 0, let tokens = materialized.editTokens[k] {
                prefix = tokens[..<token].joined(separator: " ")
            }
            if case .edit(let k, let token)? = slice.last, let tokens = materialized.editTokens[k],
               token < tokens.count - 1 {
                suffix = tokens[(token + 1)...].joined(separator: " ")
            }
            let range = lower..<upper
            let anchor = EditAnchor.words(range)
            // Весь сегмент — серверный текст с пунктуацией; часть — из слов.
            let originalText = range == materialized.rawWordRanges[r]
                ? raw.text
                : TranscriptSegmentSplitter.joinWords(Array(words[range]))
            return EditTarget(rawIndex: r, anchor: anchor, originalSpeaker: raw.speaker,
                              isSpeakerOverridden: speakerOverrides.contains { $0.anchor.intersects(anchor) },
                              absorbed: absorbed.map { textEdits[$0] },
                              prefix: prefix, suffix: suffix, originalText: originalText)
        }
    }
}

// MARK: - Ростер спикеров результата

/// Спикер в полосе «Спикеры» и в меню переназначения.
struct SpeakerInfo: Identifiable, Equatable {
    /// Канонический id (после слияний).
    let id: String
    let label: String
    /// Имя по умолчанию («Спикер 2») — подпись поповера и «Вернуть «…»».
    let defaultLabel: String
    let hasCustomName: Bool
    let segmentCount: Int
    let colorIndex: Int
    /// Влитые в этого спикера — пункты «Отделить».
    let merged: [SpeakerRef]
}

struct SpeakerRef: Identifiable, Equatable {
    let id: String
    let label: String
}

extension TranscriptResult {
    /// Имя спикера для показа и экспорта — с учётом правок.
    func speakerLabel(_ id: String) -> String {
        edits.label(for: id)
    }

    /// Результат с другими правками под заданную детализацию: материализация
    /// правок под сплиттером, всегда от исходников (`rawSegments` + `words`),
    /// поэтому идемпотентен и не зависит от прежней нарезки.
    func withEdits(_ edits: TranscriptEdits, detail: TimestampDetail) -> TranscriptResult {
        let materialized = edits.materialize(rawSegments: rawSegments, words: words)
        let parts = TranscriptSegmentSplitter.splitWithSources(segments: materialized.segments,
                                                               buckets: materialized.buckets,
                                                               config: detail.config)
        return TranscriptResult(fullText: fullText, language: language, duration: duration,
                                segments: parts.map(\.segment), rawSegments: rawSegments, words: words,
                                llmOutput: llmOutput, edits: edits,
                                segmentTargets: edits.targets(for: parts, in: materialized,
                                                              rawSegments: rawSegments, words: words),
                                editedFullText: materialized.editedFullText)
    }

    /// Правка сегментов доступна: у каждого показанного сегмента есть адрес
    /// (результат прошёл через `withEdits`).
    var canEditSegments: Bool {
        !segments.isEmpty && segmentTargets.count == segments.count
    }

    /// Индексы цветов спикеров. Ключ — id, а не имя: цвет не меняется от
    /// переименования. Порядок — исходные id по первому появлению (включая
    /// влитые), затем новые из переназначений: слияние не перекрашивает цель,
    /// влитый получает её цвет, переназначение первой реплики ничего не сдвигает.
    var speakerColorIndices: [String: Int] {
        var ordered: [String] = []
        var seen = Set<String>()
        let ids = rawSegments.compactMap(\.speaker) + edits.speakerOverrides.map(\.speaker)
        for id in ids where !id.isEmpty && seen.insert(id).inserted {
            ordered.append(id)
        }
        return SpeakerName.colorIndices(orderedIDs: ordered)
    }

    /// Спикеры показанных сегментов по первому появлению — с именами,
    /// числом реплик, цветом и влитыми.
    var speakerRoster: [SpeakerInfo] {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for segment in segments {
            guard let id = segment.speaker, !id.isEmpty else { continue }
            if counts[id] == nil { order.append(id) }
            counts[id, default: 0] += 1
        }
        let colors = speakerColorIndices
        return order.map { id in
            SpeakerInfo(id: id,
                        label: edits.label(for: id),
                        defaultLabel: SpeakerName.displayName(for: id),
                        hasCustomName: edits.customName(for: id) != nil,
                        segmentCount: counts[id] ?? 0,
                        colorIndex: colors[id] ?? 0,
                        merged: edits.mergedIDs(into: id).map {
                            SpeakerRef(id: $0, label: edits.ownLabel(for: $0))
                        })
        }
    }
}

/// Элемент массива, который при ошибке декода пропускается, а не роняет весь массив.
private struct Lossy<T: Decodable>: Decodable {
    let value: T?

    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}
