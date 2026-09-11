import Foundation

/// Пользовательские правки готовой транскрибации — слой поверх неизменного
/// машинного результата (`StoredTranscript`: `rawSegments` + `words`).
/// Хранятся в `TranscriptBody.edits` и применяются в одной точке —
/// `TranscriptResult.withEdits(_:detail:)` (через неё же идёт `withDetail`).
/// Через неё проходят показ, копирование, экспорт, текст для поиска и вход
/// анализа, поэтому обходить её нельзя.
/// Чистые детерминированные функции (как `TranscriptSegmentSplitter`).
struct TranscriptEdits: Codable, Equatable {
    /// Канонический id спикера → имя, заданное пользователем.
    var speakerNames: [String: String] = [:]
    /// id → id, в который он влит. Цепочки транзитивны; циклов нет по
    /// построению — `merge` пишет только канонические id.
    var speakerMerges: [String: String] = [:]
    /// Счётчик правок: растёт на каждое изменение, включая сброс, — по нему
    /// анализ поймёт, что расшифровку меняли после него.
    var revision = 0

    init() {}

    private enum CodingKeys: String, CodingKey {
        case speakerNames, speakerMerges, revision
    }

    /// Каждое поле декодируется независимо: битое поле правок не должно стоить
    /// остальных правок (и тем более расшифровки — см. `TranscriptBody`).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        speakerNames = (try? c.decodeIfPresent([String: String].self, forKey: .speakerNames)) ?? [:]
        speakerMerges = (try? c.decodeIfPresent([String: String].self, forKey: .speakerMerges)) ?? [:]
        revision = (try? c.decodeIfPresent(Int.self, forKey: .revision)) ?? 0
    }

    /// Правок нет (счётчик не в счёт: после сброса он остаётся).
    var isEmpty: Bool {
        speakerNames.isEmpty && speakerMerges.isEmpty
    }

    /// Совпадают ли правки по содержанию, без учёта счётчика.
    func hasSameContent(as other: TranscriptEdits) -> Bool {
        var copy = self
        copy.revision = other.revision
        return copy == other
    }
}

// MARK: - Спикеры: имена и слияние

extension TranscriptEdits {
    /// Предел длины имени — тот же, что у ролей Nexara.
    static let maxNameLength = SpeakerRolesParser.maxNameLength

    /// Имя, как его сохранят: без краевых пробелов, любые пробельные символы
    /// (включая переводы строк) схлопнуты в один пробел. Длину не режет —
    /// поповер показывает ошибку, а `rename` обрезает на всякий случай.
    static func normalizeName(_ name: String) -> String {
        name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
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

    /// Результат с другими правками под заданную детализацию: всегда от
    /// исходников (`rawSegments` + `words`), поэтому идемпотентен.
    func withEdits(_ edits: TranscriptEdits, detail: TimestampDetail) -> TranscriptResult {
        let split = detail.config.map {
            TranscriptSegmentSplitter.split(segments: rawSegments, words: words, config: $0)
        } ?? rawSegments
        let displayed = edits.speakerMerges.isEmpty ? split : split.map { segment in
            TranscriptSegment(speaker: segment.speaker.map(edits.canonical),
                              start: segment.start, end: segment.end, text: segment.text)
        }
        return TranscriptResult(fullText: fullText, language: language, duration: duration,
                                segments: displayed, rawSegments: rawSegments, words: words,
                                llmOutput: llmOutput, edits: edits)
    }

    /// Индексы цветов спикеров. Ключ — id, а не имя: цвет не меняется от
    /// переименования. Порядок — исходные id по первому появлению (включая
    /// влитые), поэтому слияние не перекрашивает цель, а влитый получает её цвет.
    var speakerColorIndices: [String: Int] {
        var ordered: [String] = []
        var seen = Set<String>()
        for id in rawSegments.compactMap(\.speaker) where !id.isEmpty && seen.insert(id).inserted {
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
