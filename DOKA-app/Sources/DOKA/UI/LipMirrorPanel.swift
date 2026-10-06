import AppKit
import SwiftUI

/// Окно зеркала губ: чёрная плашка, «вытекающая» из выреза экрана (или из
/// нижней кромки), с живым кадром рта. Показывается только пока камера
/// снимает дубль; клики проходят насквозь, фокус не забирает, в демонстрацию
/// экрана не попадает.
@MainActor
final class LipMirrorController {
    private var panel: RecorderPanel?
    private let fade = PanelFade()

    func show(style: RecorderStyle, screen: NSScreen?) {
        guard let screen else { return }
        let placement = LipMirrorPlacement.resolve(style: style,
                                                   variant: SettingsStore.shared.lipsMirrorNotchVariant)
        let notch = RecorderPanelController.notchGeometry(for: screen)
        let notchPanel = style == .notch ? RecorderPanelController.notchFrame(size: notch.size, on: screen) : nil
        let layout = LipMirrorGeometry.layout(placement, screen: screen.frame, safeTop: screen.safeAreaInsets.top,
                                              notchWidth: notch.notchWidth, notchPanel: notchPanel)
        if let panel, panel.isVisible, panel.frame == layout.frame {
            // Возможно, идёт анимация затухания: прямое присваивание она бы
            // перетёрла и довела альфу до нуля — перебиваем её своей анимацией.
            fade.restore(panel)
            return
        }
        fade.cancelHide()
        // Вью пересоздаётся на каждом показе — так плашка каждый раз заново
        // вытекает из края экрана.
        let view = NSHostingView(rootView: LipMirrorView(layout: layout))
        let window = panel ?? Self.makePanel(view: view, size: layout.frame.size)
        window.contentView = view
        window.setFrame(layout.frame, display: false)
        window.alphaValue = 1
        window.orderFrontRegardless()
        panel = window
    }

    func dismiss() {
        guard let panel, panel.isVisible else { return }
        fade.fadeOut(panel) {
            // Вью зеркала уходит из окна и отписывается от ящика кадров:
            // невидимое окно не должно заставлять движок рендерить.
            panel.contentView = nil
        }
    }

    private static func makePanel(view: NSView, size: CGSize) -> RecorderPanel {
        let panel = RecorderPanel(contentView: view, size: size)
        // Поверх менюбара: плашка прирастает к вырезу и к кромке экрана.
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.isMovableByWindowBackground = false
        panel.sharingType = .none
        return panel
    }
}

/// Содержимое окна зеркала.
struct LipMirrorView: View {
    let layout: LipMirrorLayout
    @ObservedObject private var capture = LipCapture.shared
    @State private var revealed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var size: CGSize { layout.frame.size }
    /// Свёрнутая плашка — тонкая полоска у края экрана.
    private var collapsedHeight: CGFloat { LipMirrorGeometry.shoulder + 2 }

    var body: some View {
        ZStack(alignment: layout.flatEdge == .top ? .top : .bottom) {
            EdgeFlowShape(flatEdge: layout.flatEdge, shoulder: LipMirrorGeometry.shoulder,
                          corner: LipMirrorGeometry.corner)
                .fill(.black)
                .frame(width: size.width, height: revealed ? size.height : collapsedHeight)
        }
        .frame(width: size.width, height: size.height, alignment: layout.flatEdge == .top ? .top : .bottom)
        .overlay(alignment: .topLeading) {
            video
                .frame(width: layout.video.width, height: layout.video.height)
                .offset(x: layout.video.minX, y: layout.video.minY)
                .opacity(revealed ? 1 : 0)
                // Видео догоняет плашку с небольшой задержкой — как контент нотча.
                .animation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.80).delay(0.09),
                           value: revealed)
        }
        .onAppear {
            if reduceMotion {
                revealed = true
            } else {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.80)) { revealed = true }
            }
        }
    }

    private var video: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return ZStack {
            LipMirrorVideoView(size: layout.video.size, reduceMotion: reduceMotion)
            if capture.phase != .face {
                Color.black.opacity(capture.phase == .noLips ? 0.55 : 0.75)
                if let caption {
                    Text(caption)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(DS.Lips.caption)
                }
            }
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(DS.Lips.rim, lineWidth: 0.5))
        .animation(reduceMotion ? nil : DS.Anim.control, value: capture.phase)
    }

    private var caption: String? {
        switch capture.phase {
        case .warming, .idle: return L("lips.mirror.warming")
        case .noLips: return L("lips.mirror.noLips")
        case .unavailable: return L("lips.mirror.unavailable")
        case .face: return nil
        }
    }
}
