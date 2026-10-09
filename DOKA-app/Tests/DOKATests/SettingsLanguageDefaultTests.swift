import XCTest
@testable import DOKA

/// Язык распознавания по умолчанию — «Авто», но только для новых установок.
///
/// Зачем: с явным языком Whisper пишет только на нём и английскую речь при
/// `ru` вставлял русским переводом. Прежнее «Русский» было лишь
/// зарегистрированным умолчанием — у тех, кто язык не выбирал, ключа нет, и без
/// закрепления смена умолчания молча переключила бы их на «Авто». Имена ключей
/// здесь буквальные: они лежат в UserDefaults пользователей и не должны меняться.
final class SettingsLanguageDefaultTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "doka-language-tests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    /// Новая установка: ничего не пишется — работает зарегистрированное «Авто».
    func testFreshInstallKeepsAutoDefault() {
        SettingsStore.pinLegacyLanguage(in: defaults)
        XCTAssertNil(defaults.object(forKey: "language"))
    }

    /// Прошлый запуск без выбранного языка — остаётся «Русский», как было.
    func testExistingInstallWithoutChoiceStaysRussian() {
        defaults.set(true, forKey: "servicesMigrated")
        SettingsStore.pinLegacyLanguage(in: defaults)
        XCTAssertEqual(defaults.string(forKey: "language"), "ru")
    }

    func testCompletedOnboardingCountsAsExistingInstall() {
        defaults.set(true, forKey: "onboardingCompleted")
        SettingsStore.pinLegacyLanguage(in: defaults)
        XCTAssertEqual(defaults.string(forKey: "language"), "ru")
    }

    /// Выбранный язык не трогается, повторный вызов ничего не меняет.
    func testExplicitChoiceIsKept() {
        defaults.set(true, forKey: "servicesMigrated")
        for choice in ["auto", "en"] {
            defaults.set(choice, forKey: "language")
            SettingsStore.pinLegacyLanguage(in: defaults)
            SettingsStore.pinLegacyLanguage(in: defaults)
            XCTAssertEqual(defaults.string(forKey: "language"), choice)
        }
    }
}
