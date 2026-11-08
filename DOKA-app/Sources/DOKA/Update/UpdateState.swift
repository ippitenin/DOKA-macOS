import Foundation

/// Найденная новая версия: то, что видит пользователь.
struct UpdateInfo: Equatable {
    /// Номер для людей (`CFBundleShortVersionString` новой версии, «1.0.4»).
    let version: String
    /// Заметки релиза из ленты (Markdown); nil — заметок нет.
    let notes: String?
    /// Только информационное обновление (ставить нечего, ведём на страницу):
    /// так выключают сломанный релиз, подменив его элемент ленты.
    let infoURL: URL?
}

/// Состояние обновлятора для интерфейса (плашка, «О DOKA», меню-бар).
/// Чистое значение: переходы делает `UpdateController`, отображение — `UpdateBannerModel`.
enum UpdateState: Equatable {
    /// Ничего не известно: проверки ещё не было или она прошла фоном без находки.
    case idle
    /// Идёт ручная проверка («Проверить обновления»).
    case checking
    /// Ручная проверка ничего не нашла.
    case upToDate(Date)
    /// Новая версия найдена и готова к установке по кнопке.
    case ready(UpdateInfo)
    /// Нажали «Обновить», но DOKA занята (диктовка, файл, анализ) — ждём покоя.
    case waitingForIdle(UpdateInfo)
    /// Скачивание после нажатия (фоновое скачивание было выключено).
    /// `fraction` nil — размер ещё неизвестен.
    case downloading(UpdateInfo, fraction: Double?)
    /// Установка и перезапуск.
    case installing(UpdateInfo)
    /// Ошибка, о которой стоит сказать: только после действия пользователя.
    case failed(String)
    /// Первый запуск после установки через «Обновить»: плашка «DOKA обновлена»
    /// с «Что нового» (см. `UpdateHandoff`).
    case updated(UpdateInfo)

    /// Версия, о которой идёт речь (для плашки и меню-бара).
    var info: UpdateInfo? {
        switch self {
        case .ready(let info), .waitingForIdle(let info), .installing(let info), .updated(let info):
            return info
        case .downloading(let info, _):
            return info
        case .idle, .checking, .upToDate, .failed:
            return nil
        }
    }
}

/// Сколько ещё держать «Проверяю…» на экране. Локальная или быстрая сеть
/// отвечает за миллисекунды, и карточка «О DOKA» мигала бы — по HIG
/// пользователь, нажавший «Проверить», ждёт короткую, но заметную проверку.
enum UpdateTiming {
    static let minimumCheck: TimeInterval = 1.2

    static func remainingDelay(started: Date, now: Date = Date(),
                               minimum: TimeInterval = minimumCheck) -> TimeInterval {
        max(0, minimum - now.timeIntervalSince(started))
    }
}

/// Передача «что ставили» через перезапуск: перед установкой версия и
/// заметки пишутся в UserDefaults, а новая DOKA на старте показывает
/// «DOKA обновлена · Что нового». Запись одноразовая.
enum UpdateHandoff {
    static let key = "DOKAUpdateHandoff"

    struct Saved: Codable, Equatable {
        let version: String
        let notes: String?
    }

    /// Что показать на этом запуске: nil — ничего (записи нет или установка
    /// не дошла — версия бандла не та). Запись после вызова удаляют в любом случае.
    static func resolve(saved: Saved?, currentVersion: String) -> UpdateInfo? {
        guard let saved, saved.version == currentVersion else { return nil }
        return UpdateInfo(version: saved.version, notes: saved.notes, infoURL: nil)
    }
}

/// Что показывает плашка внизу сайдбара. Чистая функция состояния —
/// покрыта `UpdateStateTests`.
struct UpdateBannerModel: Equatable {
    enum Action: Equatable {
        /// Кнопка «Обновить».
        case install
        /// Идёт работа: полоса вместо кнопки, нажимать нечего.
        case progress
        /// Без кнопки: только сообщение («DOKA обновлена»).
        case none
    }

    let version: String
    /// Ключ строки статуса под заголовком; nil — только заголовок.
    let statusKey: String?
    let action: Action
    /// Можно ли скрыть плашку крестиком (пока идёт установка — нельзя).
    let dismissible: Bool

    /// nil — плашки нет. `dismissedVersion` — версия, скрытая крестиком
    /// в этом запуске: её плашка не возвращается, пока не выйдет следующая.
    static func make(state: UpdateState, dismissedVersion: String?) -> UpdateBannerModel? {
        switch state {
        case .ready(let info):
            guard info.version != dismissedVersion else { return nil }
            return UpdateBannerModel(version: info.version, statusKey: nil,
                                     action: .install, dismissible: true)
        case .waitingForIdle(let info):
            // Нажатие уже было — плашку не прячем, даже если её скрывали раньше.
            return UpdateBannerModel(version: info.version, statusKey: "update.banner.waiting",
                                     action: .progress, dismissible: false)
        case .downloading(let info, _):
            return UpdateBannerModel(version: info.version, statusKey: "update.banner.downloading",
                                     action: .progress, dismissible: false)
        case .installing(let info):
            return UpdateBannerModel(version: info.version, statusKey: "update.banner.installing",
                                     action: .progress, dismissible: false)
        case .updated(let info):
            guard info.version != dismissedVersion else { return nil }
            return UpdateBannerModel(version: info.version, statusKey: nil,
                                     action: .none, dismissible: true)
        case .idle, .checking, .upToDate, .failed:
            return nil
        }
    }
}
