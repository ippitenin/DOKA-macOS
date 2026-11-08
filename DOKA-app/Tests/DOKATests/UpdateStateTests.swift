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

    /// Точка в меню-баре — пока новую версию можно поставить или она ждёт покоя;
    /// во время установки, после неё и без находки — нет.
    func testMenuBarBadge() {
        XCTAssertTrue(UpdateState.ready(info).showsMenuBarBadge)
        XCTAssertTrue(UpdateState.waitingForIdle(info).showsMenuBarBadge)
        for state: UpdateState in [.idle, .checking, .upToDate(Date()), .failed("сеть"),
                                   .downloading(info, fraction: 0.5), .installing(info), .updated(info)] {
            XCTAssertFalse(state.showsMenuBarBadge, "\(state)")
        }
    }

    /// Проверка сверх расписания: без даты — сразу; при запуске — не чаще
    /// раза в 5 минут; после сна — когда прошёл интервал Sparkle.
    func testScheduleOverdue() {
        let now = Date(timeIntervalSince1970: 100_000)
        XCTAssertTrue(UpdateSchedule.isOverdue(last: nil, now: now, interval: 3600))
        XCTAssertFalse(UpdateSchedule.isOverdue(last: now.addingTimeInterval(-3599), now: now, interval: 3600))
        XCTAssertTrue(UpdateSchedule.isOverdue(last: now.addingTimeInterval(-3600), now: now, interval: 3600))
        XCTAssertTrue(UpdateSchedule.shouldCheckAtLaunch(last: nil, now: now))
        XCTAssertFalse(UpdateSchedule.shouldCheckAtLaunch(last: now.addingTimeInterval(-60), now: now))
        XCTAssertTrue(UpdateSchedule.shouldCheckAtLaunch(last: now.addingTimeInterval(-301), now: now))
    }

    /// Заметки установленной версии живут, пока версия бандла та же.
    func testInstalledNotesMatchVersion() {
        let saved = UpdateHandoff.Saved(version: "1.0.5", notes: "- новое")
        XCTAssertEqual(InstalledNotes.resolve(saved: saved, currentVersion: "1.0.5"),
                       UpdateInfo(version: "1.0.5", notes: "- новое", infoURL: nil))
        XCTAssertNil(InstalledNotes.resolve(saved: saved, currentVersion: "1.0.6"))
        XCTAssertNil(InstalledNotes.resolve(saved: nil, currentVersion: "1.0.5"))
        XCTAssertNil(InstalledNotes.resolve(saved: .init(version: "1.0.5", notes: nil), currentVersion: "1.0.5"))
        XCTAssertNil(InstalledNotes.resolve(saved: .init(version: "1.0.5", notes: ""), currentVersion: "1.0.5"))
    }

    /// «Что нового»: найденная версия главнее установленной; без находки —
    /// установленная (в т.ч. после того, как плашку скрыли крестиком).
    func testReleaseNotesContent() {
        let installed = UpdateInfo(version: "1.0.3", notes: "- старое", infoURL: nil)
        XCTAssertEqual(ReleaseNotesContent.make(state: .ready(info), installedNotes: installed),
                       ReleaseNotesContent(info: info, installed: false))
        XCTAssertEqual(ReleaseNotesContent.make(state: .waitingForIdle(info), installedNotes: nil)?.installed, false)
        XCTAssertEqual(ReleaseNotesContent.make(state: .updated(info), installedNotes: nil),
                       ReleaseNotesContent(info: info, installed: true))
        for state: UpdateState in [.idle, .upToDate(Date()), .checking, .failed("сеть")] {
            XCTAssertEqual(ReleaseNotesContent.make(state: state, installedNotes: installed),
                           ReleaseNotesContent(info: installed, installed: true), "\(state)")
            XCTAssertNil(ReleaseNotesContent.make(state: state, installedNotes: nil), "\(state)")
        }
        // Найдена версия без заметок — заметки установленной не подставляются.
        let bare = UpdateInfo(version: "1.0.4", notes: nil, infoURL: nil)
        XCTAssertNil(ReleaseNotesContent.make(state: .ready(bare), installedNotes: installed))
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
        // Раз в час: при сутках новая версия ждала проверки до следующего дня.
        XCTAssertEqual(plist["SUScheduledCheckInterval"] as? Int, 3600)
    }
}
