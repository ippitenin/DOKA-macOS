import Foundation

/// Пробел между двумя диктовками подряд. Вставка кладёт текст в позицию
/// курсора как есть, поэтому две диктовки одна за другой склеиваются:
/// «…не куритьПотому что…». Если прошлая вставка была недавно, в то же
/// приложение и кончилась словом — перед новой нужен один пробел.
///
/// Правила — по образцу Type 3.0. Ошибка в обе стороны неприятна (склейка
/// или лишний пробел в начале поля), поэтому пробел ставится только когда
/// картина однозначна: окно времени, то же приложение, и между вставками
/// пользователь ничего не печатал и не кликал (это отслеживает `Paster`,
/// сбрасывая прошлую вставку).
enum PasteSpacing {
    /// Прошлая вставка DOKA.
    struct Previous: Equatable {
        let text: String
        let date: Date
        /// Приложение, куда вставляли. `nil` — неизвестно, и тогда пробела нет.
        let targetPID: pid_t?
    }

    /// Дольше этого прошлая вставка не в счёт: человек мог уйти в другое поле.
    static let window: TimeInterval = 180

    /// Префикс к новому тексту: `" "` или пустая строка.
    static func prefix(previous: Previous?, next: String, targetPID: pid_t?, now: Date) -> String {
        guard let previous, let last = previous.text.last, let first = next.first else { return "" }
        guard let targetPID, previous.targetPID == targetPID else { return "" }
        let age = now.timeIntervalSince(previous.date)
        guard age >= 0, age <= window else { return "" }
        guard !endsWithoutSpace(last), startsLikeWord(first) else { return "" }
        return " "
    }

    /// Окончания, после которых пробел не нужен: пробел или перевод строки,
    /// открывающие скобки и кавычки, дефис («кто-» + «то»), слеш. Тире и
    /// прямые кавычки сюда НЕ входят: в конце куска прямая кавычка обычно
    /// закрывающая, а тире в русском тексте отбивается пробелами с обеих сторон.
    private static func endsWithoutSpace(_ character: Character) -> Bool {
        if character.isWhitespace || character.isNewline { return true }
        return "([{«‹“‘-/".contains(character)
    }

    /// Белый список начал: буква, цифра, открывающая скобка или кавычка.
    /// Чёрный список вставил бы пробел перед «/команда», «@имя» или «#тег»
    /// и поменял бы их смысл; запятая и точка в начале — продолжение фразы.
    private static func startsLikeWord(_ character: Character) -> Bool {
        if character.isLetter || character.isNumber { return true }
        return "([{«‹“‘".contains(character)
    }
}
