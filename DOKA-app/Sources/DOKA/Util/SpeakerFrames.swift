import Foundation

/// Покадровая разметка диаризатора → интервалы говорящих. Чистые функции
/// (как `SpeakerAssignment`), FluidAudio здесь не импортируется.
///
/// Nemotron отдаёт на каждые 10 мс вероятность речи каждого из своих слотов —
/// независимо, поэтому голоса могут перекрываться. Сшивка со словами
/// (`SpeakerAssignment`) рассчитана на непересекающиеся интервалы, как у
/// pyannote: в каждом кадре говорит один — самый уверенный из тех, кто выше
/// порога.
enum SpeakerFrames {
    /// Порог активности слота — тот же, что у `Nemotron3Diarizer.segments`.
    static let threshold: Float = 0.5
    /// Отрезок короче (0,2 с) — шум разметки: выбрасывается, а его слова
    /// `SpeakerAssignment` отдаст ближайшему соседу.
    static let minRunFrames = 20
    static let frameSeconds = 0.01

    /// Говорящий каждого кадра: индекс слота или -1 (тишина). Вход —
    /// `[кадры × слоты]` построчно, как у Nemotron.
    static func labels(probabilities: [Float], numSpeakers: Int,
                       threshold: Float = threshold) -> [Int8] {
        guard numSpeakers > 0 else { return [] }
        let frames = probabilities.count / numSpeakers
        var result = [Int8](repeating: -1, count: frames)
        for frame in 0..<frames {
            var best = -1
            var bestProbability = threshold
            for slot in 0..<numSpeakers {
                let probability = probabilities[frame * numSpeakers + slot]
                if probability > bestProbability {
                    best = slot
                    bestProbability = probability
                }
            }
            result[frame] = Int8(best)
        }
        return result
    }

    /// Подряд идущие кадры одного слота → интервалы `speaker_N`.
    static func spans(labels: [Int8], minRunFrames: Int = minRunFrames,
                      frameSeconds: Double = frameSeconds) -> [SpeakerSpan] {
        guard !labels.isEmpty else { return [] }
        var raw: [(id: String, start: Double, end: Double)] = []
        var runStart = 0
        for frame in 1...labels.count {
            if frame < labels.count, labels[frame] == labels[runStart] { continue }
            if labels[runStart] >= 0, frame - runStart >= minRunFrames {
                raw.append((String(labels[runStart]),
                            Double(runStart) * frameSeconds,
                            Double(frame) * frameSeconds))
            }
            runStart = frame
        }
        return remapByFirstAppearance(raw)
    }

    /// Сырые идентификаторы диаризатора (`S1`, слот `3`…) → `speaker_0`,
    /// `speaker_1` по порядку первого появления. Порядок именно первого
    /// появления, а не сортировки строк: у Nexara нумерация тоже идёт по ходу
    /// записи, и цвет бэйджа в UI считается так же. Иначе `SpeakerName` и все
    /// экспорты показали бы сырой id.
    static func remapByFirstAppearance(_ raw: [(id: String, start: Double, end: Double)]) -> [SpeakerSpan] {
        var mapping: [String: String] = [:]
        return raw.sorted { $0.start < $1.start }.map { item in
            let speaker: String
            if let known = mapping[item.id] {
                speaker = known
            } else {
                speaker = "speaker_\(mapping.count)"
                mapping[item.id] = speaker
            }
            return SpeakerSpan(speaker: speaker, start: item.start, end: item.end)
        }
    }
}
