import Foundation

// Маршрут запроса распознавания. Жил в середине SettingsStore между сроками
// хранения и @Published-свойствами, хотя это центральный тип ветвления всего
// приложения: им пользуются и диктовка (DictationController), и файловая
// транскрибация (FileTranscriptionController). Рядом с сетевым слоем ему
// уместнее — там же лежат TranscriptionProvider и ProviderConfig.

/// Исполняемый маршрут активного сервиса распознавания — единственная форма
/// ветвления «локальный/сетевой» в контроллерах (`SettingsStore.resolveRoute`).
/// Своих редакций этого выбора (сентинелы, пары опционалов) не заводить.
enum ServiceRoute {
    case local(LocalModel)
    case remote(apiKey: String, config: ProviderConfig)

    /// Имя модели для метаданных истории.
    var modelTag: String {
        switch self {
        case .local(let model): return model.modelName
        case .remote(_, let config): return config.model
        }
    }
}

// MARK: - Фасад активного сервиса

/// Весь ответ на вопрос «куда уйдёт запрос и на чьи деньги» — на одном экране.
/// Раньше эти пятнадцать членов были размазаны по SettingsStore между
/// @Published-свойствами, хотя именно они решают, пойдёт ли распознавание на
/// платный сервис, на пресет пользователя или на локальную модель.
///
/// Стор при этом не изменился: `providerID`, `customServices` и приватные
/// `defaults`/`Key` остались на месте — расширение живёт в том же модуле и
/// видимость никому расширять не пришлось.
extension SettingsStore {
    /// Выбранный пользовательский сервис; nil — встроенный (или пресет удалён,
    /// тогда всё мягко откатывается к встроенному).
    var selectedCustomService: CustomService? {
        customService(for: providerID)
    }

    /// Пресет по id сервиса («custom:<uuid>»); nil — не пресет или он удалён.
    func customService(for providerID: String) -> CustomService? {
        guard providerID.hasPrefix("custom:"),
              let id = UUID(uuidString: String(providerID.dropFirst("custom:".count))) else {
            return nil
        }
        return customServices.first { $0.id == id }
    }

    /// Выбранная локальная модель; nil — сетевой сервис.
    var selectedLocalModel: LocalModel? {
        LocalModel.from(providerID: providerID)
    }

    /// Активен ли локальный сервис (on-device, без сети и без ключа).
    var isLocalService: Bool { selectedLocalModel != nil }

    /// Готов ли активный сервис к работе: локальный — модель скачана,
    /// сетевой — разбирается конфиг и сохранён ключ. Единая замена всех
    /// guard'ов «есть ключ» — другие редакции этой проверки не заводить.
    var isServiceReady: Bool {
        if let local = selectedLocalModel {
            return LocalModelStore.shared.isDownloaded(local)
        }
        // Конфиг — до ключа: не трогаем Keychain, когда сервис всё равно не готов.
        return providerConfig != nil && currentAPIKey != nil
    }

    /// Исполняемый маршрут активного сервиса: локальный движок или сетевой
    /// клиент с ключом и конфигом. Бросает `ClientError`, если сетевой сервис
    /// не готов. Читает Keychain — не вызывать синхронно в пути запуска
    /// (диалог подтверждения доступа заморозит приложение, см. CLAUDE.md).
    func resolveRoute() throws -> ServiceRoute {
        try resolveRoute(providerID: providerID)
    }

    /// Маршрут произвольного сервиса — повтор файловой транскрибации по
    /// сохранённым параметрам записи, не переключая выбор пользователя.
    /// Удалённый пресет — ошибка «не настроен», а не молчаливый уход на
    /// встроенный (платный) сервис. Читает Keychain — только по действию
    /// пользователя, не из тела вью и не в пути запуска.
    func resolveRoute(providerID: String) throws -> ServiceRoute {
        if let local = LocalModel.from(providerID: providerID) { return .local(local) }
        if providerID.hasPrefix("custom:"), customService(for: providerID) == nil {
            throw TranscriptionClient.ClientError.notConfigured
        }
        guard let config = providerConfig(for: providerID) else {
            throw TranscriptionClient.ClientError.notConfigured
        }
        guard let apiKey = KeychainHelper.getAPIKey(account: keychainAccount(for: providerID)) else {
            throw TranscriptionClient.ClientError.noAPIKey
        }
        return .remote(apiKey: apiKey, config: config)
    }

    /// Активная конфигурация запросов. nil — у пресета не разбирается адрес
    /// либо выбран локальный сервис (у него нет ни эндпоинта, ни модели API).
    var providerConfig: ProviderConfig? {
        providerConfig(for: providerID)
    }

    func providerConfig(for providerID: String) -> ProviderConfig? {
        guard LocalModel.from(providerID: providerID) == nil else { return nil }
        if let service = customService(for: providerID) {
            guard let url = ProviderConfig.normalizeEndpoint(service.endpoint) else { return nil }
            let model = service.model.trimmingCharacters(in: .whitespacesAndNewlines)
            return ProviderConfig(endpoint: url,
                                  model: model.isEmpty ? TranscriptionProvider.custom.defaultModel : model)
        }
        guard let url = TranscriptionProvider.builtin.endpoint else { return nil }
        return ProviderConfig(endpoint: url, model: TranscriptionProvider.builtin.defaultModel)
    }

    /// Keychain-аккаунт ключа активного сервиса.
    var currentKeychainAccount: String {
        keychainAccount(for: providerID)
    }

    func keychainAccount(for providerID: String) -> String {
        customService(for: providerID)?.keychainAccount ?? TranscriptionProvider.builtin.keychainAccount
    }

    /// Метка сервиса для записей (история, библиотека) по id сервиса.
    func providerTag(for providerID: String) -> String {
        if let local = LocalModel.from(providerID: providerID) { return local.title }
        return customService(for: providerID)?.name ?? TranscriptionProvider.builtin.rawValue
    }

    /// API-ключ активного сервиса. У локального сервиса ключа нет — Keychain
    /// намеренно не трогаем (синхронное чтение в пути запуска может заморозить
    /// приложение диалогом подтверждения доступа).
    var currentAPIKey: String? {
        guard selectedLocalModel == nil else { return nil }
        return KeychainHelper.getAPIKey(account: currentKeychainAccount)
    }

    /// Метка сервиса для записей истории: builtin остаётся rawValue
    /// (история маппит его в локализованное название), пресет — своё имя,
    /// локальная модель — её название (показывается как есть).
    var providerTagForHistory: String {
        if let local = selectedLocalModel { return local.title }
        return selectedCustomService?.name ?? TranscriptionProvider.builtin.rawValue
    }

    /// Удаляет пресет вместе с его ключом; если он был выбран — возврат
    /// на встроенный сервис.
    func deleteCustomService(_ id: UUID) {
        if let service = customServices.first(where: { $0.id == id }) {
            KeychainHelper.deleteAPIKey(account: service.keychainAccount)
        }
        customServices.removeAll { $0.id == id }
        if providerID == "custom:\(id.uuidString)" {
            providerID = TranscriptionProvider.builtin.rawValue
        }
    }
}
