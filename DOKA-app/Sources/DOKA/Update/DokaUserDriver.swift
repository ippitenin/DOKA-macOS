import Foundation
import Sparkle

/// Свой интерфейс Sparkle: вместо стандартных окон — события для
/// `UpdateController`, а плашку и страницу «О DOKA» рисует SwiftUI в
/// дизайн-системе DOKA. Все методы Sparkle зовёт на главном потоке.
@MainActor
final class DokaUserDriver: NSObject, SPUUserDriver {
    weak var controller: UpdateController?

    /// Вопрос «проверять ли обновления автоматически?». При
    /// `SUEnableAutomaticChecks` в Info.plist не задаётся вовсе; на случай,
    /// если ключ пропадёт, — отвечаем как по умолчанию и без профиля системы.
    func show(_ request: SPUUpdatePermissionRequest,
              reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        controller?.driverUserInitiatedCheck()
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState,
                         reply: @escaping (SPUUserUpdateChoice) -> Void) {
        guard let controller else { return reply(.dismiss) }
        controller.driverFoundUpdate(appcastItem, stage: state.stage, reply: reply)
    }

    /// Заметки встроены в ленту (`<description>`), ссылки на них нет.
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        guard let controller else { return acknowledgement() }
        controller.driverNoUpdate(acknowledgement: acknowledgement)
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        guard let controller else { return acknowledgement() }
        controller.driverError(error, acknowledgement: acknowledgement)
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        controller?.driverDownloadStarted()
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        controller?.driverExpectedLength(expectedContentLength)
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        controller?.driverReceivedData(length)
    }

    func showDownloadDidStartExtractingUpdate() {}

    func showExtractionReceivedProgress(_ progress: Double) {}

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        guard let controller else { return reply(.dismiss) }
        controller.driverReadyToRelaunch(reply: reply)
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool,
                              retryTerminatingApplication: @escaping () -> Void) {
        controller?.driverInstalling()
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        acknowledgement()
    }

    func dismissUpdateInstallation() {
        controller?.driverDismiss()
    }
}
