import AppKit
import AVFoundation
import QuartzCore
import SwiftUI

/// Живой кадр рта в зеркале: общий слой превью камеры, растянутый так, что
/// рот всегда в центре (кадр следует за лицом), и контур губ поверх.
/// Слоями двигаем сами на каждом результате трекера — SwiftUI в этом не
/// участвует (15 перерисовок в секунду ему не нужны).
struct LipMirrorVideoView: NSViewRepresentable {
    let size: CGSize

    func makeNSView(context: Context) -> LipMirrorVideoNSView {
        LipMirrorVideoNSView(frame: CGRect(origin: .zero, size: size))
    }

    func updateNSView(_ nsView: LipMirrorVideoNSView, context: Context) {}
}

final class LipMirrorVideoNSView: NSView {
    private let container = CALayer()
    private let contour = CAShapeLayer()
    private let dots = CAShapeLayer()
    private var smoother = LipMirrorSmoother()
    private weak var preview: AVCaptureVideoPreviewLayer?
    /// Последний известный размер кадра камеры.
    private var cameraSize = CGSize(width: 1280, height: 720)

    override init(frame: CGRect) {
        super.init(frame: frame)
        let root = CALayer()
        root.backgroundColor = NSColor.black.cgColor
        layer = root
        wantsLayer = true

        container.frame = CGRect(origin: .zero, size: frame.size)
        container.masksToBounds = true
        // Координаты сверху слева — как у боксов трекера.
        container.isGeometryFlipped = true
        root.addSublayer(container)

        contour.fillColor = nil
        contour.strokeColor = NSColor(DS.Lips.contour).cgColor
        contour.lineWidth = 1.2
        contour.lineJoin = .round
        contour.shadowColor = NSColor(DS.Lips.contour).cgColor
        contour.shadowRadius = 4
        contour.shadowOpacity = 0.9
        contour.shadowOffset = .zero
        dots.fillColor = NSColor(DS.Lips.dot).cgColor
        dots.strokeColor = nil
        container.addSublayer(contour)
        container.addSublayer(dots)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        MainActor.assumeIsolated {
            if window != nil { attach() } else { detach() }
        }
    }

    @MainActor
    private func attach() {
        let capture = LipCapture.shared
        guard let preview = capture.previewLayer else { return }
        preview.removeFromSuperlayer()
        // Зеркало — отражение по горизонтали; в файл кадр идёт как есть.
        preview.transform = CATransform3DMakeScale(-1, 1, 1)
        container.insertSublayer(preview, at: 0)
        self.preview = preview
        place(preview: LipMirrorGeometry.fillFrame(camera: cameraSize, container: container.bounds.size))
        smoother.reset()
        capture.onMouth = { [weak self] sample, size in self?.update(sample, cameraSize: size) }
    }

    @MainActor
    private func detach() {
        if preview?.superlayer === container { preview?.removeFromSuperlayer() }
        preview = nil
        LipCapture.shared.onMouth = nil
    }

    private func update(_ sample: LipFaceSample, cameraSize: CGSize) {
        self.cameraSize = cameraSize
        let bounds = container.bounds.size
        let mouth = smoother.update(sample.mouthRect)
        CATransaction.begin()
        CATransaction.setAnimationDuration(1.0 / 15)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .linear))
        if let mouth {
            let frame = LipMirrorGeometry.previewFrame(mouth: mouth, camera: cameraSize, container: bounds,
                                                       mirrored: true)
            place(preview: frame)
            drawContour(sample, frame: frame)
        } else if sample.box == nil {
            // Лица нет — показываем всю сцену, контур прячем.
            smoother.reset()
            place(preview: LipMirrorGeometry.fillFrame(camera: cameraSize, container: bounds))
            contour.path = nil
            dots.path = nil
        }
        CATransaction.commit()
    }

    /// При отражающем трансформе `frame` задавать нельзя — только границы и центр.
    private func place(preview frame: CGRect) {
        guard let preview else { return }
        preview.bounds = CGRect(origin: .zero, size: frame.size)
        preview.position = CGPoint(x: frame.midX, y: frame.midY)
    }

    private func drawContour(_ sample: LipFaceSample, frame: CGRect) {
        let scale = frame.width / max(cameraSize.width, 1)
        func map(_ p: CGPoint) -> CGPoint {
            CGPoint(x: frame.minX + (cameraSize.width - p.x) * scale, y: frame.minY + p.y * scale)
        }
        let path = CGMutablePath()
        for points in [sample.outerLips, sample.innerLips] where points.count > 2 {
            path.addLines(between: points.map(map))
            path.closeSubpath()
        }
        contour.path = path
        let dotPath = CGMutablePath()
        for p in sample.outerLips.map(map) {
            dotPath.addEllipse(in: CGRect(x: p.x - 1.6, y: p.y - 1.6, width: 3.2, height: 3.2))
        }
        dots.path = dotPath
    }
}
