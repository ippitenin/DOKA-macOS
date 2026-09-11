import AppKit
import SwiftUI

/// Главное окно приложения: сайдбар с секциями (Главная, Общие, Клавиши,
/// Словарь, Сервис, История). Создаётся лениво и переживает закрытие.
@MainActor
final class WindowManager {
    static let shared = WindowManager()

    private let mainState = MainWindowState()
    private var mainWindow: NSWindow?

    private init() {}

    /// Открывает главное окно на указанной секции.
    func showMain(section: MainSection? = nil) {
        if let section {
            mainState.section = section
        }
        if mainWindow == nil {
            mainWindow = makeMainWindow()
        }
        guard let window = mainWindow else { return }
        if !window.isVisible {
            center(window)
        }
        // Свёрнутое по Cmd+M окно makeKeyAndOrderFront сам не разворачивает —
        // без этого «Открыть» из меню-бара не вернуло бы окно из Dock.
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Возвращает фокус видимому главному окну: после смены activation
    /// policy (тоггл Dock-иконки) окно теряет key-статус.
    func refocusMain() {
        guard let window = mainWindow, window.isVisible else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    // Точки входа из старого кода (меню-бар, AppDelegate, DictationController).
    func showSettings() { showMain(section: .general) }
    func showHistory() { showMain(section: .history) }
    func showOnboarding() { showMain(section: .home) }

    /// Библиотека: с открытой записью либо на списке. Единая точка «открыть
    /// запись» — для полосы «Недавние», кнопки «Открыть в библиотеке» и
    /// (в следующих фазах) уведомлений; см. `LibraryNavigator`.
    func showLibrary(recordID: UUID?) {
        if let recordID {
            LibraryModel.shared.open(recordID)
        } else {
            LibraryModel.shared.close()
        }
        showMain(section: .library)
    }

    /// Запрос открыть «Общие → Расширенные»: под-страница — drill-in на
    /// `@State` секции «Общие», поэтому запрос забирает сама секция при
    /// появлении (`consumeAdvancedRequest`).
    private var advancedRequested = false

    func showAdvancedSettings() {
        advancedRequested = true
        showMain(section: .general)
    }

    func consumeAdvancedRequest() -> Bool {
        defer { advancedRequested = false }
        return advancedRequested
    }

    private func makeMainWindow() -> NSWindow {
        let hosting = NSHostingController(
            rootView: MainWindowView(state: mainState)
        )
        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // Тайтлбар скрыт: трафик-лайты лежат поверх сайдбара, как в Системных
        // настройках. title остаётся — для Mission Control и VoiceOver.
        window.title = "DOKA"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        // Пустой невидимый тулбар делает тайтлбар выше (52pt): трафик-лайты
        // опускаются к его центру и сидят внутри плашки сайдбара, как в Finder.
        let toolbar = NSToolbar(identifier: "doka.main")
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        // Перетаскивание — только за зону тайтлбара, как у обычных приложений:
        // иначе окно срывается с места при любом неудачном клике по фону.
        window.isMovableByWindowBackground = false
        window.isReleasedWhenClosed = false
        window.contentViewController = hosting
        // Размер должен быть рассчитан ДО центрирования, иначе окно
        // центрируется с нулевым размером и «вырастает» из верхней точки.
        window.setContentSize(NSSize(width: 900, height: 640))
        window.minSize = NSSize(width: 840, height: 560)
        // Меню-бар-приложение: окно показывается на текущем Space
        // (в том числе поверх полноэкранных приложений), а не остаётся
        // на том рабочем столе, где его открыли в прошлый раз.
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        return window
    }

    /// Настоящий центр экрана с курсором (NSWindow.center() ставит окно
    /// в верхнюю треть и всегда на главный экран).
    private func center(_ window: NSWindow) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = window.frame.size
        window.setFrameOrigin(NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2
        ))
    }
}
