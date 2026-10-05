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
    /// Показ и затухание плашки: быстрый повторный show() отменяет orderOut
    /// незавершённого скрытия.
    private let fade = PanelFade()

    /// Полноэкранная клик-сквозная подсветка краёв — только для стиля
    /// «Аврора» во время записи/распознавания.
    private var glowPanel: RecorderPanel?
    private let glowFade = PanelFade()
    /// Зеркало губ (эксперимент «Губы») — только пока камера снимает дубль.
    private let mirror = LipMirrorController()

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

        // Позиционируем только при появлении: переходы recording → transcribing →
        // error не должны дёргать панель (например, на другой экран за курсором).
        if !panel.isVisible {
            position(panel, style: effective, screen: screen)
            var start = panel.frame
            // Появление: классика всплывает снизу, нотч выезжает из-под выреза,
            // «Аврора» не съезжает вовсе — её капелька раздувается из точки
            // внутри окна, и сдвиг рамки спорил бы с этим ростом.
            switch effective {
            case .notch: start.origin.y += 8
            case .aurora, .mini: break
            default: start.origin.y -= 10
            }
            fade.fadeIn(panel, from: start)
        } else {
            // Панель уже на экране (возможно, в середине скрытия) —
            // возвращаем непрозрачность.
            fade.restore(panel)
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
        var target = panel.frame
        if appliedStyle == .notch {
            target.origin.y += 8 // нотч втягивается вверх, под вырез
        }
        fade.fadeOut(panel, to: target)
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
            glowFade.fadeIn(glow)
        } else {
            // Видима, но, возможно, гаснет: новая запись началась раньше,
            // чем кончилось затухание прошлой, — иначе запоздалый orderOut
            // оставил бы запись без подсветки.
            glowFade.restore(glow)
        }
    }

    private func dismissGlow() {
        guard let glow = glowPanel, glow.isVisible else { return }
        glowFade.fadeOut(glow)
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
            // Плюс два плеча: плашка вытекает из кромки вогнутыми дугами
            // (`EdgeFlowShape`), и они выступают за тело плашки.
            let width = notchWidth + NotchRecorderView.sideWidth * 2 + 20 + 2 * DS.EdgePlate.shoulder
            return (CGSize(width: width, height: height), notchWidth)
        }
        return (CGSize(width: 240 + 2 * DS.EdgePlate.shoulder, height: 36), 0)
    }

    /// Рамка notch-плашки: по центру экрана, вплотную к самой верхней кромке
    /// (отступ 0) — и с вырезом, и без. Общая с зеркалом губ, которое у
    /// «Нотча» продолжает плашку.
    static func notchFrame(size: CGSize, on screen: NSScreen) -> CGRect {
        let frame = screen.frame
        return CGRect(x: frame.midX - size.width / 2, y: frame.maxY - size.height,
                      width: size.width, height: size.height)
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
            // Уровень .statusBar (см. makePanel) позволяет лечь поверх менюбара.
            panel.setFrameOrigin(Self.notchFrame(size: size, on: screen).origin)
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
