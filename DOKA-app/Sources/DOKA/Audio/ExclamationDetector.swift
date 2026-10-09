import Accelerate
import Foundation

/// «!» по интонации: если диктовка кончается точкой, а тон в конце речи резко
/// падает, как в восклицании, точка становится «!». Whisper и другие сервисы
/// восклицательный знак почти не ставят: на записях владельца — 7 из 17.
///
/// Смотрит только на тон последних 1,6 с речи: шесть признаков в полутонах
/// от своей медианы. Громкости в модели нет: тихо сказанная фраза — не повод
/// менять знак. Тайм-коды слов не нужны, поэтому работает с любым сервисом.
///
/// Ошибается в безопасную сторону. На 73 фразах владельца, на словах, которых
/// не было в обучении, звук добавил 2 восклицания из 17 и не поставил ни
/// одного лишнего «!» на 56 фразах без него. Порог взят с запасом.
///
/// Каждый шаг повторяет стенд на Python один в один (перцентили — как у numpy,
/// полоса — БПФ длиной в степень двойки): константы модели посчитаны там.
/// Синхронная CPU-работа (≈10–30 мс) — вызывать вне главного потока.
enum ExclamationDetector {
    // MARK: - Модель

    /// Логистическая регрессия «!» против точки на z-оценках признаков в порядке
    /// `rise, fall, slope, range, end, endPosition`. Обучена 9.10.2026 на
    /// 75 фразах владельца (две записи, «…» считалось точкой).
    static let mean: [Double] = [1.085056, 3.589997, -3.924399, 7.895434, -1.652818, 0.232311]
    static let scale: [Double] = [4.372583, 3.566778, 13.281899, 3.298011, 3.479257, 0.306475]
    static let weights: [Double] = [-0.158870, 0.643195, -0.053323, 0.451227, -0.909732, 0.453887]
    static let bias = -1.663530
    /// Первый порог без лишних «!» в проверке был 0,75, но ближайшая обычная
    /// точка стояла вплотную (0,74) — отсюда запас.
    static let threshold = 0.8

    /// Сокращения, после которых точка — не конец фразы («в 2026 г.», «и др.»).
    static let abbreviations: Set<String> = ["г", "гг", "др", "пр", "см", "руб", "тыс", "млн", "млрд",
                                             "коп", "стр", "ул", "рис", "табл", "англ", "напр"]

    // MARK: - Знак

    /// Текст, у которого последняя точка заменена на «!», если `probability`
    /// не ниже порога, а точка — одиночная, не после сокращения и в русском
    /// предложении. Иначе — текст как есть.
    static func apply(to text: String, probability: Double?) -> String {
        guard let probability, probability >= threshold,
              let dot = text.lastIndex(where: { !$0.isWhitespace }), text[dot] == "." else { return text }
        let head = text[..<dot]
        if head.last == "." || head.last?.isWhitespace != false { return text }   // «...», «. »
        // Последнее слово: сокращение с внутренней точкой («т.д.»), одна буква, список сокращений.
        let word = head.split(whereSeparator: { $0.isWhitespace }).last.map(String.init) ?? ""
        if word.contains(".") { return text }
        let letters = word.filter(\.isLetter).lowercased()
        if letters.count == 1 || abbreviations.contains(letters) { return text }
        // Модель знает только русскую интонацию: в последнем предложении нужна кириллица.
        let sentenceStart = head.lastIndex(where: { ".!?…".contains($0) }).map { head.index(after: $0) }
            ?? head.startIndex
        guard head[sentenceStart...].unicodeScalars.contains(where: { (0x0400...0x04FF).contains($0.value) })
        else { return text }
        var result = text
        result.replaceSubrange(dot...dot, with: "!")
        return result
    }

    // MARK: - Звук

    static let sampleRate = 16_000
    private static let frame = 400                  // 25 мс
    private static let hop = 160                    // 10 мс
    private static let minLag = 40, maxLag = 228    // 400…70 Гц
    private static let yinThreshold = 0.3
    private static let tail = 1.6                   // хвост речи, с
    private static let preRoll = 0.3                // запас до хвоста, с
    private static let lastWord = 0.5               // «последнее слово», с
    private static let minPiece = 0.2, maxGap = 0.6 // кусок речи не короче; склейка через паузу до, с

    /// Вероятность «!» по WAV диктовки (`WavWriter`: 16 кГц mono Int16);
    /// nil — файла нет или мало голоса.
    static func probability(wavURL: URL) -> Double? {
        guard let data = try? Data(contentsOf: wavURL), data.count > 44 else { return nil }
        let count = (data.count - 44) / 2
        var pcm = [Int16](repeating: 0, count: count)
        _ = pcm.withUnsafeMutableBytes { data.copyBytes(to: $0, from: 44..<(44 + count * 2)) }
        return probability(samples: pcm.map { Double($0) / 32768 })
    }

    /// Вероятность «!» по отсчётам 16 кГц в [-1, 1]; nil — мало голоса.
    static func probability(samples: [Double]) -> Double? {
        guard let f = features(samples) else { return nil }
        var z = bias
        for i in f.indices { z += weights[i] * (f[i] - mean[i]) / scale[i] }
        return 1 / (1 + exp(-z))
    }

    /// Признаки в порядке модели; nil — речи или голоса не нашлось.
    static func features(_ samples: [Double]) -> [Double]? {
        let (times0, db0) = frameLevels(samples)
        guard let first = speechSpan(times: times0, db: db0) else { return nil }
        let cut = max(0, Int((max(first.start, first.end - tail) - preRoll) * Double(sampleRate)))
        let x = Array(samples[min(cut, samples.count)...])
        let (t, db) = frameLevels(x)
        guard let span = speechSpan(times: t, db: db) else { return nil }
        let f0 = pitch(x, db: db)

        let inSpan = t.indices.filter { t[$0] >= span.start && t[$0] <= span.end }
        let voiced = inSpan.filter { !f0[$0].isNaN }
        guard voiced.count >= 10 else { return nil }
        let lastStart = max(span.start, span.end - lastWord)
        let median = Percentile.linear(voiced.map { f0[$0] }.sorted(), 0.5)!
        var st = [Double](repeating: .nan, count: t.count)
        for i in voiced { st[i] = 12 * log2(f0[i] / median) }

        var lastVoiced = voiced.filter { t[$0] >= lastStart }
        if lastVoiced.count < 3 { lastVoiced = voiced.filter { t[$0] >= t[voiced.last!] - lastWord } }
        var bodyVoiced = voiced.filter { t[$0] < lastStart }
        if bodyVoiced.count < 3 { bodyVoiced = voiced }

        let peak = Percentile.linear(lastVoiced.map { st[$0] }.sorted(), 0.9)!
        let end = Percentile.linear(voiced.suffix(5).map { st[$0] }.sorted(), 0.5)!
        let tailIdx = Array(voiced.suffix(20))
        let slope = tailIdx.count >= 5 ? slopeOf(tailIdx.map { t[$0] }, tailIdx.map { st[$0] }) : 0
        let all = voiced.map { st[$0] }.sorted()
        let low = Percentile.linear(all, 0.05)!, high = Percentile.linear(all, 0.95)!
        let body = Percentile.linear(bodyVoiced.map { st[$0] }.sorted(), 0.5)!
        return [peak - body, peak - end, slope, high - low, end, (end - low) / (high - low + 1e-6)]
    }

    /// Громкость кадров 25 мс с шагом 10 мс (дБFS) и время их середин.
    private static func frameLevels(_ x: [Double]) -> (times: [Double], db: [Double]) {
        let count = max(0, (x.count - frame - maxLag) / hop)
        var times = [Double](repeating: 0, count: count)
        var db = [Double](repeating: 0, count: count)
        x.withUnsafeBufferPointer { p in
            for i in 0..<count {
                var sum = 0.0
                for j in (i * hop)..<(i * hop + frame) { sum += p[j] * p[j] }
                db[i] = 20 * log10((sum / Double(frame)).squareRoot() + 1e-9)
                times[i] = (Double(i * hop) + Double(frame) / 2) / Double(sampleRate)
            }
        }
        return (times, db)
    }

    /// Последний кусок речи не короче 0,2 с (паузы до 0,6 с склеиваются). Порог —
    /// 20 дБ ниже пика клипа, но не ниже шума + 8 дБ: от пика, чтобы тише
    /// сказанная фраза резалась там же.
    private static func speechSpan(times t: [Double], db: [Double]) -> (start: Double, end: Double)? {
        let sorted = db.sorted()
        guard let floor = Percentile.linear(sorted, 0.1), let peak = Percentile.linear(sorted, 0.99) else { return nil }
        let level = max(floor + 8, peak - 20)
        let on = db.indices.filter { db[$0] > level }
        guard var start = on.first else { return nil }
        var pieces: [(Int, Int)] = []
        var prev = start
        for i in on.dropFirst() {
            if t[i] - t[prev] > maxGap {
                pieces.append((start, prev))
                start = i
            }
            prev = i
        }
        pieces.append((start, prev))
        let long = pieces.filter { t[$0.1] - t[$0.0] >= minPiece }
        let piece = (long.isEmpty ? pieces : long).last!
        return (t[piece.0] - 0.02, t[piece.1] + 0.02)
    }

    /// Тон кадров (Гц, NaN — нет голоса): YIN по полосе 60–900 Гц, только в
    /// кадрах не тише ворот `max(шум + 6, пик − 25)` дБ. Скачки дальше 9 полутонов
    /// от медианы клипа — ошибки на октаву, выбрасываются.
    private static func pitch(_ x: [Double], db: [Double]) -> [Double] {
        var f0 = [Double](repeating: .nan, count: db.count)
        let sorted = db.sorted()
        guard let floor = Percentile.linear(sorted, 0.1), let peak = Percentile.linear(sorted, 0.99) else { return f0 }
        let gate = max(floor + 6, peak - 25)
        let y = bandpass(x)
        var diff = [Double](repeating: 0, count: maxLag)   // diff[k] — для лага k + 1
        var cmnd = [Double](repeating: 0, count: maxLag)
        y.withUnsafeBufferPointer { p in
            for i in db.indices where db[i] >= gate {
                let o = i * hop
                for lag in 1...maxLag {
                    var sum = 0.0
                    for j in 0..<frame {
                        let d = p[o + j] - p[o + lag + j]
                        sum += d * d
                    }
                    diff[lag - 1] = sum
                }
                var cumulative = 0.0
                for k in 0..<maxLag {
                    cumulative += diff[k]
                    cmnd[k] = diff[k] * Double(k + 1) / max(cumulative, 1e-12)
                }
                guard var lag = (minLag..<maxLag).first(where: { cmnd[$0 - 1] < yinThreshold }) else { continue }
                while lag + 1 < maxLag && cmnd[lag] < cmnd[lag - 1] { lag += 1 }
                let a = cmnd[lag - 2], b = cmnd[lag - 1], c = cmnd[lag]
                let denom = a - 2 * b + c
                let shift = denom != 0 ? min(max(0.5 * (a - c) / denom, -1), 1) : 0
                f0[i] = Double(sampleRate) / (Double(lag) + shift)
            }
        }
        let found = f0.filter { !$0.isNaN }
        if found.count >= 5, let median = Percentile.linear(found.sorted(), 0.5) {
            for i in f0.indices where !f0[i].isNaN && abs(12 * log2(f0[i] / median)) > 9 { f0[i] = .nan }
        }
        return f0
    }

    /// Полоса 60–900 Гц: БПФ длиной в степень двойки, остальные частоты — в ноль.
    /// Масштаб результата для YIN не важен, но приведён к исходному.
    private static func bandpass(_ x: [Double]) -> [Double] {
        var n = 2
        while n < x.count { n <<= 1 }
        let log2n = vDSP_Length(n.trailingZeroBitCount)
        guard let setup = vDSP_create_fftsetupD(log2n, FFTRadix(kFFTRadix2)) else { return x }
        defer { vDSP_destroy_fftsetupD(setup) }
        var signal = x + [Double](repeating: 0, count: n - x.count)
        var real = [Double](repeating: 0, count: n / 2)
        var imag = [Double](repeating: 0, count: n / 2)
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPDoubleSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                signal.withUnsafeBytes {
                    vDSP_ctozD($0.bindMemory(to: DSPDoubleComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(n / 2))
                }
                vDSP_fft_zripD(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
                rp[0] = 0   // постоянная составляющая
                ip[0] = 0   // частота Найквиста (у vDSP лежит здесь)
                for k in 1..<(n / 2) {
                    let hz = Double(k) * Double(sampleRate) / Double(n)
                    if hz < 60 || hz > 900 {
                        rp[k] = 0
                        ip[k] = 0
                    }
                }
                vDSP_fft_zripD(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Inverse))
                signal.withUnsafeMutableBytes {
                    vDSP_ztocD(&split, 1, $0.bindMemory(to: DSPDoubleComplex.self).baseAddress!, 2, vDSP_Length(n / 2))
                }
            }
        }
        let norm = 1 / Double(2 * n)   // прямое и обратное преобразование vDSP вместе дают 2n
        return signal.prefix(x.count).map { $0 * norm }
    }

    /// Наклон прямой МНК (как `numpy.polyfit(…, 1)[0]`).
    private static func slopeOf(_ x: [Double], _ y: [Double]) -> Double {
        let mx = x.reduce(0, +) / Double(x.count), my = y.reduce(0, +) / Double(y.count)
        var num = 0.0, den = 0.0
        for i in x.indices {
            num += (x[i] - mx) * (y[i] - my)
            den += (x[i] - mx) * (x[i] - mx)
        }
        return den > 0 ? num / den : 0
    }
}
