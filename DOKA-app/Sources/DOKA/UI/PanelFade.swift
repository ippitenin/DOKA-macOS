import AppKit

/// Появление и затухание плавающих окон: панель записи, подсветка краёв
/// «Авроры», зеркало губ. Один экземпляр — на одно окно (или на слот окна,
/// которое пересоздаётся).
///
/// Две ловушки, ради которых это вынесено в одно место:
/// - `NSAnimationContext`, в отличие от SwiftUI, сам НЕ уважает Reduce
///   Motion — длительность умножается на `durationScale`;
/// - завершение затухания приходит позже: если окно за это время показали
///   снова, запоздалый `orderOut` спрятал бы уже нужное окно. Поэтому у
///   затухания поколение, и любой показ его отменяет.
@MainActor
final class PanelFade {
    /// 0 при Reduce Motion — анимации AppKit схлопываются в мгновенные.
    static var durationScale: Double {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 1
    }

    private var generation = 0

    /// Окно снова нужно: запланированный затуханием `orderOut` отменяется.
    func cancelHide() {
        generation += 1
    }

    /// Появление из прозрачности; с `start` — ещё и съезд из этой рамки в
    /// текущую рамку окна.
    func fadeIn(_ window: NSWindow, from start: NSRect? = nil) {
        cancelHide()
        let target = window.frame
        if let start { window.setFrame(start, display: false) }
        window.alphaValue = 0
        window.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = DS.Anim.panelShow * Self.durationScale
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
            if start != nil { window.animator().setFrame(target, display: true) }
        }
    }

    /// Окно уже на экране (возможно, посреди затухания) — вернуть непрозрачность.
    func restore(_ window: NSWindow) {
        cancelHide()
        window.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = DS.Anim.panelShow * Self.durationScale
            window.animator().alphaValue = 1
        }
    }

    /// Затухание (с `target` — ещё и уход рамки в неё), затем `orderOut` и
    /// `completion` — только если окно с тех пор не показали снова.
    func fadeOut(_ window: NSWindow, to target: NSRect? = nil, completion: (@MainActor () -> Void)? = nil) {
        generation += 1
        let token = generation
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = DS.Anim.panelHide * Self.durationScale
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0
            if let target { window.animator().setFrame(target, display: true) }
        }, completionHandler: {
            // Completion приходит на главном потоке, но без изоляции к актору.
            MainActor.assumeIsolated {
                guard token == self.generation else { return }
                window.orderOut(nil)
                window.alphaValue = 1
                completion?()
            }
        })
    }
}
