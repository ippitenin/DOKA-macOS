import AppKit
import Combine
import SwiftUI

/// Главное окно приложения: сайдбар с секциями (Главная, Общие, Клавиши,
/// Словарь, Сервис, История). Создаётся лениво и переживает закрытие.
@MainActor
final class WindowManager {
    static let shared = WindowManager()

    private let mainState = MainWindowState()
    private var mainWindow: NSWindow?
    /// Делегат окна — держим сами: `NSWindow.delegate` слабый.
    private let windowDelegate = MainWindowDelegate()
    /// Окно «Тренировка» (эксперимент «Губы») — тоже ленивое.
    private var trainingWindow: NSWindow?
    private let trainingDelegate = TrainingWindowDelegate()
    private var cancellables: Set<AnyCancellable> = []

    private init() {
        // Минимальная высота окна зависит от числа пунктов сайдбара (раздел
        // «Губы»): ставим её окну явно, а не надеемся на SwiftUI-рамку.
        SettingsStore.shared.$lipsExperiment
            .receive(on: RunLoop.main)
            .sink { [weak self] enabled in
                self?.applyMinSize(lipsEnabled: enabled)
                // Эксперимент выключили — тренировке без него не место.
                if !enabled { self?.closeTraining() }
            }
            .store(in: &cancellables)
    }

    private func applyMinSize(lipsEnabled: Bool) {
        guard let window = mainWindow else { return }
        let height = MainWindowLayout.minHeight(lipsEnabled: lipsEnabled)
        window.minSize = NSSize(width: MainWindowLayout.minWidth, height: height)
        // Окно ниже нового минимума — подрастить вниз, не сдвигая верх.
        if window.frame.height < height {
            var frame = window.frame
            frame.origin.y -= height - frame.height
            frame.size.height = height
            window.setFrame(frame, display: true, animate: true)
        }
    }

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

    /// Видит ли пользователь секцию прямо сейчас: приложение активно, главное
    /// окно key (или key — его шит: алерт, «Распознать заново», выбор файла),
    /// видимо, не свёрнуто и не заслонено. Уведомления так не дублируют
    /// результат, который и так на глазах; ушёл в другое приложение — баннер придёт.
    func isShowing(_ section: MainSection) -> Bool {
        guard let window = mainWindow, NSApp.isActive, window.isVisible,
              !window.isMiniaturized, window.occlusionState.contains(.visible) else { return false }
        let key = NSApp.keyWindow
        guard key === window || key?.sheetParent === window else { return false }
        return mainState.section == section
    }

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

    /// Окно «Тренировка». Каждый показ закрытого окна — новый сеанс: свежая
    /// очередь фраз и счётчик «за сеанс».
    func showTraining() {
        guard SettingsStore.shared.lipsExperiment else { return }
        if trainingWindow == nil {
            trainingWindow = makeTrainingWindow()
        }
        guard let window = trainingWindow else { return }
        if !window.isVisible {
            // Вью — заново: так она снова берёт фокус клавиатуры и подписывается.
            let hosting = NSHostingController(rootView: LipTrainingView())
            hosting.sizingOptions = .preferredContentSize
            window.contentViewController = hosting
            window.setContentSize(hosting.view.fittingSize)
            center(window)
            LipTrainingController.shared.beginSession()
        }
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func closeTraining() {
        guard let window = trainingWindow, window.isVisible else { return }
        window.performClose(nil)
    }

    private func makeTrainingWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = L("training.window.title")
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = false
        window.isReleasedWhenClosed = false
        window.delegate = trainingDelegate
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        return window
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
        window.delegate = windowDelegate
        // Размер должен быть рассчитан ДО центрирования, иначе окно
        // центрируется с нулевым размером и «вырастает» из верхней точки.
        window.setContentSize(NSSize(width: 900, height: 640))
        window.minSize = NSSize(width: MainWindowLayout.minWidth,
                                height: MainWindowLayout.minHeight(lipsEnabled: SettingsStore.shared.lipsExperiment))
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

/// Делегат окна «Тренировка»: закрытие — конец сеанса. Идущая фраза
/// выбрасывается, отложенная фиксируется; вью уходит из окна и отписывается
/// от камеры.
@MainActor
private final class TrainingWindowDelegate: NSObject, NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        LipTrainingController.shared.endSession()
        (notification.object as? NSWindow)?.contentViewController = nil
    }
}

/// Делегат главного окна: шиты встают по вертикальному центру окна.
/// Система вешает шит сразу под тулбаром, и высокий шит упирался в нижнюю
/// кромку, а невысокий — висел у верха. Высокий, которому по центру места
/// не хватает, остаётся на системном месте (выше тулбара шит не уезжает).
@MainActor
private final class MainWindowDelegate: NSObject, NSWindowDelegate {
    func window(_ window: NSWindow, willPositionSheet sheet: NSWindow,
                using rect: NSRect) -> NSRect {
        // `rect.origin.y` — кромка, от которой шит свисает вниз (координаты
        // окна, начало снизу). По центру: верх шита на (высота + шит) / 2.
        let height = window.contentView?.bounds.height ?? window.frame.height
        let centeredTop = ((height + sheet.frame.height) / 2).rounded()
        var positioned = rect
        positioned.origin.y = min(rect.origin.y, centeredTop)
        return positioned
    }
}
