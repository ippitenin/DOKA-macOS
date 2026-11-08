import AppKit
import Combine
import Sparkle
import SwiftUI

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
    /// Полоса окна установки (0…1). Двигается плавно (`withAnimation`), чтобы
    /// установка не была мгновенным «щелчком» — как в Telegram.
    @Published private(set) var installProgress: Double = 0

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
    /// Начало ручной проверки — для минимальной длительности «Проверяю…».
    private var checkStartedAt: Date?

    /// Сколько ползёт полоса установки, и пауза на «100 %» перед перезапуском.
    private static let installDuration: TimeInterval = 2.8
    private static let installSettle: TimeInterval = 0.35

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
        // Первый запуск после установки через «Обновить» — «DOKA обновлена».
        let defaults = UserDefaults.standard
        let saved = defaults.data(forKey: UpdateHandoff.key)
            .flatMap { try? JSONDecoder().decode(UpdateHandoff.Saved.self, from: $0) }
        defaults.removeObject(forKey: UpdateHandoff.key)
        if let info = UpdateHandoff.resolve(saved: saved, currentVersion: AppVersion.short) {
            state = .updated(info)
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
        checkStartedAt = Date()
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
        guard case .ready(let info) = state else { return }
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

    /// Установка «как в Telegram»: главное окно гаснет, появляется окно
    /// «Обновление DOKA» с плавно ползущей полосой, и только потом DOKA
    /// перезапускается новой. Без фонового скачивания полоса сначала идёт
    /// по настоящей доле скачивания (`downloading`), затем доползает до конца.
    private func performInstall() {
        guard let info = state.info else { return }
        if immediateInstall != nil || readyToRelaunch != nil {
            presentInstallWindow(info)
            runInstall(info, from: 0)
        } else if let pendingChoice {
            presentInstallWindow(info)
            state = .downloading(info, fraction: nil)
            self.pendingChoice = nil
            pendingChoice(.install)
        }
    }

    private func presentInstallWindow(_ info: UpdateInfo) {
        // Что ставили — новая DOKA покажет «DOKA обновлена · Что нового».
        let saved = UpdateHandoff.Saved(version: info.version, notes: info.notes)
        if let data = try? JSONEncoder().encode(saved) {
            UserDefaults.standard.set(data, forKey: UpdateHandoff.key)
        }
        installProgress = 0
        WindowManager.shared.hideMainForUpdate()
        UpdateInstallPanelController.shared.show(updates: self)
    }

    /// Полоса доползает от `from` до конца, затем — блок Sparkle «поставить
    /// сейчас»: DOKA завершается, Sparkle меняет бандл и запускает новую.
    private func runInstall(_ info: UpdateInfo, from start: Double) {
        state = .installing(info)
        installProgress = start
        let duration = Self.installDuration * (1 - start)
        withAnimation(.easeInOut(duration: duration)) { installProgress = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + Self.installSettle) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, case .installing = self.state else { return }
                if let immediateInstall = self.immediateInstall {
                    self.immediateInstall = nil
                    immediateInstall()
                } else if let readyToRelaunch = self.readyToRelaunch {
                    self.readyToRelaunch = nil
                    readyToRelaunch(.install)
                }
            }
        }
    }

    /// Установка сорвалась: окно установки прочь, главное окно назад.
    private func abortInstallWindow() {
        UserDefaults.standard.removeObject(forKey: UpdateHandoff.key)
        UpdateInstallPanelController.shared.hide()
        WindowManager.shared.showMain()
    }

    /// Итог ручной проверки — не раньше `UpdateTiming.minimumCheck` после
    /// нажатия: мгновенный ответ дёргал бы карточку «О DOKA» дважды.
    private func settleCheck(_ apply: @escaping @MainActor () -> Void) {
        guard let started = checkStartedAt else { return apply() }
        checkStartedAt = nil
        let delay = UpdateTiming.remainingDelay(started: started)
        guard delay > 0 else { return apply() }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            MainActor.assumeIsolated { apply() }
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
        settleCheck { [weak self] in self?.state = .ready(info) }
    }

    func driverNoUpdate(acknowledgement: @escaping () -> Void) {
        userInitiatedCheck = false
        acknowledgement()
        settleCheck { [weak self] in
            let now = Date()
            self?.lastCheck = now
            self?.state = .upToDate(now)
        }
    }

    func driverError(_ error: Error, acknowledgement: @escaping () -> Void) {
        let shouldShow = userInitiatedCheck || installRequested
        userInitiatedCheck = false
        installRequested = false
        NSLog("[Update] ошибка: %@", error.localizedDescription)
        acknowledgement()
        if UpdateInstallPanelController.shared.isVisible { abortInstallWindow() }
        let message = error.localizedDescription
        settleCheck { [weak self] in self?.state = shouldShow ? .failed(message) : .idle }
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
        let fraction = min(1, Double(receivedLength) / Double(expectedLength))
        state = .downloading(info, fraction: fraction)
        installProgress = fraction * Self.downloadShare
    }

    func driverReadyToRelaunch(reply: @escaping (SPUUserUpdateChoice) -> Void) {
        // Сюда приходят только после нажатия «Обновить» — ставим сразу,
        // но снова уважаем занятость: за время скачивания могла начаться диктовка.
        readyToRelaunch = reply
        guard let info = state.info else { return }
        // Окно установки уже на экране (шло скачивание) — полоса доползает
        // от доли скачивания. Иначе (повторная проверка нашла уже скачанное) —
        // обычный ход через «Обновить».
        if UpdateInstallPanelController.shared.isVisible {
            runInstall(info, from: max(installProgress, Self.downloadShare))
        } else if AppActivity.isBusy {
            state = .waitingForIdle(info)
            waitForIdle { [weak self] in self?.performInstall() }
        } else {
            performInstall()
        }
    }

    /// Доля полосы окна установки, отданная скачиванию (остальное — установка).
    private static let downloadShare = 0.6

    func driverInstalling() {
        // Наша полоса уже ведёт `installing` — не перебиваем её.
        guard case .installing = state else {
            if let info = state.info { state = .installing(info) }
            return
        }
    }

    /// Sparkle закончил сессию. Итог проверки («последняя версия», ошибка,
    /// готовое обновление) остаётся на экране; гасим только промежуточные стадии.
    func driverDismiss() {
        readyToRelaunch = nil
        switch state {
        case .checking, .downloading, .installing:
            if UpdateInstallPanelController.shared.isVisible { abortInstallWindow() }
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
