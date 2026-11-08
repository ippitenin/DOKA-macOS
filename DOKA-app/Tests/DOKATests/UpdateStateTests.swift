import XCTest
@testable import DOKA

/// Что показывает плашка обновления в сайдбаре в каждом состоянии
/// (`UpdateBannerModel.make`) и какую версию отдаёт состояние (`UpdateState.info`).
final class UpdateStateTests: XCTestCase {
    private let info = UpdateInfo(version: "1.0.4", notes: "- исправления", infoURL: nil)

    func testNoBannerWithoutFoundUpdate() {
        for state: UpdateState in [.idle, .checking, .upToDate(Date()), .failed("сеть")] {
            XCTAssertNil(UpdateBannerModel.make(state: state, dismissedVersion: nil), "\(state)")
            XCTAssertNil(state.info, "\(state)")
        }
    }

    func testReadyShowsInstallButtonAndCanBeHidden() {
        let banner = UpdateBannerModel.make(state: .ready(info), dismissedVersion: nil)
        XCTAssertEqual(banner?.version, "1.0.4")
        XCTAssertEqual(banner?.action, .install)
        XCTAssertNil(banner?.statusKey)
        XCTAssertEqual(banner?.dismissible, true)
    }

    func testDismissedVersionHidesOnlyThatVersion() {
        XCTAssertNil(UpdateBannerModel.make(state: .ready(info), dismissedVersion: "1.0.4"))
        // Вышла следующая версия — плашка возвращается.
        XCTAssertNotNil(UpdateBannerModel.make(state: .ready(info), dismissedVersion: "1.0.3"))
    }

    /// После нажатия «Обновить» плашка видна всегда, даже скрытая раньше,
    /// и спрятать её крестиком нельзя.
    func testInProgressStatesIgnoreDismissal() {
        let cases: [(UpdateState, String)] = [
            (.waitingForIdle(info), "update.banner.waiting"),
            (.downloading(info, fraction: 0.4), "update.banner.downloading"),
            (.installing(info), "update.banner.installing")
        ]
        for (state, key) in cases {
            let banner = UpdateBannerModel.make(state: state, dismissedVersion: "1.0.4")
            XCTAssertEqual(banner?.statusKey, key, "\(state)")
            XCTAssertEqual(banner?.action, .progress, "\(state)")
            XCTAssertEqual(banner?.dismissible, false, "\(state)")
            XCTAssertEqual(state.info, info, "\(state)")
        }
    }

    /// Первый запуск после обновления: сообщение без кнопки, скрывается крестиком.
    func testUpdatedShowsMessageWithoutButton() {
        let banner = UpdateBannerModel.make(state: .updated(info), dismissedVersion: nil)
        XCTAssertEqual(banner?.action, UpdateBannerModel.Action.none)
        XCTAssertEqual(banner?.dismissible, true)
        XCTAssertNil(UpdateBannerModel.make(state: .updated(info), dismissedVersion: "1.0.4"))
        XCTAssertEqual(UpdateState.updated(info).info, info)
    }

    /// «Проверяю…» держится не меньше минимума, долгая проверка не ждёт лишнего.
    func testCheckMinimumDuration() {
        let start = Date(timeIntervalSince1970: 1000)
        XCTAssertEqual(UpdateTiming.remainingDelay(started: start, now: start.addingTimeInterval(0.2),
                                                   minimum: 1.2), 1.0, accuracy: 0.0001)
        XCTAssertEqual(UpdateTiming.remainingDelay(started: start, now: start.addingTimeInterval(3),
                                                   minimum: 1.2), 0)
    }

    /// «DOKA обновлена» — только если установилась именно записанная версия.
    func testHandoffShowsOnlyMatchingVersion() {
        let saved = UpdateHandoff.Saved(version: "1.0.4", notes: "- новое")
        XCTAssertEqual(UpdateHandoff.resolve(saved: saved, currentVersion: "1.0.4"),
                       UpdateInfo(version: "1.0.4", notes: "- новое", infoURL: nil))
        // Установка не дошла — на месте старая версия, сообщать нечего.
        XCTAssertNil(UpdateHandoff.resolve(saved: saved, currentVersion: "1.0.3"))
        XCTAssertNil(UpdateHandoff.resolve(saved: nil, currentVersion: "1.0.4"))
    }

    func testBusySnapshot() {
        XCTAssertFalse(AppActivity.Snapshot().isBusy)
        XCTAssertTrue(AppActivity.Snapshot(fileTranscription: true).isBusy)
        XCTAssertTrue(AppActivity.Snapshot(dictation: true).isBusy)
        XCTAssertTrue(AppActivity.Snapshot(analysis: true).isBusy)
        XCTAssertTrue(AppActivity.Snapshot(libraryWork: true).isBusy)
    }

    /// Лента, ключ подписи и фоновое скачивание заданы в Info.plist исходников:
    /// без них Sparkle не стартует или не качает заранее, а сборка всё равно
    /// проходит — заметили бы только на живом обновлении.
    func testInfoPlistDeclaresUpdateFeed() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Info.plist")
        let plist = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: Any])
        XCTAssertEqual(plist["SUFeedURL"] as? String,
                       "https://github.com/ippitenin/DOKA-macOS/releases/latest/download/appcast.xml")
        let key = try XCTUnwrap(plist["SUPublicEDKey"] as? String)
        // Публичный ключ Ed25519 — 32 байта в base64.
        XCTAssertEqual(Data(base64Encoded: key)?.count, 32)
        XCTAssertEqual(plist["SUEnableAutomaticChecks"] as? Bool, true)
        XCTAssertEqual(plist["SUAutomaticallyUpdate"] as? Bool, true)
    }
}
