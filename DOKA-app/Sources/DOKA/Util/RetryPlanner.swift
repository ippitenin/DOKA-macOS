import Foundation

/// Что сделает «Повторить» у записи библиотеки, завершившейся ошибкой или
/// отменённой. Повтор идёт НА МЕСТЕ (та же запись) и по сохранённым
/// параметрам — глобальный выбор сервиса не переключается.
enum RetryPlan: Equatable {
    /// Забрать результат async-задачи Nexara с сервера — без нового POST и
    /// без повторной оплаты: отмена у Nexara лишь прекращала опрос, сервер
    /// задачу дообработал.
    case repoll(jobID: String)
    /// Сервиса записи больше нет (пресет удалён) — повторить можно только
    /// «Распознать заново» другим сервисом.
    case serviceUnavailable
    /// Исходный файл на месте и читается.
    case rerunOriginal(billed: Bool)
    /// Исходника нет (перенесён, удалён, TCC не пускает в «Рабочий стол») —
    /// распознаём сохранённый архив звука записи.
    case rerunStoredAudio(billed: Bool)
    /// Ни исходника, ни архива: пользователь выбирает файл сам.
    case needsFile
}

/// Выбор плана «Повторить» — чистая функция: всё, что требует диска или
/// Keychain (читается ли исходник, есть ли архив, жив ли пресет), приходит
/// аргументами. Правила — строго по порядку, первое подошедшее побеждает.
enum RetryPlanner {
    /// Факты о записи, которые планировщик сам не добывает.
    struct Context: Equatable {
        /// Сервис повтора: `params.providerID` записи, у записей до библиотеки
        /// (без `params`) — текущий сервис страницы.
        var providerID: String
        /// Сервис существует (пресет не удалён; встроенный и локальные — всегда).
        var serviceExists: Bool
        /// Исходный файл по `sourcePath` читается.
        var originalReadable: Bool
        /// Архив звука записи лежит на диске.
        var hasStoredAudio: Bool
        var now: Date
    }

    /// nil — повторять нечего: запись готова или ещё выполняется.
    static func plan(for record: FileTranscriptRecord, context: Context) -> RetryPlan? {
        switch record.status {
        case .inProgress, .done: return nil
        case .error, .cancelled: break
        }
        // 1. Результат ещё на сервере — забираем бесплатно.
        if canRepoll(record, now: context.now), let jobID = record.jobID {
            return .repoll(jobID: jobID)
        }
        // 2. Повторять нечем: сервис записи удалён.
        guard context.serviceExists else { return .serviceUnavailable }
        let billed = isBilled(providerID: context.providerID)
        // 3–5. Оригинал раньше архива: архив — сжатая копия (AAC 24 кбит/с).
        if context.originalReadable { return .rerunOriginal(billed: billed) }
        if context.hasStoredAudio { return .rerunStoredAudio(billed: billed) }
        return .needsFile
    }

    /// Можно ли забрать результат с сервера без повторной отправки файла:
    /// есть job_id Nexara, результат ещё хранится (12 ч от постановки), и
    /// прошлая неудача была преходящей (сеть, ключ, баланс) или её не было
    /// вовсе (отмена, старые версии). Всё остальное повторный опрос вернул бы
    /// точно так же: 404 (`jobNotFound`), `status=error` (`jobFailed`),
    /// пустой или неразборчивый ответ (`other`) — такие записи
    /// переотправляются. У отменённой запись опрос пробуется: 404 превратится
    /// в `jobNotFound`, и следующий «Повторить» пойдёт переотправкой — без
    /// зацикливания.
    static func canRepoll(_ record: FileTranscriptRecord, now: Date) -> Bool {
        switch record.status {
        case .error, .cancelled: break
        case .inProgress, .done: return false
        }
        guard record.jobID != nil else { return false }
        switch record.failure {
        case nil, .network?, .auth?, .noFunds?: break
        default: return false
        }
        return now < repollDeadline(for: record)
    }

    /// Дедлайн опроса: от постановки задачи (у старых записей — от создания).
    static func repollDeadline(for record: FileTranscriptRecord) -> Date {
        (record.submittedAt ?? record.date).addingTimeInterval(TranscriptHistoryStore.serverResultLifetime)
    }

    /// Тарифицирует ли сервис повторное распознавание: любой сетевой —
    /// встроенный и пользовательские пресеты; локальные модели бесплатны.
    static func isBilled(providerID: String) -> Bool {
        LocalModel.from(providerID: providerID) == nil
    }
}
