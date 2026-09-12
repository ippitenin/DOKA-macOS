import Foundation

/// Нарезка расшифровки на части под окно контекста и упаковка конспектов
/// частей для сведения. Чистая арифметика по числу токенов — тестируется
/// без модели.
///
/// Строки не режутся: строка — это реплика, и разорванная посередине реплика
/// теряет и говорящего, и смысл. Длину строки ограничивает сам вход
/// (`TranscriptLLMInput.defaultMaxTurn`).
enum LLMChunker {
    /// Больше этого числа частей не берёмся: каждая часть — отдельный проход
    /// модели, и сорок частей это уже десятки минут работы.
    static let maxParts = 40

    /// Из чего складывается доступный под вход бюджет токенов.
    struct Budget: Equatable {
        /// Окно контекста модели.
        let context: Int
        /// Промпт без расшифровки: системное сообщение, шапка, разделы.
        let promptOverhead: Int
        /// Сколько оставляем модели на ответ.
        let outputReserve: Int
        /// Запас на неточность оценки (шаблон чата, склейки, знаки).
        let safety: Int

        init(context: Int, promptOverhead: Int, outputReserve: Int, safety: Int = 256) {
            self.context = context
            self.promptOverhead = promptOverhead
            self.outputReserve = outputReserve
            self.safety = safety
        }

        /// Сколько токенов входа влезает; 0 — не влезает ничего.
        var input: Int { max(0, context - promptOverhead - outputReserve - safety) }
    }

    /// Сколько токенов оставляем на ответ: у финального отчёта он длинный,
    /// у конспекта части — короче.
    static let finalOutputReserve = 1536
    static let mapOutputReserve = 640

    /// Диапазоны строк по частям. Соседние части перекрываются хвостом
    /// примерно в `overlapTokens`: без перекрытия мысль, начатая в конце
    /// одной части, теряет продолжение.
    /// Пустой вход или нулевой бюджет — пустой план.
    static func plan(lineTokens: [Int], budget: Int, overlapTokens: Int = 200) -> [Range<Int>] {
        guard !lineTokens.isEmpty, budget > 0 else { return [] }
        // Всё влезает — одна часть, без перекрытий.
        if lineTokens.reduce(0, +) <= budget { return [0..<lineTokens.count] }

        var parts: [Range<Int>] = []
        var start = 0
        while start < lineTokens.count {
            var end = start
            var used = 0
            while end < lineTokens.count {
                let next = lineTokens[end]
                // Строка длиннее всего бюджета идёт одна: резать её нельзя,
                // а пропустить — значит потерять кусок расшифровки.
                if used + next > budget, end > start { break }
                used += next
                end += 1
                if used >= budget { break }
            }
            parts.append(start..<end)
            guard end < lineTokens.count else { break }
            // Отступ назад на перекрытие, но не дальше, чем на половину
            // части: иначе части начали бы повторяться и план не сходился бы.
            var back = 0
            var overlap = 0
            let maxBack = max(0, (end - start) / 2)
            while back < maxBack, overlap + lineTokens[end - 1 - back] <= overlapTokens {
                overlap += lineTokens[end - 1 - back]
                back += 1
            }
            start = max(start + 1, end - back)
            if parts.count >= maxParts { break }
        }
        return parts
    }

    /// Группы конспектов для сведения: сколько конспектов влезает в один
    /// запрос. nil — не влезает даже один, сводить нечем.
    static func reduceGroups(noteTokens: [Int], budget: Int) -> [Range<Int>]? {
        guard !noteTokens.isEmpty, budget > 0 else { return nil }
        guard noteTokens.allSatisfy({ $0 <= budget }) else { return nil }
        var groups: [Range<Int>] = []
        var start = 0
        var used = 0
        for index in noteTokens.indices {
            if used + noteTokens[index] > budget, index > start {
                groups.append(start..<index)
                start = index
                used = 0
            }
            used += noteTokens[index]
        }
        groups.append(start..<noteTokens.count)
        return groups
    }
}
