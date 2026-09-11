import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var dictationController: DictationController!
    private var hotkeyManager: HotkeyManager!
    private var menuBarManager: MenuBarManager!
    private var panelController: RecorderPanelController!

    /// Делегат уведомлений — ДО завершения запуска: иначе ответ на клик по
    /// уведомлению при незапущенном приложении может не дойти; события добора
    /// (resumePendingJobs в didFinishLaunching) тоже должны застать подписку.
    func applicationWillFinishLaunching(_ notification: Notification) {
        FileTranscriptionNotifier.shared.install()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Сироты временных WAV прошлых запусков (слот повтора диктовки живёт
        // в памяти) — фоном, запуск не ждёт файловую систему.
        let launch = Date()
        Task.detached(priority: .utility) {
            DictationController.sweepOrphanedTempFiles(before: launch)
        }
        installEditMenu()
        dictationController = DictationController()
        panelController = RecorderPanelController(controller: dictationController)
        hotkeyManager = HotkeyManager(controller: dictationController)
        menuBarManager = MenuBarManager(controller: dictationController)

        dictationController.hotkeys = hotkeyManager
        dictationController.panelController = panelController
        dictationController.onNeedsOnboarding = {
            WindowManager.shared.showOnboarding()
        }

        // Чистка просроченного аудио истории по сроку хранения (только когда запись включена).
        let settings = SettingsStore.shared
        if settings.saveAudio, let days = settings.audioRetention.days {
            HistoryStore.shared.pruneAudio(olderThan: days)
        }

        // Библиотека транскрибаций: загрузка (синхронно, с миграцией журнала
        // v1) при первом обращении, чистка по сроку и добор незавершённых
        // async-задач Nexara (задача переживает перезапуск приложения).
        TranscriptHistoryStore.shared.prune(retention: settings.transcriptRetention)
        TranscriptHistoryStore.shared.resumePendingJobs()

        let permissions = PermissionsManager.shared
        permissions.refresh()
        if permissions.allGranted && SettingsStore.shared.isServiceReady {
            // Всё уже выдано — онбординг не нужен, даже если его закрыли крестиком.
            SettingsStore.shared.onboardingCompleted = true
            // Иначе запуск незаметен (только иконка в меню-баре); тоггл —
            // в «Расширенных» настройках.
            if settings.openWindowAtLaunch {
                WindowManager.shared.showMain(section: .home)
            }
        } else {
            WindowManager.shared.showOnboarding()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Слот повтора диктовки живёт только в памяти — его WAV не должен
    /// пережить процесс (при крэше/kill подчистит sweep на следующем старте).
    func applicationWillTerminate(_ notification: Notification) {
        dictationController?.discardFailedDictation()
        // Записи библиотеки идут фоновой очередью, а exit() её не ждёт:
        // без flush готовая запись после перезапуска оказалась бы «прерванной».
        TranscriptHistoryStore.shared.flush()
    }

    /// Повторный запуск (open/двойной клик в Finder) открывает главное окно.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        WindowManager.shared.showMain(section: .home)
        return false
    }

    /// У приложения меню-бара нет главного меню, а Cmd+V/C/X/A в macOS
    /// работают только через пункты меню «Правка». Меню не видно
    /// (LSUIElement), но маршрутизацию клавиш оно обеспечивает.
    private func installEditMenu() {
        let editMenu = NSMenu(title: L("edit.menu"))
        editMenu.addItem(withTitle: L("edit.undo"), action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: L("edit.redo"), action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: L("edit.cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: L("edit.copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: L("edit.paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: L("edit.selectAll"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        // Меню «Окно»: без пунктов меню Cmd+W/Cmd+M не работают вовсе.
        // Селекторы first-responder (target nil) уходят активному окну;
        // после закрытия приложение живёт в меню-баре
        // (applicationShouldTerminateAfterLastWindowClosed == false).
        let windowMenu = NSMenu(title: L("window.menu"))
        windowMenu.addItem(withTitle: L("window.close"),
                           action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: L("window.minimize"),
                           action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")

        let mainMenu = NSMenu()
        let editItem = NSMenuItem()
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)
        let windowItem = NSMenuItem()
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)
        NSApp.mainMenu = mainMenu
    }
}
