import XCTest
@testable import DOKA

/// Вырезание тишины из WAV диктовки перед отправкой на распознавание.
///
/// Зачем: это единственное место, где мы МЕНЯЕМ звук, уходящий на платное
/// распознавание. Ошибка в арифметике окон или паддинга не падает и ничего
/// не логирует — она просто откусывает первый слог или середину фразы, и
/// пользователь видит «сервис плохо распознал». Четыре порога
/// (`silenceThresholdDb`, `paddingWindows`, `minSavingRatio`,
/// `minResultDuration`) закрепляются здесь как контракт.
///
/// Фикстуры — синтетический WAV через `WavWriter` (прецедент
/// `SourceAudioArchiverTests`): ни микрофона, ни сети.
final class SilenceRemoverTests: XCTestCase {

    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("doka-silence-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: - Фикстуры

    /// Кусок записи: `speech == false` — ровная тишина (нули).
    private struct Chunk {
        let seconds: Double
        let speech: Bool
    }

    /// WAV 16 кГц mono Int16 из последовательности кусков.
    private func makeWav(_ chunks: [Chunk], name: String = "in.wav") throws -> URL {
        let url = tmp.appendingPathComponent(name)
        let writer = try WavWriter(url: url)
        var phase = 0
        for chunk in chunks {
            let count = Int(chunk.seconds * Double(WavWriter.sampleRate))
            var samples = [Int16](repeating: 0, count: count)
            if chunk.speech {
                for i in 0..<count {
                    let t = Double(phase + i) / Double(WavWriter.sampleRate)
                    samples[i] = Int16(sin(2 * .pi * 440 * t) * 0.5 * Double(Int16.max))
                }
            }
            phase += count
            samples.withUnsafeBufferPointer { writer.append(Data(buffer: $0)) }
        }
        try writer.finalize()
        return url
    }

    /// Длительность WAV по размеру данных (заголовок 44 байта, Int16 mono).
    private func duration(of url: URL) throws -> Double {
        let size = try Data(contentsOf: url).count
        return Double((size - 44) / 2) / Double(WavWriter.sampleRate)
    }

    private func process(_ url: URL) -> URL? {
        let result = SilenceRemover.process(url)
        if let result { addTeardownBlock { try? FileManager.default.removeItem(at: result) } }
        return result
    }

    // MARK: - Когда резать нечего

    /// Сплошная речь: выигрыш нулевой, обрезка не окупается — оригинал.
    func testAllSpeechIsNotTrimmed() throws {
        let url = try makeWav([Chunk(seconds: 3, speech: true)])
        XCTAssertNil(process(url))
    }

    /// Сплошная тишина: резать можно всё, но результат короче
    /// `minResultDuration` — отправляем оригинал, а не пустой файл.
    /// (До API такая запись всё равно не дойдёт — её остановит `DictationGate`.)
    func testAllSilenceIsNotTrimmed() throws {
        let url = try makeWav([Chunk(seconds: 3, speech: false)])
        XCTAssertNil(process(url))
    }

    /// Выигрыш меньше `minSavingRatio` (10 %) — не окупается.
    func testTooSmallSavingIsNotTrimmed() throws {
        // 0.2 с тишины при 5 с речи: даже без паддинга это 4 %.
        let url = try makeWav([Chunk(seconds: 5, speech: true), Chunk(seconds: 0.2, speech: false)])
        XCTAssertNil(process(url))
    }

    func testFileShorterThanOneWindowIsNotTrimmed() throws {
        // Меньше `windowSamples` (320 сэмплов = 20 мс).
        let url = try makeWav([Chunk(seconds: 0.01, speech: true)])
        XCTAssertNil(process(url))
    }

    func testMissingFileIsNotTrimmed() {
        XCTAssertNil(SilenceRemover.process(tmp.appendingPathComponent("нет-такого.wav")))
    }

    /// Файл из одного заголовка без данных не должен ронять обрезку.
    func testHeaderOnlyFileIsNotTrimmed() throws {
        let url = tmp.appendingPathComponent("empty.wav")
        let writer = try WavWriter(url: url)
        try writer.finalize()
        XCTAssertNil(SilenceRemover.process(url))
    }

    // MARK: - Когда резать стоит

    /// Речь — тишина — речь: середина уходит, края остаются.
    func testLongSilenceInTheMiddleIsRemoved() throws {
        let url = try makeWav([
            Chunk(seconds: 1, speech: true),
            Chunk(seconds: 5, speech: false),
            Chunk(seconds: 1, speech: true),
        ])
        let trimmed = try XCTUnwrap(process(url))
        XCTAssertNotEqual(trimmed, url, "обрезка обязана писать НОВЫЙ файл — оригинал нужен истории и m4a")
        let result = try duration(of: trimmed)
        XCTAssertLessThan(result, 7)
        XCTAssertGreaterThan(result, 2, "две секунды речи обязаны остаться целиком")
        // 2 с речи + по 0.24 с паддинга с ВНУТРЕННЕЙ стороны каждого островка:
        // внешние стороны упираются в границы файла и обрезаются по ним.
        XCTAssertEqual(result, 2 + 2 * 0.24, accuracy: 0.05)
    }

    /// Оригинал не трогается — история, статистика и m4a работают с ним.
    func testOriginalSurvivesTrimming() throws {
        let url = try makeWav([
            Chunk(seconds: 1, speech: true),
            Chunk(seconds: 5, speech: false),
            Chunk(seconds: 1, speech: true),
        ])
        let before = try duration(of: url)
        _ = try XCTUnwrap(process(url))
        XCTAssertEqual(try duration(of: url), before, accuracy: 0.001)
    }

    /// Паддинг вокруг речи: 12 окон × 20 мс = 0.24 с с каждой стороны —
    /// слова не режутся по живому. Тишина В НАЧАЛЕ уходит не вся.
    func testLeadingSilenceKeepsPadding() throws {
        let url = try makeWav([Chunk(seconds: 4, speech: false), Chunk(seconds: 2, speech: true)])
        let trimmed = try XCTUnwrap(process(url))
        let result = try duration(of: trimmed)
        // 2 с речи + 0.24 с паддинга слева (справа речь упирается в конец файла).
        XCTAssertEqual(result, 2 + 0.24, accuracy: 0.05)
    }

    func testTrailingSilenceKeepsPadding() throws {
        let url = try makeWav([Chunk(seconds: 2, speech: true), Chunk(seconds: 4, speech: false)])
        let trimmed = try XCTUnwrap(process(url))
        XCTAssertEqual(try duration(of: trimmed), 2 + 0.24, accuracy: 0.05)
    }

    /// Результат — валидный WAV, который снова можно прогнать через обрезку:
    /// он уже плотный, поэтому второй проход ничего не даёт.
    func testTrimmingIsIdempotent() throws {
        let url = try makeWav([
            Chunk(seconds: 1, speech: true),
            Chunk(seconds: 5, speech: false),
            Chunk(seconds: 1, speech: true),
        ])
        let trimmed = try XCTUnwrap(process(url))
        XCTAssertNil(process(trimmed), "повторная обрезка плотной записи не окупается")
    }

    // MARK: - Пороги как контракт

    func testThresholdsAreStable() {
        XCTAssertEqual(SilenceRemover.windowSamples, 320)          // 20 мс при 16 кГц
        XCTAssertEqual(SilenceRemover.silenceThresholdDb, -40)
        XCTAssertEqual(SilenceRemover.paddingWindows, 12)          // 0.24 с
        XCTAssertEqual(SilenceRemover.minSavingRatio, 0.1)
        // Порог результата согласован с `DictationGate.minDuration`: обрезка
        // не имеет права отдать запись, которую гейт тут же отсеет.
        XCTAssertEqual(SilenceRemover.minResultDuration, DictationGate.minDuration)
    }
}
