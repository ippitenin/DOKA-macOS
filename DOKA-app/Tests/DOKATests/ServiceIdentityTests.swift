import XCTest
@testable import DOKA

/// Идентификаторы сервисов: аккаунты Keychain, адреса, имена пресетов.
///
/// Зачем: у встроенного сервиса аккаунт Keychain называется `nexara-api-key`
/// — историческое имя, оставшееся от прежнего названия. Любая «причёсывающая»
/// правка вроде `api-key-builtin` молча потеряет ключи ВСЕХ существующих
/// пользователей: приложение не упадёт, просто перестанет распознавать и
/// отправит человека вводить ключ заново. Тест ловит это одной строкой.
final class ServiceIdentityTests: XCTestCase {

    // MARK: - Keychain

    /// Контракт, а не оформление: имя аккаунта — ключ к данным пользователя.
    func testBuiltinKeychainAccountKeepsItsHistoricalName() {
        XCTAssertEqual(TranscriptionProvider.builtin.keychainAccount, "nexara-api-key")
    }

    func testOtherProvidersUseRawValueAccounts() {
        XCTAssertEqual(TranscriptionProvider.openai.keychainAccount, "api-key-openai")
        XCTAssertEqual(TranscriptionProvider.groq.keychainAccount, "api-key-groq")
        XCTAssertEqual(TranscriptionProvider.custom.keychainAccount, "api-key-custom")
    }

    /// У каждого сервиса свой ключ — иначе смена сервиса подменяла бы ключ.
    func testKeychainAccountsAreDistinct() {
        let accounts = TranscriptionProvider.allCases.map(\.keychainAccount)
        XCTAssertEqual(Set(accounts).count, accounts.count, "аккаунты дублируются: \(accounts)")
    }

    /// Аккаунт пресета выводится из его id и обязан отличаться от всех
    /// встроенных: пресет с чужим аккаунтом читал бы чужой ключ.
    func testCustomServiceAccountsAreDerivedFromID() {
        let id = UUID()
        let service = CustomService(id: id, name: "n", endpoint: "https://e/v1", model: "m")
        XCTAssertEqual(service.keychainAccount, "custom-\(id.uuidString)")
        XCTAssertFalse(TranscriptionProvider.allCases.map(\.keychainAccount)
            .contains(service.keychainAccount))
    }

    func testTwoPresetsNeverShareAnAccount() {
        let a = CustomService(id: UUID(), name: "a", endpoint: "https://a/v1", model: "")
        let b = CustomService(id: UUID(), name: "b", endpoint: "https://b/v1", model: "")
        XCTAssertNotEqual(a.keychainAccount, b.keychainAccount)
    }

    // MARK: - rawValue как ключ хранения

    /// rawValue уезжает в UserDefaults (`providerID`) и в метаданные записей
    /// истории. Переименование кейса ломает и то, и другое.
    func testRawValuesAreStable() {
        XCTAssertEqual(TranscriptionProvider.builtin.rawValue, "builtin")
        XCTAssertEqual(TranscriptionProvider.openai.rawValue, "openai")
        XCTAssertEqual(TranscriptionProvider.groq.rawValue, "groq")
        XCTAssertEqual(TranscriptionProvider.custom.rawValue, "custom")
    }

    /// `.openai` и `.groq` убраны из пикера, но НЕ мертвы: история и анализ
    /// производительности разбирают ими старое поле `provider` записей
    /// (`TranscriptionProvider(rawValue:)?.title ?? raw`). Удалить кейсы —
    /// значит показать людям сырые строки вместо названий сервисов.
    func testLegacyProvidersStillResolveForOldHistoryRecords() {
        XCTAssertEqual(TranscriptionProvider(rawValue: "openai")?.title, "OpenAI")
        XCTAssertEqual(TranscriptionProvider(rawValue: "groq")?.title, "Groq")
    }

    // MARK: - Адреса и модели

    func testBuiltinPointsAtNexara() {
        XCTAssertEqual(TranscriptionProvider.builtin.endpoint?.absoluteString,
                       "https://api.nexara.ru/api/v1/audio/transcriptions")
    }

    /// У «своего сервиса» адрес задаёт пользователь — жёсткого эндпоинта нет.
    func testCustomHasNoBuiltInEndpoint() {
        XCTAssertNil(TranscriptionProvider.custom.endpoint)
    }

    /// Все встроенные адреса — https и уже полный путь эндпоинта:
    /// нормализация их не меняет.
    func testBuiltInEndpointsAreCompleteHTTPS() {
        for provider in TranscriptionProvider.allCases {
            guard let url = provider.endpoint else { continue }
            XCTAssertEqual(url.scheme, "https", "\(provider.rawValue)")
            XCTAssertTrue(url.path.hasSuffix("/audio/transcriptions"), "\(provider.rawValue)")
            XCTAssertEqual(ProviderConfig.normalizeEndpoint(url.absoluteString), url,
                           "нормализация не должна менять готовый адрес \(provider.rawValue)")
        }
    }

    func testDefaultModels() {
        XCTAssertEqual(TranscriptionProvider.builtin.defaultModel, "whisper-1")
        XCTAssertEqual(TranscriptionProvider.openai.defaultModel, "whisper-1")
        XCTAssertEqual(TranscriptionProvider.custom.defaultModel, "whisper-1")
        XCTAssertEqual(TranscriptionProvider.groq.defaultModel, "whisper-large-v3")
    }

    // MARK: - Имя пресета

    func testPresetNameCombinesHostAndModel() {
        XCTAssertEqual(CustomService.makeName(endpoint: "https://api.example.com/v1", model: "whisper-1"),
                       "api.example.com · whisper-1")
    }

    /// Пустая модель означает «по умолчанию» — в имени её не показываем.
    func testPresetNameOmitsEmptyModel() {
        XCTAssertEqual(CustomService.makeName(endpoint: "https://api.example.com/v1", model: "   "),
                       "api.example.com")
    }

    /// Неразбираемый адрес показывается как есть — лучше странное имя, чем
    /// пустое или крэш на этапе сохранения пресета.
    func testPresetNameFallsBackToRawEndpoint() {
        XCTAssertEqual(CustomService.makeName(endpoint: "не адрес", model: ""), "не адрес")
    }

    // MARK: - Разбор providerID

    /// Три формата `providerID` не должны пересекаться: «builtin»,
    /// «custom:<uuid>» и «local:<model>». Пересечение означало бы запрос
    /// не туда — и, для платных сервисов, чужие деньги.
    func testProviderIDNamespacesDoNotOverlap() {
        XCTAssertNil(LocalModel.from(providerID: TranscriptionProvider.builtin.rawValue))
        XCTAssertNil(LocalModel.from(providerID: "custom:\(UUID().uuidString)"))
        for model in LocalModel.allCases {
            XCTAssertFalse(model.providerID.hasPrefix("custom:"))
            XCTAssertNotEqual(model.providerID, TranscriptionProvider.builtin.rawValue)
        }
    }
}
