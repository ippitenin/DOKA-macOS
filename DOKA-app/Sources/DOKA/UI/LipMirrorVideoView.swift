import AppKit
import AVFoundation
import QuartzCore
import SwiftUI

/// Живой кадр рта в зеркале: общий слой превью камеры, растянутый так, что
/// рот всегда в центре (кадр следует за лицом), и маска-сетка губ поверх.
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
    private let mask = LipMeshOverlay()
    private var smoother = LipMirrorSmoother()
    private var meshSmoother = LipMeshSmoother()
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

        mask.install(in: container)
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
        // Если соединение превью уже отражает картинку само (автоматическое
        // зеркалирование не успели выключить), второй раз не отражаем —
        // иначе контур губ лёг бы на отражённое дважды лицо.
        let alreadyMirrored = preview.connection?.isVideoMirrored ?? false
        preview.transform = alreadyMirrored ? CATransform3DIdentity : CATransform3DMakeScale(-1, 1, 1)
        container.insertSublayer(preview, at: 0)
        self.preview = preview
        place(preview: LipMirrorGeometry.fillFrame(camera: cameraSize, container: container.bounds.size))
        smoother.reset()
        meshSmoother.reset()
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
            drawMask(sample, frame: frame)
        } else if sample.box == nil {
            // Лица нет — показываем всю сцену, маску прячем.
            smoother.reset()
            meshSmoother.reset()
            place(preview: LipMirrorGeometry.fillFrame(camera: cameraSize, container: bounds))
            mask.apply(nil)
        }
        CATransaction.commit()
    }

    /// При отражающем трансформе `frame` задавать нельзя — только границы и центр.
    private func place(preview frame: CGRect) {
        guard let preview else { return }
        preview.bounds = CGRect(origin: .zero, size: frame.size)
        preview.position = CGPoint(x: frame.midX, y: frame.midY)
    }

    /// Губы не сложились в сетку (нет внутреннего контура) — остаётся прежняя маска.
    private func drawMask(_ sample: LipFaceSample, frame: CGRect) {
        guard let raw = LipMesh.make(outer: sample.outerLips, inner: sample.innerLips) else { return }
        let lips = meshSmoother.update(raw)
        let scale = frame.width / max(cameraSize.width, 1)
        let width = cameraSize.width
        mask.apply(LipMeshPaths.make(lips) { p in
            CGPoint(x: frame.minX + (width - p.x) * scale, y: frame.minY + p.y * scale)
        })
    }
}
