import AppKit
import SwiftUI

/// Плавающая панель записи: поверх всех окон и полноэкранных приложений,
/// не забирает фокус у активного приложения.
final class RecorderPanel: NSPanel {
    init(contentView: NSView, size: CGSize) {
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .floating
        isFloatingPanel = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.contentView = contentView
    }

    // Панель не должна становиться key — фокус остаётся в целевом приложении.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Управляет показом панели записи.
@MainActor
final class RecorderPanelController {
    private var panel: RecorderPanel?
    private var appliedStyle: RecorderStyle?
    private let controller: DictationController
    /// Отменяет orderOut незавершённого скрытия при быстром повторном show().
    private var hideGeneration = 0

    /// Полноэкранная клик-сквозная подсветка краёв — только для стиля
    /// «Аврора» во время записи/распознавания.
    private var glowPanel: RecorderPanel?
    /// Зеркало губ (эксперимент «Губы») — только пока камера снимает дубль.
    private let mirror = LipMirrorController()

    /// NSAnimationContext, в отличие от SwiftUI, сам не уважает Reduce Motion.
    private var animationDurationScale: Double {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 1
    }

    init(controller: DictationController) {
        self.controller = controller
    }

    func show() {
        let style = SettingsStore.shared.recorderStyle
        let screen = Self.screenUnderMouse()

        // «Скрытая»: запись и распознавание идут без панели (статус виден
        // по иконке меню-бара). Ошибки показываем всегда — иначе они
        // станут беззвучно-невидимыми. Зеркало губ при этом показывается:
        // это индикатор камеры, а не панель записи.
        if style == .hidden {
            if case .error = controller.state {
                // показываем панель в классическом виде
            } else {
                hide()
                syncMirror(style: style, screen: screen)
                return
            }
        }

        // Стиль применяется лениво в момент показа: смена настройки
        // не дёргает живую панель во время записи.
        var effective: RecorderStyle = style == .hidden ? .classic : style
        // В капельку («Аврора» и «Мини») текст ошибки не помещается —
        // на ошибке они, как и «Скрытая», падают на классический вид.
        if case .error = controller.state, effective == .aurora || effective == .mini {
            effective = .classic
        }

        // Полноэкранная подсветка краёв: только «Аврора» и только пока идёт
        // запись/распознавание (на ошибке остаётся одна плашка). Показываем
        // ДО плашки, чтобы плашка легла поверх каймы.
        let active: Bool
        switch controller.state {
        case .recording, .transcribing: active = true
        default: active = false
        }
        if effective == .aurora && active {
            presentGlow(on: screen)
        } else {
            dismissGlow()
        }

        // Нотч-панель пересоздаётся на каждом появлении: геометрия выреза
        // зависит от экрана, на котором сейчас курсор.
        let needsRebuild = panel == nil
            || appliedStyle != effective
            || (effective == .notch && panel?.isVisible != true)
        if needsRebuild {
            panel?.orderOut(nil)
            panel = makePanel(style: effective, screen: screen)
            appliedStyle = effective
        }
        guard let panel else { return }
        hideGeneration += 1

        // Позиционируем только при появлении: переходы recording → transcribing →
        // error не должны дёргать панель (например, на другой экран за курсором).
        if !panel.isVisible {
            position(panel, style: effective, screen: screen)
            let target = panel.frame
            var start = target
            // Появление: классика всплывает снизу, нотч выезжает из-под выреза,
            // «Аврора» не съезжает вовсе — её капелька раздувается из точки
            // внутри окна, и сдвиг рамки спорил бы с этим ростом.
            switch effective {
            case .notch: start.origin.y += 8
            case .aurora, .mini: break
            default: start.origin.y -= 10
            }
            panel.setFrame(start, display: false)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = DS.Anim.panelShow * animationDurationScale
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
                panel.animator().setFrame(target, display: true)
            }
        } else {
            // Панель уже на экране (возможно, в середине скрытия) —
            // возвращаем непрозрачность.
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = DS.Anim.panelShow * animationDurationScale
                panel.animator().alphaValue = 1
            }
        }
        syncMirror(style: style, screen: screen)
    }

    /// Зеркало губ — пока идёт запись и камера снимает дубль; размещение —
    /// по настроенному стилю панели (у «Нотча» — свой вариант).
    private func syncMirror(style: RecorderStyle, screen: NSScreen?) {
        if controller.state.isRecording, LipCapture.shared.activeTake != nil {
            mirror.show(style: style, screen: screen)
        } else {
            mirror.dismiss()
        }
    }

    func hide() {
        dismissGlow()
        mirror.dismiss()
        guard let panel, panel.isVisible else { return }
        hideGeneration += 1
        let generation = hideGeneration
        var target = panel.frame
        if appliedStyle == .notch {
            target.origin.y += 8 // нотч втягивается вверх, под вырез
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = DS.Anim.panelHide * animationDurationScale
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
            panel.animator().setFrame(target, display: true)
        }, completionHandler: {
            // Completion приходит на главном потоке, но без изоляции к актору.
            MainActor.assumeIsolated {
                guard generation == self.hideGeneration else { return }
                panel.orderOut(nil)
                panel.alphaValue = 1
            }
        })
    }

    // MARK: - Создание и геометрия

    private func makePanel(style: RecorderStyle, screen: NSScreen?) -> RecorderPanel {
        if style == .notch {
            let geometry = Self.notchGeometry(for: screen)
            let view = NSHostingView(rootView: NotchRecorderView(
                controller: controller,
                notchWidth: geometry.notchWidth,
                size: geometry.size
            ))
            let result = RecorderPanel(contentView: view, size: geometry.size)
            // Поверх менюбара — плашка визуально сливается с вырезом
            // и не таскается мышью (приращена к кромке экрана).
            result.level = .statusBar
            result.isMovableByWindowBackground = false
            return result
        }
        // Капелька: «Аврора» — широкая и с подсветкой краёв, «Мини» — вдвое
        // уже и без неё (подсветку поднимает show(), а не эта фабрика).
        if style == .aurora || style == .mini {
            let geometry: DropGeometry = style == .aurora ? .wide : .compact
            let size = geometry.panel
            let view = NSHostingView(rootView: DropRecorderView(
                controller: controller, size: size, geometry: geometry
            ))
            return RecorderPanel(contentView: view, size: size)
        }
        if style == .studio {
            let size = RecorderView.panelSize(for: .studio)
            let view = NSHostingView(rootView: StudioRecorderView(controller: controller, size: size))
            return RecorderPanel(contentView: view, size: size)
        }
        let view = NSHostingView(rootView: RecorderView(controller: controller, style: style))
        return RecorderPanel(contentView: view, size: RecorderView.panelSize(for: style))
    }

    // MARK: - Полноэкранная подсветка краёв (Аврора)

    /// Показывает (создаёт при необходимости) клик-сквозную панель-кайму
    /// на весь экран под курсором. Не перехватывает мышь и не забирает фокус.
    private func presentGlow(on screen: NSScreen?) {
        guard let screen else { dismissGlow(); return }
        let frame = screen.frame
        if glowPanel == nil {
            let view = NSHostingView(rootView: ScreenGlowView(controller: controller))
            let p = RecorderPanel(contentView: view, size: frame.size)
            p.ignoresMouseEvents = true          // клик-сквозной оверлей
            p.isMovableByWindowBackground = false
            p.level = .floating
            glowPanel = p
        }
        guard let glow = glowPanel else { return }
        glow.setFrame(frame, display: false)     // под текущий экран
        if !glow.isVisible {
            glow.alphaValue = 0
            glow.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = DS.Anim.panelShow * animationDurationScale
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                glow.animator().alphaValue = 1
            }
        }
    }

    private func dismissGlow() {
        guard let glow = glowPanel, glow.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = DS.Anim.panelHide * animationDurationScale
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            glow.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                glow.orderOut(nil)
                glow.alphaValue = 1
            }
        })
    }

    /// Геометрия нотч-панели: вырез + боковые зоны контента;
    /// на экране без выреза — компактная пилюля (notchWidth == 0).
    static func notchGeometry(for screen: NSScreen?) -> (size: CGSize, notchWidth: CGFloat) {
        if let screen,
           screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            let notchWidth = screen.frame.width - left.width - right.width
            // Ровно высота выреза: любая добавка свесит плашку ниже его
            // кромки (на этом маке safeAreaInsets.top = 32, прежние +4
            // читались как «нотч заходит на пару пикселей»).
            let height = max(screen.safeAreaInsets.top, 32)
            let width = notchWidth + NotchRecorderView.sideWidth * 2 + 20
            return (CGSize(width: width, height: height), notchWidth)
        }
        return (CGSize(width: 240, height: 36), 0)
    }

    private static func screenUnderMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
    }

    /// Классика/мини — внизу по центру экрана с курсором;
    /// нотч — вплотную к верхней кромке экрана (отступ 0, с вырезом и без).
    private func position(_ panel: NSPanel, style: RecorderStyle, screen: NSScreen?) {
        guard let screen else { return }
        let size = panel.frame.size
        if style == .notch {
            let frame = screen.frame
            // И с вырезом, и без — плашка прирастает к самой верхней кромке (отступ 0).
            // Уровень .statusBar (см. makePanel) позволяет лечь поверх менюбара.
            panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2,
                                         y: frame.maxY - size.height))
        } else if style == .studio {
            // Студия прижата почти к нижней кромке (над Dock).
            let visible = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(
                x: visible.midX - size.width / 2,
                y: visible.minY + 20
            ))
        } else if style == .aurora || style == .mini {
            // Отступ считается так, чтобы центр капельки остался там же, где
            // была прежняя пилюля: окно выше самой капельки на запас под ореол.
            let visible = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(
                x: visible.midX - size.width / 2,
                y: visible.minY + 80 + (54 - size.height) / 2   // центр капельки — на прежней высоте
            ))
        } else {
            let visible = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(
                x: visible.midX - size.width / 2,
                y: visible.minY + 80
            ))
        }
    }
}
