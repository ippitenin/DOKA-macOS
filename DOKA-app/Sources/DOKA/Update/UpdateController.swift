import AppKit
import Combine
import Sparkle

/// Автообновление: владелец `SPUUpdater`, единственный источник состояния
/// обновления для интерфейса (плашка сайдбара, «О DOKA», меню-бар).
///
/// Два пути к установке (подробно — `Update/CLAUDE.md`):
/// - **фоновое скачивание** (по умолчанию): Sparkle сам качает и распаковывает
///   новую версию и зовёт `willInstallUpdateOnQuit` с блоком «поставить сейчас»;
///   кнопка «Обновить» вызывает этот блок, а простой выход из DOKA ставит
///   обновление и без кнопки;
/// - **без фонового скачивания** или после ручной проверки: драйвер получает
///   `showUpdateFound` с ответом, «Обновить» отвечает `.install`, дальше —
///   скачивание с прогрессом и установка.
///
/// Установка не обрывает работу: пока `AppActivity.isBusy`, нажатие ждёт покоя.
@MainActor
final class UpdateController: NSObject, ObservableObject {
    static let shared = UpdateController()

    @Published private(set) var state: UpdateState = .idle
    /// Версия, скрытая крестиком плашки в этом запуске.
    @Published private(set) var dismissedVersion: String?
    @Published private(set) var lastCheck: Date?

    /// Обновлятор работает: в бандле есть лента (`SUFeedURL`). Её нет у
    /// сборок без Developer ID — `build.sh` вырезает ключ, чтобы самосборка
    /// не заменилась молча официальной (со сбросом разрешений), и у голого
    /// бинаря `swift run`.
    let isAvailable: Bool

    private var updater: SPUUpdater?
    private let userDriver = DokaUserDriver()

    /// Ответ на `showUpdateFound`: держим до нажатия «Обновить».
    private var pendingChoice: ((SPUUserUpdateChoice) -> Void)?
    /// Блок «поставить сейчас» от фонового скачивания.
    private var immediateInstall: (() -> Void)?
    /// Ответ на `showReadyToInstallAndRelaunch` (путь без фонового скачивания).
    private var readyToRelaunch: ((SPUUserUpdateChoice) -> Void)?
    /// Проверку запустил пользователь — о её ошибке надо сказать.
    private var userInitiatedCheck = false
    /// Пользователь нажал «Обновить» — ошибки этого цикла тоже показываем.
    private var installRequested = false
    private var expectedLength: UInt64 = 0
    private var receivedLength: UInt64 = 0
    private var idleTimer: Timer?

    /// Переопределение ленты для стенда обновления:
    /// `defaults write com.pitenin.doka DOKAUpdateFeedOverride <URL>`.
    static let feedOverrideKey = "DOKAUpdateFeedOverride"

    private override init() {
        let bundled = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String
        let override = UserDefaults.standard.string(forKey: Self.feedOverrideKey)
        isAvailable = Bundle.main.bundleURL.pathExtension == "app"
            && (bundled?.isEmpty == false || override?.isEmpty == false)
        super.init()
        userDriver.controller = self
    }

    /// Запуск планировщика проверок. Зовётся из `AppDelegate` после миграций.
    func start() {
        guard isAvailable else {
            NSLog("[Update] лента не задана (сборка не от Developer ID) — автообновление выключено")
            return
        }
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main,
                                 userDriver: userDriver, delegate: self)
        do {
            try updater.start()
            self.updater = updater
            lastCheck = updater.lastUpdateCheckDate
        } catch {
            NSLog("[Update] Sparkle не запустился: %@", error.localizedDescription)
        }
    }

    // MARK: - Настройки (хранит сам Sparkle в UserDefaults)

    var automaticallyChecks: Bool {
        get { updater?.automaticallyChecksForUpdates ?? false }
        set {
            objectWillChange.send()
            updater?.automaticallyChecksForUpdates = newValue
        }
    }

    var automaticallyDownloads: Bool {
        get { updater?.automaticallyDownloadsUpdates ?? false }
        set {
            objectWillChange.send()
            updater?.automaticallyDownloadsUpdates = newValue
        }
    }

    var canCheck: Bool {
        guard let updater else { return false }
        switch state {
        case .checking, .waitingForIdle, .downloading, .installing: return false
        default: return updater.canCheckForUpdates
        }
    }

    var banner: UpdateBannerModel? {
        UpdateBannerModel.make(state: state, dismissedVersion: dismissedVersion)
    }

    // MARK: - Действия

    func checkNow() {
        guard let updater, canCheck else { return }
        // Найденная фоном версия уже стоит в очереди: повторная проверка
        // покажет её же (Sparkle вернёт стадию «скачано/ставится»).
        updater.checkForUpdates()
    }

    func dismissBanner() {
        guard let info = state.info else { return }
        dismissedVersion = info.version
    }

    /// «Обновить»: ставить, как только DOKA свободна.
    func installNow() {
        guard let info = state.info else { return }
        if let url = info.infoURL {
            // Информационное обновление: ставить нечего, ведём на страницу релиза.
            NSWorkspace.shared.open(url)
            return
        }
        installRequested = true
        if AppActivity.isBusy {
            state = .waitingForIdle(info)
            waitForIdle { [weak self] in self?.performInstall() }
        } else {
            performInstall()
        }
    }

    private func performInstall() {
        guard let info = state.info else { return }
        if let immediateInstall {
            state = .installing(info)
            self.immediateInstall = nil
            immediateInstall()
        } else if let readyToRelaunch {
            state = .installing(info)
            self.readyToRelaunch = nil
            readyToRelaunch(.install)
        } else if let pendingChoice {
            state = .downloading(info, fraction: nil)
            self.pendingChoice = nil
            pendingChoice(.install)
        }
    }

    /// Раз в секунду проверяет занятость; таймер один на всё приложение.
    private func waitForIdle(then action: @escaping () -> Void) {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard !AppActivity.isBusy else { return }
                timer.invalidate()
                self?.idleTimer = nil
                action()
            }
        }
    }

    private static func info(from item: SUAppcastItem) -> UpdateInfo {
        let notes = item.itemDescription?.trimmingCharacters(in: .whitespacesAndNewlines)
        return UpdateInfo(version: item.displayVersionString,
                          notes: (notes?.isEmpty ?? true) ? nil : notes,
                          infoURL: item.isInformationOnlyUpdate ? item.infoURL : nil)
    }

    // MARK: - События драйвера (`DokaUserDriver`)

    func driverUserInitiatedCheck() {
        userInitiatedCheck = true
        state = .checking
    }

    func driverFoundUpdate(_ item: SUAppcastItem, stage: SPUUserUpdateStage,
                           reply: @escaping (SPUUserUpdateChoice) -> Void) {
        let info = Self.info(from: item)
        userInitiatedCheck = false
        if info.infoURL != nil {
            // Ставить нечего — ответ не держим, плашка поведёт на страницу.
            reply(.dismiss)
        } else {
            pendingChoice = reply
        }
        state = .ready(info)
    }

    func driverNoUpdate(acknowledgement: @escaping () -> Void) {
        userInitiatedCheck = false
        let now = Date()
        lastCheck = now
        state = .upToDate(now)
        acknowledgement()
    }

    func driverError(_ error: Error, acknowledgement: @escaping () -> Void) {
        let shouldShow = userInitiatedCheck || installRequested
        userInitiatedCheck = false
        installRequested = false
        NSLog("[Update] ошибка: %@", error.localizedDescription)
        state = shouldShow ? .failed(error.localizedDescription) : .idle
        acknowledgement()
    }

    func driverDownloadStarted() {
        expectedLength = 0
        receivedLength = 0
        if let info = state.info { state = .downloading(info, fraction: nil) }
    }

    func driverExpectedLength(_ length: UInt64) {
        expectedLength = length
    }

    func driverReceivedData(_ length: UInt64) {
        receivedLength += length
        guard let info = state.info, expectedLength > 0 else { return }
        state = .downloading(info, fraction: min(1, Double(receivedLength) / Double(expectedLength)))
    }

    func driverReadyToRelaunch(reply: @escaping (SPUUserUpdateChoice) -> Void) {
        // Сюда приходят только после нажатия «Обновить» — ставим сразу,
        // но снова уважаем занятость: за время скачивания могла начаться диктовка.
        readyToRelaunch = reply
        guard let info = state.info else { return }
        if AppActivity.isBusy {
            state = .waitingForIdle(info)
            waitForIdle { [weak self] in self?.performInstall() }
        } else {
            performInstall()
        }
    }

    func driverInstalling() {
        if let info = state.info { state = .installing(info) }
    }

    /// Sparkle закончил сессию. Итог проверки («последняя версия», ошибка,
    /// готовое обновление) остаётся на экране; гасим только промежуточные стадии.
    func driverDismiss() {
        readyToRelaunch = nil
        switch state {
        case .checking, .downloading, .installing:
            state = .idle
            installRequested = false
        default:
            break
        }
    }
}

// MARK: - SPUUpdaterDelegate

extension UpdateController: SPUUpdaterDelegate {
    func feedURLString(for updater: SPUUpdater) -> String? {
        let override = UserDefaults.standard.string(forKey: Self.feedOverrideKey)
        return (override?.isEmpty ?? true) ? nil : override
    }

    /// Фоновое скачивание закончено: берём установку на себя (`true`) —
    /// плашка покажет «Обновить», а при выходе из DOKA Sparkle поставит
    /// обновление сам в любом случае.
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        immediateInstall = immediateInstallHandler
        let info = Self.info(from: item)
        // Нажатие уже ждёт (`waitingForIdle`) — не откатываем его в «готово».
        if case .waitingForIdle = state { return true }
        state = .ready(info)
        return true
    }

    /// Страховка: перезапуск не обрывает работу, даже если установку начал
    /// не наш путь (например, повторный запуск установщика Sparkle).
    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        guard AppActivity.isBusy else { return false }
        state = .waitingForIdle(Self.info(from: item))
        waitForIdle(then: installHandler)
        return true
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
                 error: Error?) {
        lastCheck = updater.lastUpdateCheckDate ?? lastCheck
    }
}
