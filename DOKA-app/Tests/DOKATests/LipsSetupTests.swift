import XCTest
@testable import DOKA

/// Каркас эксперимента «Губы»: где лежат данные и как раздел попадает в сайдбар.
///
/// Зачем: `LipData` читает внешний инструмент обучения (WISLIP) по
/// ФИКСИРОВАННОМУ пути — перенос «Папки данных» не должен ни увезти пары,
/// ни стереть их, ни споткнуться о них при возврате на путь по умолчанию.
/// Раздел «Губы» виден только при включённом эксперименте, и его появление
/// не должно переставить остальные пункты.
final class LipsSetupTests: XCTestCase {

    // MARK: - Фиксированная папка

    /// Пары лежат рядом с моделями, в Application Support, а не в
    /// переносимой «Папке данных».
    func testLipDataLivesNextToModelsInDefaultFolder() {
        XCTAssertEqual(AppDataFolder.lipDataURL.lastPathComponent, "LipData")
        XCTAssertEqual(AppDataFolder.lipDataURL.deletingLastPathComponent().path,
                       AppDataFolder.defaultURL.path)
    }

    func testFixedFoldersAreModelsAndLipData() {
        XCTAssertEqual(AppDataFolder.fixedFolderNames, ["Models", "LipData"])
    }

    /// Возврат на путь по умолчанию: в цели могут лежать только фиксированные
    /// папки и мусор Finder — это не «непустая цель».
    func testFixedFoldersDoNotBlockMigration() {
        XCTAssertFalse(AppDataFolder.blocksMigration(targetContents: []))
        XCTAssertFalse(AppDataFolder.blocksMigration(targetContents: ["Models", "LipData", ".DS_Store"]))
        XCTAssertTrue(AppDataFolder.blocksMigration(targetContents: ["LipData", "history.json"]))
    }

    // MARK: - Сайдбар

    /// Эксперимент выключен — сайдбар ровно прежний.
    func testSidebarWithoutLipsIsUnchanged() {
        let groups = MainSection.sidebarGroups(lipsEnabled: false)
        XCTAssertEqual(groups.map(\.titleKey), [nil, "sidebar.group.dictation", "sidebar.group.settings"])
        XCTAssertEqual(groups.map(\.sections), [
            [.home, .dashboard],
            [.transcribe, .library, .history, .dictionary],
            [.general, .sound, .hotkeys, .service]
        ])
    }

    /// Окно и SwiftUI берут минимальную высоту из одного места: 12-й пункт
    /// сайдбара на прежних 560 обрезался бы.
    func testMainWindowMinHeight() {
        XCTAssertEqual(MainWindowLayout.minHeight(lipsEnabled: false), 560)
        XCTAssertEqual(MainWindowLayout.minHeight(lipsEnabled: true), 608)
    }

    /// Включён — «Губы» встают в конец группы «Диктовка», остальное на месте.
    func testSidebarWithLipsAppendsSectionToDictationGroup() {
        let groups = MainSection.sidebarGroups(lipsEnabled: true)
        XCTAssertEqual(groups.map(\.sections), [
            [.home, .dashboard],
            [.transcribe, .library, .history, .dictionary, .lips],
            [.general, .sound, .hotkeys, .service]
        ])
    }
}
