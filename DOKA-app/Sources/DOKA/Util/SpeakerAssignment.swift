import Foundation

/// Сшивка расшифровки с результатом локальной диаризации: у ASR — текст со
/// словами и тайм-кодами, у диаризатора — интервалы «кто когда говорил»,
/// общего между ними только время. Чистые детерминированные функции
/// (как `TranscriptSegmentSplitter` и `TranscriptFormatter`).
///
/// У сетевой диаризации Nexara этого шага нет: там сервер сразу возвращает
/// `speaker` в каждом сегменте.
enum SpeakerAssignment {
    /// Проставляет спикеров сегментам расшифровки.
    ///
    /// Сегмент, целиком попавший в речь одного говорящего, сохраняет исходный
    /// текст сервера/движка — пересобирать его из слов незачем, потеряется
    /// пунктуация. Сегмент, внутри которого говорящий сменился, режется по
    /// словам на границе смены. Без слов (движок не дал пословных меток)
    /// спикер определяется по наибольшему перекрытию интервалов.
    static func apply(spans: [SpeakerSpan],
                      words: [TranscriptWord],
                      segments: [TranscriptSegment]) -> [TranscriptSegment] {
        guard !spans.isEmpty, !segments.isEmpty else { return segments }

        // Спикеры слов — по всей записи сразу: островок на стыке двух
        // сегментов (у Whisper они короткие) изнутри одного не увидеть.
        let labels = speakers(of: words, spans: spans)
        let ranges = TranscriptSegmentSplitter.assignWordRanges(words, to: segments)
        var result: [TranscriptSegment] = []

        for (index, segment) in segments.enumerated() {
            let range = index < ranges.count ? ranges[index] : 0..<0
            guard !range.isEmpty else {
                result.append(TranscriptSegment(speaker: dominantSpeaker(for: segment, spans: spans),
                                                start: segment.start,
                                                end: segment.end,
                                                text: segment.text))
                continue
            }

            let runs = speakerRuns(words: words, labels: labels, range: range)
            if runs.count == 1, let only = runs.first {
                result.append(TranscriptSegment(speaker: only.speaker,
                                                start: segment.start,
                                                end: segment.end,
                                                text: segment.text))
            } else {
                for run in runs {
                    guard let first = run.words.first, let last = run.words.last else { continue }
                    result.append(TranscriptSegment(speaker: run.speaker,
                                                    start: first.start,
                                                    end: last.end,
                                                    text: TranscriptSegmentSplitter.joinWords(run.words)))
                }
            }
        }
        return result
    }

    /// «Островок» — не длиннее стольких слов подряд внутри речи другого человека.
    static let islandMaxWords = 2
    /// Пауза, которая сама по себе считается границей реплики.
    static let islandPause = 0.5

    /// Спикер каждого слова, сглаженный от дрожания разметки. Диаризатор
    /// (Nemotron заметно чаще pyannote) отдаёт другому человеку слово-два
    /// посреди фразы: «Американская, [стайсик,] и мне нравится». Островок,
    /// окружённый речью ОДНОГО и того же человека, остаётся отдельной репликой,
    /// только если с ОБЕИХ сторон у него естественная граница — конец
    /// предложения или пауза ≥ `islandPause`. Так выживают настоящие короткие
    /// ответы («…не бьётся. [Логично.] Идём дальше.»), а дрожание уходит
    /// соседу. Замер на 85-минутной записи с тремя голосами: у Nemotron смен
    /// говорящего 284 → 237, островков 42 → 10, и все оставшиеся — короткие
    /// ответы и эхо («Логично.», «Конечно.», «Всех инвестиций?»).
    static func speakers(of words: [TranscriptWord], spans: [SpeakerSpan]) -> [String] {
        guard !spans.isEmpty else { return [] }
        var labels = words.map { speaker(for: $0, spans: spans) }

        var runs: [(range: Range<Int>, speaker: String)] = []
        for (index, label) in labels.enumerated() {
            if let last = runs.last, last.speaker == label {
                runs[runs.count - 1].range = last.range.lowerBound..<index + 1
            } else {
                runs.append((index..<index + 1, label))
            }
        }

        var k = 1
        while k + 1 < runs.count {
            let previous = runs[k - 1], island = runs[k], next = runs[k + 1]
            let first = island.range.lowerBound, last = island.range.upperBound - 1
            let isIsland = island.range.count <= islandMaxWords && previous.speaker == next.speaker
            let boundaryBefore = isBoundary(after: words[first - 1], next: words[first])
            let boundaryAfter = isBoundary(after: words[last], next: words[last + 1])
            guard isIsland, !(boundaryBefore && boundaryAfter) else {
                k += 1
                continue
            }
            for index in island.range { labels[index] = previous.speaker }
            runs[k - 1].range = previous.range.lowerBound..<next.range.upperBound
            runs.removeSubrange(k...k + 1)
        }
        return labels
    }

    private static func isBoundary(after word: TranscriptWord, next: TranscriptWord) -> Bool {
        next.start - word.end >= islandPause
            || TranscriptSegmentSplitter.isSentenceBoundary(after: word, next: next)
    }

    // MARK: - Внутренности

    private struct SpeakerRun {
        let speaker: String
        var words: [TranscriptWord]
    }

    /// Слова сегмента (`range` в `words`), разбитые на подряд идущие реплики
    /// одного говорящего по уже сглаженным `labels`.
    private static func speakerRuns(words: [TranscriptWord], labels: [String],
                                    range: Range<Int>) -> [SpeakerRun] {
        var runs: [SpeakerRun] = []
        for index in range {
            let word = words[index], speaker = labels[index]
            if var last = runs.last, last.speaker == speaker {
                last.words.append(word)
                runs[runs.count - 1] = last
            } else {
                runs.append(SpeakerRun(speaker: speaker, words: [word]))
            }
        }
        return runs
    }

    /// Спикер слова — по средней точке слова (как раздача слов сегментам).
    /// Слово, не попавшее ни в один интервал (пауза между репликами, речь
    /// короче порога диаризатора), достаётся ближайшему интервалу: оставить
    /// его без спикера значило бы разорвать реплику надвое.
    private static func speaker(for word: TranscriptWord, spans: [SpeakerSpan]) -> String {
        let mid = (word.start + word.end) / 2
        if let containing = spans.first(where: { mid >= $0.start && mid <= $0.end }) {
            return containing.speaker
        }
        var best = spans[0]
        var bestDistance = Double.infinity
        for span in spans {
            let distance = mid < span.start ? span.start - mid : mid - span.end
            if distance < bestDistance {
                bestDistance = distance
                best = span
            }
        }
        return best.speaker
    }

    /// Спикер сегмента без слов — с наибольшим перекрытием по времени.
    /// Нулевое перекрытие со всеми (сегмент в тишине) оставляет спикера пустым:
    /// выдумывать его не на чем.
    private static func dominantSpeaker(for segment: TranscriptSegment,
                                        spans: [SpeakerSpan]) -> String? {
        var totals: [String: Double] = [:]
        for span in spans {
            let overlap = min(segment.end, span.end) - max(segment.start, span.start)
            if overlap > 0 {
                totals[span.speaker, default: 0] += overlap
            }
        }
        return totals.max { $0.value < $1.value }?.key
    }
}
