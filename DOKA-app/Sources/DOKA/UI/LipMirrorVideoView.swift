import AppKit
import Combine
import QuartzCore
import SwiftUI

/// Живой кадр рта в зеркале: картинка и маска-сетка губ ОДНОГО кадра камеры,
/// готовые на `visionQueue` (`LipMirrorFeed`). Здесь они только
/// присваиваются слоям — одной транзакцией без анимаций, поэтому видео и
/// маска меняются одновременно. SwiftUI в этом не участвует.
struct LipMirrorVideoView: NSViewRepresentable {
    let size: CGSize
    let reduceMotion: Bool

    func makeNSView(context: Context) -> LipMirrorVideoNSView {
        LipMirrorVideoNSView(frame: CGRect(origin: .zero, size: size), reduceMotion: reduceMotion)
    }

    func updateNSView(_ nsView: LipMirrorVideoNSView, context: Context) {
        nsView.reduceMotion = reduceMotion
    }
}

@MainActor
final class LipMirrorVideoNSView: NSView {
    private let container = CALayer()
    /// Картинка кадра. Ориентация `CGImage` в `contents` от переворота
    /// контейнера не зависит (CALayer.h) — верх картинки остаётся сверху.
    private let picture = CALayer()
    private let mask = LipMeshOverlay()
    /// Подписка на ящик кадров; nil — окна нет.
    private var owner: UUID?
    private var phase: LipMirrorPhase = .idle
    private var phaseSubscription: AnyCancellable?

    var reduceMotion: Bool {
        didSet { if reduceMotion != oldValue { updateTarget() } }
    }

    init(frame: CGRect, reduceMotion: Bool) {
        self.reduceMotion = reduceMotion
        super.init(frame: frame)
        // Слой-хост: свой корень до `wantsLayer`.
        let root = CALayer()
        root.backgroundColor = NSColor.black.cgColor
        layer = root
        wantsLayer = true
        // Слои маски ложатся на видео фильтром компоновки (`LipMeshOverlay`).
        // NSView.h просит этот флаг для CIFilter в поддереве; строковому
        // фильтру Core Animation он не нужен — держим как страховку.
        layerUsesCoreImageFilters = true

        container.frame = CGRect(origin: .zero, size: frame.size)
        container.masksToBounds = true
        // Координаты сверху слева — как у путей маски.
        container.isGeometryFlipped = true
        root.addSublayer(container)

        picture.contentsGravity = .resize
        picture.frame = container.bounds
        container.insertSublayer(picture, at: 0)
        mask.install(in: container)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { attach() } else { detach() }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        relayout()
    }

    override func layout() {
        super.layout()
        relayout()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        relayout()
    }

    private func attach() {
        guard owner == nil else { return }
        relayout()
        let capture = LipCapture.shared
        phase = capture.phase
        owner = capture.mirrorFeed.attach(target: target) { [weak self] frame in self?.show(frame) }
        // Лицо пропало или камера встала — маску прячем сразу: новых кадров
        // может и не прийти. @Published отдаёт значение до записи в свойство.
        phaseSubscription = capture.$phase.sink { [weak self] phase in
            guard let self else { return }
            self.phase = phase
            if phase != .face { self.mask.apply(nil) }
        }
    }

    private func detach() {
        if let owner { LipCapture.shared.mirrorFeed.detach(owner: owner) }
        owner = nil
        phaseSubscription = nil
    }

    private var target: LipMirrorTarget {
        LipMirrorTarget(size: bounds.size, scale: window?.backingScaleFactor ?? 2, reduceMotion: reduceMotion)
    }

    /// Рамки и масштаб слоёв под окно, затем новый размер — в ящик: кадры под
    /// старый размер он дальше не отдаст.
    private func relayout() {
        let scale = window?.backingScaleFactor ?? 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.frame = bounds
        container.contentsScale = scale
        picture.frame = container.bounds
        picture.contentsScale = scale
        mask.setScale(scale)
        CATransaction.commit()
        updateTarget()
    }

    private func updateTarget() {
        guard let owner else { return }
        LipCapture.shared.mirrorFeed.update(target: target, owner: owner)
    }

    /// nil — «пусто» (начался новый дубль): ни картинки, ни маски.
    private func show(_ frame: LipMirrorFrame?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        picture.contents = frame?.image
        mask.apply(phase == .face ? frame?.paths : nil)
        CATransaction.commit()
    }
}
