import Foundation

/// Вырезает тишину из WAV-записи диктовки (формат `WavWriter`: PCM 16 кГц
/// mono Int16) перед отправкой на распознавание: меньше галлюцинаций на
/// паузах и быстрее обработка длинных записей. Оригинал не меняется —
/// результат пишется в отдельный временный WAV; история, статистика и m4a
/// продолжают работать с оригиналом. Синхронная CPU-работа — вызывать вне
/// главного потока.
enum SilenceRemover {
    /// Окно анализа: 20 мс при 16 кГц.
    static let windowSamples = 320
    /// Порог тишины в дБFS — согласован с `AudioRecorder.speechLevelThreshold`
    /// (нормализованный 0.2 ≈ −40 дБ).
    static let silenceThresholdDb: Float = -40
    /// Паддинг вокруг речи, в окнах: 12 × 20 мс = 0.24 с с каждой стороны —
    /// слова не режутся, стыки звучат естественно.
    static let paddingWindows = 12
    /// Выигрыш меньше 10% — обрезка не окупается, шлём оригинал.
    static let minSavingRatio = 0.1
    /// Результат короче порога `DictationGate.minDuration` — оригинал.
    static let minResultDuration = 0.4

    /// URL нового WAV без тишины; nil — резать нечего или не вышло
    /// (отправляется оригинал).
    static func process(_ url: URL) -> URL? {
        guard let data = try? Data(contentsOf: url), data.count > 44 else { return nil }
        let sampleCount = (data.count - 44) / 2
        guard sampleCount >= windowSamples else { return nil }

        // Data может быть не выровнена под Int16 — копируем в массив.
        var samples = [Int16](repeating: 0, count: sampleCount)
        _ = samples.withUnsafeMutableBytes { dest in
            data.copyBytes(to: dest, from: 44..<(44 + sampleCount * 2))
        }

        // Маска «в окне есть речь»: RMS окна → дБ → порог.
        let windowCount = (sampleCount + windowSamples - 1) / windowSamples
        var voiced = [Bool](repeating: false, count: windowCount)
        for w in 0..<windowCount {
            let start = w * windowSamples
            let end = min(start + windowSamples, sampleCount)
            var sum: Float = 0
            for i in start..<end {
                let v = Float(samples[i]) / 32768
                sum += v * v
            }
            let rms = (sum / Float(end - start)).squareRoot()
            let db = 20 * log10(max(rms, 1e-7))
            voiced[w] = db >= silenceThresholdDb
        }

        // Паддинг: тишина рядом с речью сохраняется.
        var keep = [Bool](repeating: false, count: windowCount)
        for w in voiced.indices where voiced[w] {
            for i in max(0, w - paddingWindows)...min(windowCount - 1, w + paddingWindows) {
                keep[i] = true
            }
        }

        // Стоит ли игра свеч.
        var keptSamples = 0
        for w in keep.indices where keep[w] {
            keptSamples += min((w + 1) * windowSamples, sampleCount) - w * windowSamples
        }
        let total = Double(sampleCount) / Double(WavWriter.sampleRate)
        let kept = Double(keptSamples) / Double(WavWriter.sampleRate)
        guard kept >= minResultDuration, total - kept >= total * minSavingRatio else { return nil }

        // Сборка нового WAV существующим writer'ом, непрерывными кусками.
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("doka-trimmed-\(UUID().uuidString).wav")
        do {
            let writer = try WavWriter(url: outURL)
            var w = 0
            while w < windowCount {
                guard keep[w] else { w += 1; continue }
                var end = w
                while end + 1 < windowCount, keep[end + 1] { end += 1 }
                let range = (w * windowSamples)..<min((end + 1) * windowSamples, sampleCount)
                samples[range].withUnsafeBytes { writer.append(Data($0)) }
                w = end + 1
            }
            try writer.finalize()
            return outURL
        } catch {
            NSLog("DOKA: не удалось обрезать тишину: \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: outURL)
            return nil
        }
    }
}
