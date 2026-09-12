import Foundation

/// Локальное разбиение длинных сегментов транскрипции на подсегменты по
/// границам предложений. Диаризация Nexara отдаёт один сегмент на всю
/// непрерывную речь спикера (бывает 2+ минуты) — такие тайм-коды бесполезны
/// для навигации. Пословные тайм-коды (`timestamp_granularities[]=word`)
/// позволяют резать сегменты локально, без дополнительных запросов к API.
/// Чистые детерминированные функции (как `PerformanceMetrics`).
enum TranscriptSegmentSplitter {
    /// Пороги нарезки. Пресеты — уровни `TimestampDetail`; внутри каждого
    /// пропорции 1 : 1.25 : 1.5 сохранены от исходных констант.
    struct Config: Equatable {
        /// Целевая длительность подсегмента: предложения группируются,
        /// пока блок не превысит её.
        let targetChunkDuration: Double
        /// Сегменты короче порога проходят насквозь с серверным текстом:
        /// их не пересобираем из слов.
        let splitThreshold: Double
        /// Речь без пунктуации дольше этого рвётся принудительно —
        /// на самой длинной межсловной паузе куска.
        let hardBreakDuration: Double

        static let coarse = Config(targetChunkDuration: 60, splitThreshold: 75, hardBreakDuration: 90)
        static let medium = Config(targetChunkDuration: 30, splitThreshold: 37.5, hardBreakDuration: 45)
        static let fine = Config(targetChunkDuration: 10, splitThreshold: 12.5, hardBreakDuration: 15)
    }

    /// Пауза, подтверждающая конец предложения, когда следующее слово
    /// не начинается с заглавной буквы. От детализации не зависит.
    static let sentencePauseThreshold: Double = 0.5

    /// Отображаемый сегмент и его происхождение: кусок входа (`piece`) и
    /// диапазон слов этого куска. По такому адресу слой правок находит
    /// исходные слова на любой детализации (см. `TranscriptEdits`).
    struct SplitPart: Equatable {
        let segment: TranscriptSegment
        let piece: Int
        let words: Range<Int>
    }

    /// Точка входа: длинные сегменты заменяются цепочкой подсегментов,
    /// короткие и «бессловные» проходят без изменений. Пустые `words` —
    /// деградация в исходные сегменты (сервер не отдал пословные тайм-коды).
    static func split(segments: [TranscriptSegment],
                      words: [TranscriptWord],
                      config: Config = .medium) -> [TranscriptSegment] {
        guard !words.isEmpty, !segments.isEmpty else { return segments }
        let buckets = assignWords(words, to: segments)
        return splitWithSources(segments: segments, buckets: buckets, config: config).map(\.segment)
    }

    /// Нарезка с происхождением. Слова приходят уже разложенными по кускам:
    /// повторная раздача по середине слова ошибалась бы на кусках, которые
    /// слой правок режет по спикерам (у ASR слова перекрываются по времени).
    /// `config == nil` — «как сервер»: каждый кусок как есть.
    static func splitWithSources(segments: [TranscriptSegment],
                                 buckets: [[TranscriptWord]],
                                 config: Config?) -> [SplitPart] {
        var result: [SplitPart] = []
        result.reserveCapacity(segments.count)
        for (piece, segment) in segments.enumerated() {
            let bucket = piece < buckets.count ? buckets[piece] : []
            // Именно `!(<=)`, а не `>`: с NaN в границах — как прежняя реализация.
            guard let config, !(segment.end - segment.start <= config.splitThreshold), !bucket.isEmpty else {
                result.append(SplitPart(segment: segment, piece: piece, words: 0..<bucket.count))
                continue
            }
            for range in chunkRanges(of: bucket, config: config) {
                let chunk = TranscriptSegment(speaker: segment.speaker,
                                              start: bucket[range.lowerBound].start,
                                              end: bucket[range.upperBound - 1].end,
                                              text: joinWords(Array(bucket[range])))
                result.append(SplitPart(segment: chunk, piece: piece, words: range))
            }
        }
        return result
    }

    /// Раздаёт слова сегментам по средней точке слова (линейный merge двух
    /// отсортированных списков): одно назначение на слово, устойчиво к
    /// выходу слова за границу сегмента на доли секунды. Слова до первого
    /// сегмента достаются первому, после последнего — последнему.
    static func assignWords(_ words: [TranscriptWord],
                            to segments: [TranscriptSegment]) -> [[TranscriptWord]] {
        assignWordRanges(words, to: segments).map { Array(words[$0]) }
    }

    /// То же в индексах: указатель сегмента только растёт, поэтому корзина
    /// каждого сегмента — непрерывный диапазон индексов `words`.
    static func assignWordRanges(_ words: [TranscriptWord],
                                 to segments: [TranscriptSegment]) -> [Range<Int>] {
        guard !segments.isEmpty else { return [] }
        var ranges: [Range<Int>] = []
        ranges.reserveCapacity(segments.count)
        var start = 0
        for (offset, word) in words.enumerated() {
            let mid = (word.start + word.end) / 2
            // Текущий сегмент — `ranges.count`; последний забирает хвост.
            while ranges.count < segments.count - 1, mid >= segments[ranges.count].end {
                ranges.append(start..<offset)
                start = offset
            }
        }
        while ranges.count < segments.count {
            ranges.append(start..<words.count)
            start = words.count
        }
        return ranges
    }

    /// Конец ли предложения после слова: слово (без замыкающих кавычек и
    /// скобок) оканчивается на `.!?…`, И следующее начинается с заглавной
    /// или цифры ЛИБО отделено паузой. Числа «2.5» отсекаются сами (точка не
    /// в конце), «т.д.» — строчной буквой следующего слова; редкая ложная
    /// граница на инициалах — приемлемая цена простоты.
    static func isSentenceBoundary(after word: TranscriptWord,
                                   next: TranscriptWord?) -> Bool {
        guard let last = lastMeaningfulCharacter(of: word.text),
              sentenceTerminators.contains(last) else { return false }
        guard let next else { return true }
        if let first = next.text.first, first.isUppercase || first.isNumber {
            return true
        }
        return next.start - word.end > sentencePauseThreshold
    }

    // MARK: - Внутренности

    private static let sentenceTerminators: Set<Character> = [".", "!", "?", "…"]
    private static let trailingClosers: Set<Character> = ["»", "\"", "'", ")", "]", "”", "’"]

    private static func lastMeaningfulCharacter(of text: String) -> Character? {
        var characters = Array(text)
        while let last = characters.last, trailingClosers.contains(last) {
            characters.removeLast()
        }
        return characters.last
    }

    /// Режет слова куска на предложения и группирует их в блоки до
    /// `config.targetChunkDuration`; результат — непрерывные диапазоны
    /// индексов, покрывающие все слова. Тайм-код блока — start его первого слова.
    private static func chunkRanges(of words: [TranscriptWord], config: Config) -> [Range<Int>] {
        var sentences: [Range<Int>] = []
        var start = 0
        for offset in words.indices {
            let word = words[offset]
            let next = offset + 1 < words.count ? words[offset + 1] : nil
            if isSentenceBoundary(after: word, next: next) {
                sentences.append(start..<offset + 1)
                start = offset + 1
            } else if word.end - words[start].start > config.hardBreakDuration {
                let head = headCountAtWidestPause(words[start...offset])
                sentences.append(start..<start + head)
                start += head
            }
        }
        if start < words.count { sentences.append(start..<words.count) }

        var chunks: [Range<Int>] = []
        var chunk: Range<Int>?
        for sentence in sentences {
            guard let current = chunk else {
                chunk = sentence
                continue
            }
            if words[sentence.upperBound - 1].end - words[current.lowerBound].start <= config.targetChunkDuration {
                chunk = current.lowerBound..<sentence.upperBound
            } else {
                chunks.append(current)
                chunk = sentence
            }
        }
        if let chunk { chunks.append(chunk) }
        return chunks
    }

    /// Принудительный разрыв куска без пунктуации: голова до самой длинной
    /// межсловной паузы (число слов головы). Если пауз нет (слова впритык) —
    /// рвётся как есть, по текущей длине.
    private static func headCountAtWidestPause(_ words: ArraySlice<TranscriptWord>) -> Int {
        guard words.count > 1 else { return words.count }
        var bestIndex = words.endIndex
        var bestPause = -Double.infinity
        for index in (words.startIndex + 1)..<words.endIndex {
            let pause = words[index].start - words[index - 1].end
            if pause > bestPause {
                bestPause = pause
                bestIndex = index
            }
        }
        return bestIndex - words.startIndex
    }

    /// Склейка текста из слов: одиночная пунктуация (мусорные токены)
    /// приклеивается к предыдущему слову без пробела. Не private —
    /// тем же способом собирает текст `SpeakerAssignment`, когда режет
    /// сегмент на репликах разных спикеров.
    static func joinWords(_ words: [TranscriptWord]) -> String {
        var parts: [String] = []
        for word in words {
            let isPunctuationOnly = word.text.allSatisfy { $0.isPunctuation || $0.isSymbol }
            if isPunctuationOnly, !parts.isEmpty {
                parts[parts.count - 1] += word.text
            } else {
                parts.append(word.text)
            }
        }
        return parts.joined(separator: " ")
    }
}

/// Уровень детализации тайм-кодов результата: управляет ТОЛЬКО локальной
/// нарезкой сегментов (пословные метки запрашиваются у сервера всегда),
/// поэтому его можно менять на готовом результате без повторного запроса.
/// UI-агностичен, титулы через L() — по образцу `DiarizationSetting`.
enum TimestampDetail: String, CaseIterable, Identifiable {
    case server, coarse, medium, fine

    var id: String { rawValue }
    var title: String { L("transcribe.detail.\(rawValue)") }

    /// Конфиг сплиттера. nil — «как отдаёт сервер»: нарезка не выполняется
    /// (при диаризации сегменты могут длиться минутами).
    var config: TranscriptSegmentSplitter.Config? {
        switch self {
        case .server: return nil
        case .coarse: return .coarse
        case .medium: return .medium
        case .fine: return .fine
        }
    }
}
