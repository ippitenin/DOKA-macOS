import XCTest
@testable import DOKA

/// Поток текста от языковой модели: сборка UTF-8 из байтов токенов,
/// вырезание размышлений, детектор зацикливания, чистка ответа.
final class LLMTextTests: XCTestCase {

    // MARK: - UTF8StreamDecoder

    /// Кириллица двухбайтная, эмодзи четырёхбайтное: декодер обязан собрать
    /// исходную строку при ЛЮБОМ разбиении байтового потока.
    func testDecoderReassemblesTextAtEveryByteSplit() {
        let source = "Привет, мир! 🎧 ok"
        let bytes = Array(source.utf8)
        for split in 0...bytes.count {
            var decoder = LLMText.UTF8StreamDecoder()
            var result = decoder.append(Array(bytes[0..<split]))
            result += decoder.append(Array(bytes[split...]))
            result += decoder.flush()
            XCTAssertEqual(result, source, "разрез после байта \(split)")
        }
    }

    /// Побайтовая подача — самый злой случай: наружу до конца символа не
    /// должно уйти ничего.
    func testDecoderByteByByte() {
        let source = "Ёлка 🌲 и текст"
        var decoder = LLMText.UTF8StreamDecoder()
        var result = ""
        for byte in Array(source.utf8) {
            let piece = decoder.append([byte])
            XCTAssertFalse(piece.contains("\u{FFFD}"), "наружу ушёл обрывок символа")
            result += piece
        }
        result += decoder.flush()
        XCTAssertEqual(result, source)
    }

    func testDecoderHoldsIncompleteSequence() {
        var decoder = LLMText.UTF8StreamDecoder()
        // Первый байт «П» (0xD0) — символ ещё не закончен.
        XCTAssertEqual(decoder.append([0xD0]), "")
        XCTAssertEqual(decoder.append([0x9F]), "П")
    }

    // MARK: - ThinkFilter

    func testThinkFilterRemovesWholeBlock() {
        var filter = LLMText.ThinkFilter()
        let output = filter.feed("До <think>рассуждение</think> после") + filter.flush()
        XCTAssertEqual(output, "До  после")
    }

    /// Тег приходит разорванным между кусками — самый частый случай в потоке.
    func testThinkFilterHandlesTagSplitAcrossChunks() {
        var filter = LLMText.ThinkFilter()
        var output = filter.feed("начало <thi")
        output += filter.feed("nk>скрытое</thi")
        output += filter.feed("nk> конец")
        output += filter.flush()
        XCTAssertEqual(output, "начало  конец")
    }

    /// Незакрытый блок В НАЧАЛЕ ответа — настоящее размышление: выбрасываем.
    func testThinkFilterDropsUnclosedBlockAtStart() {
        var filter = LLMText.ThinkFilter()
        let output = filter.feed("<think>дальше только мысли") + filter.flush()
        XCTAssertEqual(output, "")
    }

    /// Незакрытый блок ПОСЛЕ написанного текста — процитированный тег, а не
    /// мысль: выбросить его значило бы потерять отчёт от этого места до конца.
    func testThinkFilterKeepsUnclosedTagAfterVisibleText() {
        var filter = LLMText.ThinkFilter()
        let output = filter.feed("## Отчёт\nМодель пишет <think> в ответе, и дальше важный текст")
            + filter.flush()
        XCTAssertTrue(output.hasPrefix("## Отчёт"))
        XCTAssertTrue(output.hasSuffix("важный текст"))
    }

    /// Одинокая «<» не должна застрять в фильтре навсегда.
    func testThinkFilterFlushesPartialTag() {
        var filter = LLMText.ThinkFilter()
        let output = filter.feed("текст <th") + filter.flush()
        XCTAssertEqual(output, "текст <th")
    }

    func testThinkFilterPassesPlainText() {
        var filter = LLMText.ThinkFilter()
        let output = filter.feed("## Заголовок\n- пункт") + filter.flush()
        XCTAssertEqual(output, "## Заголовок\n- пункт")
    }

    // MARK: - LoopDetector

    func testLoopDetectorFindsRepeatingFragment() {
        var detector = LLMText.LoopDetector()
        var tripped = false
        for _ in 0..<8 {
            if detector.feed("- Обсудили сроки проекта\n") { tripped = true; break }
        }
        XCTAssertTrue(tripped)
    }

    func testLoopDetectorIgnoresNormalText() {
        var detector = LLMText.LoopDetector()
        let lines = ["## Суть\n", "Команда обсудила сроки и бюджет.\n",
                     "- Аня готовит смету к пятнице\n", "- Борис проверяет договор\n",
                     "## Итог\n", "Решили перенести релиз на март.\n"]
        for line in lines {
            XCTAssertFalse(detector.feed(line))
        }
    }

    /// Разделитель и строки markdown-таблицы повторяются по своей природе.
    /// Встроенный «Протокол встречи» просит таблицу ровно из ЧЕТЫРЁХ колонок,
    /// а системный промпт велит писать «Не указано» в пустых ячейках — без
    /// правила про «|» детектор рубил бы отчёт посреди таблицы.
    func testLoopDetectorIgnoresMarkdownTable() {
        for line in ["|--------|--------|--------|--------|\n",
                     "| ----- | ----- | ----- | ----- |\n",
                     "| Не указано | Не указано | Не указано | Не указано |\n",
                     "| Ответственный | Задача | Срок | Тайм-код |\n"] {
            var detector = LLMText.LoopDetector()
            XCTAssertFalse(detector.feed(line), "оборвано на строке таблицы: \(line)")
        }
    }

    /// Повтор дефисов и точек — оформление, а не зацикливание.
    func testLoopDetectorIgnoresPunctuationRuns() {
        var detector = LLMText.LoopDetector()
        XCTAssertFalse(detector.feed(String(repeating: "-", count: 200)))
        XCTAssertFalse(detector.feed(String(repeating: ". ", count: 120)))
    }

    /// Повтор пробелов и переносов — это оформление, а не зацикливание.
    func testLoopDetectorIgnoresWhitespace() {
        var detector = LLMText.LoopDetector()
        for _ in 0..<40 {
            XCTAssertFalse(detector.feed("\n"))
        }
    }

    // MARK: - clean

    func testCleanStripsThinkAndFence() {
        let raw = "<think>подумал</think>\n```markdown\n## Отчёт\n- пункт\n```"
        XCTAssertEqual(LLMText.clean(raw), "## Отчёт\n- пункт")
    }

    /// Забор, закрытый на одной строке с текстом: снимать надо сам забор,
    /// а не последнюю строку — иначе пропадает содержимое.
    func testCleanKeepsContentWhenFenceClosesInline() {
        XCTAssertEqual(LLMText.clean("```markdown\n## Отчёт\n- пункт```"), "## Отчёт\n- пункт")
        XCTAssertEqual(LLMText.clean("```\nТолько одна строка```"), "Только одна строка")
    }

    func testCleanKeepsInnerCodeBlock() {
        let raw = "## Отчёт\n\n```\nкод\n```\n\nКонец"
        XCTAssertEqual(LLMText.clean(raw), raw)
    }

    /// Ответ, целиком состоящий из ДВУХ блоков кода, разворачивать нельзя:
    /// снятие внешнего забора склеило бы их в один.
    func testCleanKeepsTwoCodeBlocks() {
        let raw = "```\nодин\n```\n\n```\nдва\n```"
        XCTAssertEqual(LLMText.clean(raw), raw)
    }

    func testCleanDropsUnclosedThink() {
        XCTAssertEqual(LLMText.clean("<think>только мысли"), "")
    }

    /// `clean` работает над уже отфильтрованным текстом, но и сама не должна
    /// съедать отчёт из-за тега, процитированного в его середине.
    func testCleanKeepsTextAfterQuotedThinkTag() {
        let raw = "## Отчёт\nМодель вывела `<think>` и продолжила."
        XCTAssertEqual(LLMText.clean(raw), raw)
    }

    // MARK: - CJK

    func testContainsCJK() {
        XCTAssertTrue(LLMText.containsCJK("会议"))
        XCTAssertTrue(LLMText.containsCJK("ありがとう"))
        XCTAssertTrue(LLMText.containsCJK("회의"))
        XCTAssertFalse(LLMText.containsCJK("Совещание"))
        XCTAssertFalse(LLMText.containsCJK("Meeting #1 — 12:34"))
    }
}
