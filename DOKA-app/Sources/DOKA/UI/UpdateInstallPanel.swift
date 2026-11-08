import AppKit
import SwiftUI

/// Окно «Обновление DOKA» на время установки — как у Telegram: главное окно
/// ушло, по центру экрана плавно ползёт полоса, затем DOKA перезапускается
/// новой. Borderless-панель с материалом (`forceMaterial`: Liquid Glass в
/// borderless-окнах ведёт себя плохо — `UI/CLAUDE.md`), тень даёт само окно,
/// а не `.shadow` на корне (квадратная граница окна обрезала бы её).
/// Показ и затухание — через `PanelFade`.
@MainActor
final class UpdateInstallPanelController {
    static let shared = UpdateInstallPanelController()

    private var panel: NSPanel?
    private let fade = PanelFade()

    var isVisible: Bool { panel?.isVisible ?? false }

    func show(updates: UpdateController) {
        let panel = self.panel ?? makePanel(updates: updates)
        self.panel = panel
        let screen = NSScreen.main ?? NSScreen.screens.first
        if let visible = screen?.visibleFrame {
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2,
                                         y: visible.midY - size.height / 2 + visible.height * 0.08))
        }
        fade.fadeIn(panel)
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        fade.fadeOut(panel)
    }

    private func makePanel(updates: UpdateController) -> NSPanel {
        let hosting = NSHostingView(rootView: UpdateInstallView(updates: updates))
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.contentView = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        return panel
    }
}

/// Содержимое окна установки: настоящий логотип, что происходит и полоса.
private struct UpdateInstallView: View {
    @ObservedObject var updates: UpdateController

    private var subtitle: String {
        if case .downloading = updates.state { return L("update.panel.downloading") }
        return L("update.panel.installing", updates.state.info?.version ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                DokaBrandLogo(size: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("update.panel.title"))
                        .font(.headline)
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .contentTransition(.opacity)
                        .animation(DS.Anim.section, value: subtitle)
                }
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 7) {
                SmoothProgressBar(value: updates.installProgress)
                Text(L("update.panel.relaunch"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(width: 360)
        .glassSurface(radius: DS.Radius.card, forceMaterial: true)
    }
}

/// Полоса, которую SwiftUI анимирует плавно: системный `ProgressView` на
/// macOS — это NSProgressIndicator, и значение в нём прыгает, а не ползёт.
private struct SmoothProgressBar: View {
    let value: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.10))
                Capsule()
                    .fill(LinearGradient(colors: [DS.accent.opacity(0.85), DS.accent],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(6, geo.size.width * min(max(value, 0), 1)))
            }
        }
        .frame(height: 6)
    }
}
