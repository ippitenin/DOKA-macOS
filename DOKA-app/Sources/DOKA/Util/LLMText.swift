import Foundation

/// Работа с потоком текста от языковой модели: сборка UTF-8 из байтов
/// токенов, вырезание блока размышлений, детектор зацикливания и чистка
/// готового ответа. Всё — чистые функции и мелкие структуры без зависимостей
/// от llama.cpp: движок пользуется ими, тесты проверяют без модели.
enum LLMText {

    // MARK: - Сборка UTF-8 из кусков

    /// BPE режет текст по байтам, а не по символам: кириллица двухбайтная, и
    /// один токен регулярно заканчивается посреди символа. Декодер отдаёт
    /// наружу только валидный префикс, а незаконченную последовательность
    /// удерживает до следующего куска — иначе в UI сыпались бы «».
    struct UTF8StreamDecoder {
        private var pending: [UInt8] = []

        init() {}

        /// Добавляет байты и возвращает готовый текст (может быть пустым).
        mutating func append(_ bytes: [UInt8]) -> String {
            pending.append(contentsOf: bytes)
            let split = Self.completeLength(of: pending)
            guard split > 0 else { return "" }
            let ready = String(decoding: pending[0..<split], as: UTF8.self)
            pending.removeFirst(split)
            return ready
        }

        /// Остаток после последнего токена: незаконченная последовательность
        /// уже не дополнится, отдаём как есть (с заменой на U+FFFD).
        mutating func flush() -> String {
            guard !pending.isEmpty else { return "" }
            let rest = String(decoding: pending, as: UTF8.self)
            pending.removeAll()
            return rest
        }

        /// Длина префикса, который точно не обрывает символ на середине.
        static func completeLength(of bytes: [UInt8]) -> Int {
            let n = bytes.count
            guard n > 0 else { return 0 }
            // Ведущий байт последней последовательности — не дальше 3 байт от
            // конца: длиннее 4 байт последовательностей в UTF-8 не бывает.
            var i = n - 1
            let lowerBound = max(0, n - 4)
            while i >= lowerBound, bytes[i] & 0b1100_0000 == 0b1000_0000 { i -= 1 }
            guard i >= lowerBound else { return n }   // мусор без ведущего байта — отдаём всё
            let lead = bytes[i]
            let expected: Int
            switch lead {
            case 0x00...0x7F: expected = 1
            case 0xC0...0xDF: expected = 2
            case 0xE0...0xEF: expected = 3
            case 0xF0...0xF7: expected = 4
            default: return n                        // невалидный ведущий байт
            }
            return i + expected > n ? i : n
        }
    }

    // MARK: - Блок размышлений

    /// Потоковое вырезание `<think>…</think>`. Для текущей модели это
    /// страховка (пустой блок дописывается префиллом), но гибридные модели
    /// умеют выдавать его сами, а показывать пользователю сырые размышления
    /// нельзя. Незакрытый блок съедается до конца — это и есть размышление.
    struct ThinkFilter {
        private static let open = "<think>"
        private static let close = "</think>"

        private var pending = ""
        /// Проглоченное содержимое текущего блока: если блок так и не
        /// закроется, а до него уже шёл видимый текст, это была не мысль
        /// модели, а цитата тега — тогда содержимое возвращается наружу.
        private var swallowed = ""
        private var emittedVisibleText = false
        private(set) var isInsideThink = false

        init() {}

        mutating func feed(_ chunk: String) -> String {
            pending += chunk
            var output = ""
            while true {
                if isInsideThink {
                    guard let range = pending.range(of: Self.close) else {
                        // Хвост, который ещё может оказаться началом «</think>»,
                        // придержим; остальное — содержимое блока.
                        let hold = Self.partialSuffix(pending, of: Self.close)
                        swallowed += String(pending.prefix(pending.count - hold))
                        pending = String(pending.suffix(hold))
                        return output
                    }
                    swallowed = ""
                    pending = String(pending[range.upperBound...])
                    isInsideThink = false
                } else {
                    guard let range = pending.range(of: Self.open) else {
                        let hold = Self.partialSuffix(pending, of: Self.open)
                        let emitCount = pending.count - hold
                        let visible = String(pending.prefix(emitCount))
                        output += visible
                        if visible.contains(where: { !$0.isWhitespace }) { emittedVisibleText = true }
                        pending = String(pending.suffix(hold))
                        return output
                    }
                    let visible = String(pending[pending.startIndex..<range.lowerBound])
                    output += visible
                    if visible.contains(where: { !$0.isWhitespace }) { emittedVisibleText = true }
                    pending = String(pending[range.upperBound...])
                    isInsideThink = true
                    swallowed = ""
                }
            }
        }

        /// Хвост после последнего токена. Незакрытый блок в САМОМ НАЧАЛЕ
        /// ответа — настоящее размышление, его выбрасываем. Незакрытый блок
        /// после уже написанного текста — почти наверняка процитированный
        /// тег: выбросить его значило бы потерять весь отчёт от этого места
        /// и до конца.
        mutating func flush() -> String {
            defer { pending = ""; swallowed = ""; isInsideThink = false }
            guard isInsideThink else { return pending }
            return emittedVisibleText ? Self.open + swallowed + pending : ""
        }

        /// Длина самого длинного суффикса `text`, который является префиксом
        /// `tag`: только его имеет смысл придерживать до следующего куска.
        private static func partialSuffix(_ text: String, of tag: String) -> Int {
            let maxLength = min(text.count, tag.count - 1)
            guard maxLength > 0 else { return 0 }
            for length in stride(from: maxLength, through: 1, by: -1) where tag.hasPrefix(text.suffix(length)) {
                return length
            }
            return 0
        }
    }

    // MARK: - Зацикливание

    /// Ловит «заело пластинку»: модель начинает повторять один и тот же
    /// фрагмент до упора в лимит токенов. Проверяются периоды от 8 до 48
    /// символов — короткий период ловит повтор строки списка, длинный —
    /// повтор целого предложения.
    struct LoopDetector {
        static let minPeriod = 8
        static let maxPeriod = 48
        static let repeats = 4

        private var tail: [Character] = []

        init() {}

        /// Возвращает true, если хвост выглядит зациклившимся.
        mutating func feed(_ chunk: String) -> Bool {
            guard !chunk.isEmpty else { return false }
            tail.append(contentsOf: chunk)
            let limit = Self.maxPeriod * Self.repeats
            if tail.count > limit { tail.removeFirst(tail.count - limit) }
            for period in stride(from: Self.minPeriod, through: Self.maxPeriod, by: 1)
            where tail.count >= period * Self.repeats {
                if Self.isRepeating(tail.suffix(period * Self.repeats), period: period) { return true }
            }
            return false
        }

        private static func isRepeating(_ block: ArraySlice<Character>, period: Int) -> Bool {
            let chars = Array(block)
            guard chars.count == period * repeats else { return false }
            let head = chars.prefix(period)
            // Таблица Markdown повторяется ПО СВОЕЙ ПРИРОДЕ: разделитель
            // «|-----|-----|-----|-----|» и строка «| Не указано | … » из
            // четырёх колонок — это ровно четыре повтора периода. Встроенный
            // «Протокол встречи» просит таблицу именно из четырёх колонок, а
            // системный промпт велит писать «Не указано» в пустых ячейках,
            // так что без этого правила детектор рубил бы отчёт посреди
            // таблицы и ещё помечал его «оборван по длине».
            guard !head.contains("|") else { return false }
            // Повтор одних пробелов, дефисов и точек — оформление, не заедание.
            guard head.contains(where: { $0.isLetter || $0.isNumber }) else { return false }
            for index in period..<chars.count where chars[index] != chars[index - period] {
                return false
            }
            return true
        }
    }

    // MARK: - Чистка готового ответа

    /// Снимает блок размышлений (в том числе незакрытый), обёртку
    /// ```` ```markdown ```` и лишние пробелы по краям. Модели регулярно
    /// заворачивают весь ответ в один блок кода — показывать его как код
    /// значит потерять заголовки и таблицы.
    static func clean(_ text: String) -> String {
        var result = stripThink(text)
        result = stripCodeFence(result)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// То же правило, что у потокового `ThinkFilter`: закрытый блок
    /// вырезается где угодно, а незакрытый считается размышлением, только
    /// если до него ещё не было видимого текста. Иначе это процитированный
    /// тег, и выбрасывать из-за него хвост отчёта нельзя.
    static func stripThink(_ text: String) -> String {
        var result = ""
        var rest = Substring(text)
        while let open = rest.range(of: "<think>") {
            let before = rest[rest.startIndex..<open.lowerBound]
            guard let close = rest.range(of: "</think>", range: open.upperBound..<rest.endIndex) else {
                let hasVisibleText = (result + before).contains { !$0.isWhitespace }
                return hasVisibleText ? result + rest : result + before
            }
            result += before
            rest = rest[close.upperBound...]
        }
        return result + rest
    }

    /// Обёртка всего ответа в ``` … ``` — только если она охватывает ВЕСЬ
    /// текст: блок кода внутри отчёта трогать нельзя. Снимается САМ забор,
    /// а не строки вокруг него: модель регулярно закрывает забор на одной
    /// строке с последним пунктом, и удаление последней строки съедало бы
    /// содержимое (а у однострочного ответа — весь ответ целиком).
    static func stripCodeFence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```"), trimmed.hasSuffix("```"), trimmed.count > 6,
              let firstNewline = trimmed.firstIndex(where: \.isNewline) else { return text }
        // Открывающая строка — только ``` и необязательное имя языка.
        let language = trimmed[trimmed.index(trimmed.startIndex, offsetBy: 3)..<firstNewline]
            .trimmingCharacters(in: .whitespaces)
        guard !language.contains("`") else { return text }
        let inner = trimmed[trimmed.index(after: firstNewline)...].dropLast(3)
        // Забор внутри — значит это несколько блоков кода, а не одна обёртка:
        // снятие внешнего склеило бы их в один.
        guard !inner.contains("```") else { return text }
        return String(inner).trimmingCharacters(in: .newlines)
    }

    // MARK: - CJK

    /// Есть ли в строке иероглифы, кана или хангыль. Нужно для бана токенов:
    /// Qwen на длинном русском контексте склонен сваливаться в китайский.
    static func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains(where: isCJK)
    }

    static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x1100...0x11FF,      // хангыль-чамо
             0x3000...0x303F,      // китайско-японская пунктуация
             0x3040...0x30FF,      // хирагана и катакана
             0x3130...0x318F,      // совместимость хангыля
             0x3400...0x4DBF,      // иероглифы, расширение A
             0x4E00...0x9FFF,      // основные иероглифы
             0xA960...0xA97F,      // хангыль, расширение A
             0xAC00...0xD7AF,      // слоги хангыля
             0xF900...0xFAFF,      // совместимость иероглифов
             0xFF00...0xFF60,      // полноширинные формы
             0x20000...0x2FA1F:    // иероглифы, расширения B…F
            return true
        default:
            return false
        }
    }
}
