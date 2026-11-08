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
    private let quietItem = NSMenuItem()
    /// «Обновить DOKA до X…»: виден, только когда новая версия готова.
    private let updateItem = NSMenuItem()
    /// «Что нового в X»: рядом с пунктом обновления, если у версии есть заметки.
    private let notesItem = NSMenuItem()
    /// Отделяет пару пунктов обновления от «Открыть DOKA».
    private let updateSeparator = NSMenuItem.separator()
    /// Точка «есть обновление» в углу иконки: окно DOKA почти всегда закрыто,
    /// и без неё новую версию не заметить. Отдельный слой поверх кнопки —
    /// сама иконка остаётся template-образом и следует теме меню-бара.
    private let badgeView = NSView()
    /// Последнее описание состояния диктовки — к нему добавляется «доступно обновление».
    private var statusDescription = ""
    private var showsUpdateBadge = false

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

        // Тихий режим (шёпот): галочка — текущее состояние настройки.
        quietItem.title = L("menu.quietMode")
        quietItem.target = self
        quietItem.action = #selector(toggleQuietMode)
        quietItem.setShortcut(for: .toggleQuietMode)
        menu.addItem(quietItem)

        menu.addItem(.separator())

        // Сочетания задаются в «Клавишах» (setShortcut сам обновляет подпись
        // при переназначении). Прежний декоративный Cmd+, работал только при
        // открытом меню; настроенные здесь — глобальные.
        // Готовое обновление — над «Открыть DOKA», чтобы его было видно сразу.
        updateItem.target = self
        updateItem.action = #selector(installUpdate)
        updateItem.isHidden = true
        menu.addItem(updateItem)
        // «Что нового в X» — заметки, не открывая плашку (её могли скрыть крестиком).
        notesItem.target = self
        notesItem.action = #selector(showReleaseNotes)
        notesItem.isHidden = true
        menu.addItem(notesItem)
        updateSeparator.isHidden = true
        menu.addItem(updateSeparator)

        let openItem = NSMenuItem(title: L("menu.open"), action: #selector(openMain), keyEquivalent: "")
        openItem.target = self
        openItem.setShortcut(for: .openMainWindow)
        menu.addItem(openItem)

        let historyItem = NSMenuItem(title: L("menu.history"), action: #selector(openHistory), keyEquivalent: "")
        historyItem.target = self
        historyItem.setShortcut(for: .openHistoryWindow)
        menu.addItem(historyItem)

        // Ручная проверка — на странице «О DOKA»: там видно и итог, и настройки.
        // У самосборки ленты нет — пункт не нужен.
        if UpdateController.shared.isAvailable {
            let checkItem = NSMenuItem(title: L("menu.checkUpdates"), action: #selector(openAbout),
                                       keyEquivalent: "")
            checkItem.target = self
            menu.addItem(checkItem)
        }

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: L("menu.quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        statusItem.menu = menu
        installBadge()

        controller.$state
            .sink { [weak self] state in self?.update(for: state) }
            .store(in: &cancellables)
        // @Published отдаёт новое значение в sink ещё до присвоения (willSet) —
        // поэтому берём значения из параметров, а не из контроллера.
        Publishers.CombineLatest(controller.$state, controller.$lastFailedDictation)
            .sink { [weak self] state, failed in self?.updateRetry(state: state, failed: failed) }
            .store(in: &cancellables)
        UpdateController.shared.$state
            .sink { [weak self] state in self?.updateUpdateItem(state: state) }
            .store(in: &cancellables)
        SettingsStore.shared.$quietMode
            .sink { [weak self] on in self?.quietItem.state = on ? .on : .off }
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
        case .paused:
            image = Self.symbolImage("pause.fill")
            description = L("recorder.paused")
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
        statusDescription = description
        statusItem.button?.image = image
        applyAccessibilityDescription()
    }

    /// Описание иконки для VoiceOver: состояние диктовки + «доступно обновление».
    private func applyAccessibilityDescription() {
        let text = showsUpdateBadge
            ? statusDescription + ", " + L("menu.status.updateAvailable")
            : statusDescription
        statusItem.button?.image?.accessibilityDescription = text
        statusItem.button?.setAccessibilityLabel(text)
    }

    /// Точка — 6 pt в правом верхнем углу 18-пунктовой лого-марки. Привязка
    /// к центру кнопки, а не к её краям: у меню-бара с вырезом кнопка выше.
    private func installBadge() {
        guard let button = statusItem.button else { return }
        let size: CGFloat = 6
        badgeView.wantsLayer = true
        badgeView.layer?.backgroundColor = NSColor(DS.accent).cgColor
        badgeView.layer?.cornerRadius = size / 2
        badgeView.isHidden = true
        badgeView.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(badgeView)
        NSLayoutConstraint.activate([
            badgeView.widthAnchor.constraint(equalToConstant: size),
            badgeView.heightAnchor.constraint(equalToConstant: size),
            badgeView.centerXAnchor.constraint(equalTo: button.centerXAnchor, constant: 7.5),
            badgeView.centerYAnchor.constraint(equalTo: button.centerYAnchor, constant: -6.5)
        ])
    }

    /// Пункт повтора: скрыт без записи в слоте и во время записи/распознавания.
    private func updateRetry(state: DictationController.State, failed: FailedDictation?) {
        let busy = state.isBusy
        retryItem.isHidden = failed == nil || busy
        if let failed {
            retryItem.title = L("menu.retryFailed", clockMMSS(failed.audio.duration))
            retryItem.toolTip = failed.message
        }
    }

    /// Пункты обновления: только при готовой версии; пока идёт установка или
    /// ожидание покоя — скрыты (нажатие уже было). Точка на иконке — и при
    /// ожидании покоя: обновление ещё не стоит.
    private func updateUpdateItem(state: UpdateState) {
        if case .ready(let info) = state {
            updateItem.title = L("menu.installUpdate", info.version)
            updateItem.isHidden = false
            notesItem.title = L("menu.whatsNew", info.version)
            notesItem.isHidden = info.notes == nil
        } else {
            updateItem.isHidden = true
            notesItem.isHidden = true
        }
        updateSeparator.isHidden = updateItem.isHidden
        showsUpdateBadge = state.showsMenuBarBadge
        badgeView.isHidden = !showsUpdateBadge
        applyAccessibilityDescription()
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

    @objc private func toggleQuietMode() {
        controller.toggleQuietMode()
    }

    @objc private func openMain() {
        WindowManager.shared.showMain(section: .home)
    }

    @objc private func openHistory() {
        WindowManager.shared.showMain(section: .history)
    }

    @objc private func openAbout() {
        WindowManager.shared.showAbout()
    }

    @objc private func installUpdate() {
        UpdateController.shared.installNow()
    }

    /// «Что нового в X»: «О DOKA» и лист заметок поверх (лист — на окне).
    @objc private func showReleaseNotes() {
        WindowManager.shared.showAbout()
        UpdateController.shared.requestNotes()
    }
}
