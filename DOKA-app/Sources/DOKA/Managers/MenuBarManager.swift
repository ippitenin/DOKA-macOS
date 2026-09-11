import AppKit
import Combine
import KeyboardShortcuts
import SwiftUI

/// Иконка в меню-баре и её меню. Иконка отражает состояние диктовки.
@MainActor
final class MenuBarManager {
    private let statusItem: NSStatusItem
    private let controller: DictationController
    private var cancellables = Set<AnyCancellable>()
    private let toggleItem = NSMenuItem()
    private let retryItem = NSMenuItem()

    init(controller: DictationController) {
        self.controller = controller
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        let menu = NSMenu()

        toggleItem.target = self
        toggleItem.action = #selector(toggleDictation)
        // Нативная подсказка сочетания: рисуется справа и сама обновляется
        // при переназначении (наблюдатель внутри setShortcut).
        toggleItem.setShortcut(for: .toggleRecording)
        menu.addItem(toggleItem)

        let pasteItem = NSMenuItem(
            title: L("menu.pasteLast"),
            action: #selector(pasteLast),
            keyEquivalent: ""
        )
        pasteItem.target = self
        pasteItem.setShortcut(for: .pasteLast)
        menu.addItem(pasteItem)

        // Повтор неудачной диктовки: виден, только пока в слоте есть запись.
        // isHidden, а не isEnabled — autoenablesItems перетёр бы isEnabled
        // у пункта с target.
        retryItem.target = self
        retryItem.action = #selector(retryFailed)
        retryItem.isHidden = true
        menu.addItem(retryItem)

        menu.addItem(.separator())

        // Сочетания задаются в «Клавишах» (setShortcut сам обновляет подпись
        // при переназначении). Прежний декоративный Cmd+, работал только при
        // открытом меню; настроенные здесь — глобальные.
        let openItem = NSMenuItem(title: L("menu.open"), action: #selector(openMain), keyEquivalent: "")
        openItem.target = self
        openItem.setShortcut(for: .openMainWindow)
        menu.addItem(openItem)

        let historyItem = NSMenuItem(title: L("menu.history"), action: #selector(openHistory), keyEquivalent: "")
        historyItem.target = self
        historyItem.setShortcut(for: .openHistoryWindow)
        menu.addItem(historyItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: L("menu.quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        statusItem.menu = menu

        controller.$state
            .sink { [weak self] state in self?.update(for: state) }
            .store(in: &cancellables)
        // @Published отдаёт новое значение в sink ещё до присвоения (willSet) —
        // поэтому берём значения из параметров, а не из контроллера.
        Publishers.CombineLatest(controller.$state, controller.$lastFailedDictation)
            .sink { [weak self] state, failed in self?.updateRetry(state: state, failed: failed) }
            .store(in: &cancellables)
        update(for: controller.state)
    }

    private func update(for state: DictationController.State) {
        // Покой — фирменная лого-марка; активные состояния остаются
        // SF-символами: различимость записи/распознавания/ошибки важнее бренда.
        let image: NSImage?
        let description: String
        switch state {
        case .idle:
            image = Self.logoTemplateImage ?? Self.symbolImage("mic")
            description = L("menu.status.idle")
            toggleItem.title = L("menu.startDictation")
        case .recording:
            image = Self.symbolImage("mic.fill")
            description = L("menu.status.recording")
            toggleItem.title = L("menu.stopDictation")
        case .transcribing:
            image = Self.symbolImage("waveform")
            description = L("menu.status.transcribing")
            toggleItem.title = L("common.transcribing")
        case .error:
            image = Self.symbolImage("mic.slash")
            description = L("menu.status.error")
            toggleItem.title = L("menu.startDictation")
        }
        image?.accessibilityDescription = description
        statusItem.button?.image = image
    }

    /// Пункт повтора: скрыт без записи в слоте и во время записи/распознавания.
    private func updateRetry(state: DictationController.State, failed: FailedDictation?) {
        let busy = state.isRecording || state == .transcribing
        retryItem.isHidden = failed == nil || busy
        if let failed {
            retryItem.title = L("menu.retryFailed", clockMMSS(failed.audio.duration))
            retryItem.toolTip = failed.message
        }
    }

    private static func symbolImage(_ name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        image?.isTemplate = true
        return image
    }

    /// Template-образ лого-марки для статус-бара: важна только альфа,
    /// наложения лепестков дают слоистость. Рендерится один раз.
    private static let logoTemplateImage: NSImage? = {
        let renderer = ImageRenderer(content: DokaLogoMark(size: 18, tint: .black))
        renderer.scale = 2  // ретина
        guard let cg = renderer.cgImage else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: 18, height: 18))
        image.isTemplate = true
        return image
    }()

    @objc private func toggleDictation() {
        controller.toggle()
    }

    @objc private func pasteLast() {
        controller.pasteLastTranscription()
    }

    @objc private func retryFailed() {
        controller.retryLastFailedDictation()
    }

    @objc private func openMain() {
        WindowManager.shared.showMain(section: .home)
    }

    @objc private func openHistory() {
        WindowManager.shared.showMain(section: .history)
    }
}
