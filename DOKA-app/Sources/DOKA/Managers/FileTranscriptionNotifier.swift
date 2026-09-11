import AppKit
import Combine
import UserNotifications

/// Системные уведомления о файловой транскрибации: «готово» и «не удалось» —
/// только об исходах, которых пользователь ждал (путь контроллера, добор
/// после перезапуска, повторный опрос). Источник событий один —
/// `TranscriptHistoryStore.finished`; безнадёжные на старте записи туда не
/// попадают (`markError(notify: false)`), отмена — тоже.
@MainActor
final class FileTranscriptionNotifier: NSObject {
    static let shared = FileTranscriptionNotifier()

    /// nonisolated — читается из nonisolated-методов делегата.
    nonisolated static let recordIDKey = "recordID"
    private static let threadID = "doka.fileTranscription"

    /// `UNUserNotificationCenter.current()` бросает исключение у процесса без
    /// бандла (голый `.build/debug/DOKA`, xctest) — только собранный `.app`.
    static var isSupported: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
    }

    private var center: UNUserNotificationCenter? { Self.isSupported ? .current() : nil }
    private var cancellables = Set<AnyCancellable>()
    /// id записей библиотеки — чтобы заметить удалённые.
    private var knownIDs: Set<UUID> = []

    private override init() {
        super.init()
    }

    /// В `applicationWillFinishLaunching`: делегат обязан стоять ДО
    /// завершения запуска, иначе ответ на клик при незапущенном приложении
    /// может не дойти; события добора (`resumePendingJobs`) тоже должны
    /// застать подписку.
    func install() {
        guard cancellables.isEmpty else { return }
        center?.delegate = self
        let store = TranscriptHistoryStore.shared
        store.finished
            .sink { [weak self] record in self?.notifyFinished(record) }
            .store(in: &cancellables)
        knownIDs = Set(store.records.map(\.id))
        // @Published отдаёт новое значение параметром (willSet).
        store.$records
            .sink { [weak self] records in self?.recordsDidChange(records) }
            .store(in: &cancellables)
    }

    /// Разрешение спрашивается лениво — при запуске транскрибации и при
    /// включении тумблера, не на старте приложения.
    func requestAuthorizationIfNeeded() async {
        guard let center, SettingsStore.shared.notifyFileTranscription else { return }
        guard await center.notificationSettings().authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    /// Статус разрешения для карточки настроек; nil — уведомления в этом
    /// процессе недоступны (не собранный `.app`).
    func authorizationStatus() async -> UNAuthorizationStatus? {
        guard let center else { return nil }
        return await center.notificationSettings().authorizationStatus
    }

    /// Настройки уведомлений DOKA в Системных настройках (после запрета).
    func openSystemSettings() {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.pitenin.doka"
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(bundleID)") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Постановка

    private func notifyFinished(_ record: FileTranscriptRecord) {
        guard let center, SettingsStore.shared.notifyFileTranscription else { return }
        let content = UNMutableNotificationContent()
        switch record.status {
        case .done:
            content.title = L("notify.transcribe.done.title")
            content.body = [record.displayTitle, record.durationLabel]
                .compactMap { $0 }
                .joined(separator: " · ")
        case .error(let message):
            content.title = L("notify.transcribe.failed.title")
            content.body = L("notify.transcribe.failed.body", record.displayTitle, message)
        case .inProgress, .cancelled:
            return
        }
        // Результат и так на глазах — баннер его только продублировал бы.
        guard !isOnScreen(record) else { return }
        content.sound = .default
        content.threadIdentifier = Self.threadID
        content.userInfo = [Self.recordIDKey: record.id.uuidString]
        // Идентификатор — id записи: повтор той же записи заменяет прежнее
        // уведомление, а не копит их.
        let request = UNNotificationRequest(identifier: record.id.uuidString,
                                            content: content, trigger: nil)
        Task {
            // Не спрошено или запрещено — молча пропускаем: на старте (добор)
            // разрешение не запрашиваем.
            switch await center.notificationSettings().authorizationStatus {
            case .authorized, .provisional:
                try? await center.add(request)
            default:
                return
            }
        }
    }

    /// Видна ли запись прямо сейчас: на «Транскрибации» — если это задача или
    /// результат страницы (добор другой записи там не виден), в библиотеке —
    /// если открыт список или сама запись.
    private func isOnScreen(_ record: FileTranscriptRecord) -> Bool {
        let windows = WindowManager.shared
        if windows.isShowing(.transcribe) {
            let controller = FileTranscriptionController.shared
            return controller.runningRecordID == record.id || controller.shownRecordID == record.id
        }
        if windows.isShowing(.library) {
            let opened = LibraryModel.shared.openedRecordID
            return opened == nil || opened == record.id
        }
        return false
    }

    /// Удалённые записи — их уведомления из Центра уведомлений убираем:
    /// клик вёл бы в несуществующую запись.
    private func recordsDidChange(_ records: [FileTranscriptRecord]) {
        let ids = Set(records.map(\.id))
        let removed = knownIDs.subtracting(ids)
        knownIDs = ids
        guard !removed.isEmpty else { return }
        center?.removeDeliveredNotifications(withIdentifiers: removed.map(\.uuidString))
    }

    /// Клик по уведомлению: запись в библиотеке. Если её уже удалили — список.
    fileprivate func open(recordID: UUID) {
        center?.removeDeliveredNotifications(withIdentifiers: [recordID.uuidString])
        if TranscriptHistoryStore.shared.record(recordID) != nil {
            LibraryNavigator.open(recordID)
        } else {
            LibraryNavigator.showList()
        }
    }
}

/// Методы делегата nonisolated: `@MainActor`-метод, закрывающий
/// nonisolated-требование ObjC-протокола, дал бы предупреждение. Варианты с
/// completion, а не async: у async-перевода системный completion вызывается
/// вне главного потока (на iOS 15 так падало с «must be made on main thread»).
extension FileTranscriptionNotifier: UNUserNotificationCenterDelegate {
    /// Подавление решено в момент постановки (`isOnScreen`), поэтому баннер
    /// показываем и при активном приложении — иначе macOS молча положит его
    /// в Центр уведомлений.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    /// Через границу акторов передаётся только UUID, не сам ответ.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let raw = response.actionIdentifier == UNNotificationDefaultActionIdentifier
            ? response.notification.request.content.userInfo[Self.recordIDKey] as? String
            : nil
        let id = raw.flatMap(UUID.init(uuidString:))
        DispatchQueue.main.async {
            if let id {
                MainActor.assumeIsolated { FileTranscriptionNotifier.shared.open(recordID: id) }
            }
            completionHandler()
        }
    }
}
