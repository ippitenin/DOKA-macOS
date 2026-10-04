import CoreGraphics
import Foundation

/// Вариант зеркала при стиле панели «Вырез»: оба на пробу (решение владельца).
enum LipMirrorNotchVariant: String, CaseIterable {
    /// Зеркало продолжает notch-плашку вниз.
    case continuation
    /// «Нижний вырез»: плашка всплывает от нижнего края экрана.
    case bottom

    var title: String {
        switch self {
        case .continuation: return L("lips.mirror.variant.continuation")
        case .bottom: return L("lips.mirror.variant.bottom")
        }
    }
}

/// Где показывается зеркало губ.
enum LipMirrorPlacement: Equatable {
    /// Сверху, из выреза (при нижних стилях панели и при «Скрытой»).
    case topNotch
    /// Под notch-плашкой, как её продолжение.
    case belowNotchPanel
    /// От нижнего края экрана.
    case bottomEdge

    /// Нижние стили — зеркало сверху: панель записи внизу, им не тесно.
    static func resolve(style: RecorderStyle, variant: LipMirrorNotchVariant) -> LipMirrorPlacement {
        guard style == .notch else { return .topNotch }
        return variant == .continuation ? .belowNotchPanel : .bottomEdge
    }
}

struct LipMirrorLayout: Equatable {
    /// Рамка окна в координатах экрана (AppKit: начало снизу слева).
    let frame: CGRect
    /// Кадр видео внутри окна (SwiftUI: начало сверху слева).
    let video: CGRect
    let flatEdge: PlateEdge
}

/// Чистая геометрия зеркала губ.
enum LipMirrorGeometry {
    static let videoSize = CGSize(width: 224, height: 120)
    /// Вогнутые «плечи» у края экрана: плашка вытекает из кромки, а не
    /// приклеена к ней прямым углом.
    static let shoulder: CGFloat = DS.EdgePlate.shoulder
    /// Скругление противоположного края.
    static let corner: CGFloat = 22
    static let padding: CGFloat = 12
    /// Зазор между вырезом и видео: физический вырез не должен закрывать кадр.
    static let gapBelowNotch: CGFloat = 6
    /// Насколько плашка заходит под notch-плашку: чёрное по чёрному, без шва.
    static let overlap: CGFloat = 2

    static func layout(_ placement: LipMirrorPlacement, screen: CGRect, safeTop: CGFloat,
                       notchWidth: CGFloat, notchPanel: CGRect?) -> LipMirrorLayout {
        let minBody = videoSize.width + 2 * padding
        switch placement {
        case .topNotch:
            let body = max(notchWidth + 40, minBody)
            let width = body + 2 * shoulder
            let top = max(safeTop, 0) + gapBelowNotch
            let height = top + videoSize.height + padding
            let frame = CGRect(x: screen.midX - width / 2, y: screen.maxY - height, width: width, height: height)
            let video = CGRect(x: (width - videoSize.width) / 2, y: top,
                               width: videoSize.width, height: videoSize.height)
            return LipMirrorLayout(frame: frame, video: video, flatEdge: .top)

        case .belowNotchPanel:
            guard let panel = notchPanel else {
                return layout(.topNotch, screen: screen, safeTop: safeTop, notchWidth: notchWidth, notchPanel: nil)
            }
            // Уже notch-плашки на её скругления, чтобы плечи легли на ровный низ.
            let body = min(minBody, panel.width - 2 * shoulder - 8)
            let videoWidth = body - 2 * padding
            let videoHeight = (videoWidth * videoSize.height / videoSize.width).rounded()
            let width = body + 2 * shoulder
            let top = overlap + 8
            let height = top + videoHeight + padding
            let frame = CGRect(x: panel.midX - width / 2, y: panel.minY + overlap - height,
                               width: width, height: height)
            let video = CGRect(x: (width - videoWidth) / 2, y: top, width: videoWidth, height: videoHeight)
            return LipMirrorLayout(frame: frame, video: video, flatEdge: .top)

        case .bottomEdge:
            let width = minBody + 2 * shoulder
            let height = padding + videoSize.height + gapBelowNotch
            let frame = CGRect(x: screen.midX - width / 2, y: screen.minY, width: width, height: height)
            let video = CGRect(x: (width - videoSize.width) / 2, y: padding,
                               width: videoSize.width, height: videoSize.height)
            return LipMirrorLayout(frame: frame, video: video, flatEdge: .bottom)
        }
    }

    /// Во сколько раз область вокруг рта шире самого рта.
    static let zoom: CGFloat = 2.2

    /// Рамка слоя превью (весь кадр камеры) внутри контейнера видео так,
    /// чтобы рот оказался в центре и занимал 1/`zoom` ширины. Координаты —
    /// сверху слева. `mirrored` — картинка отражена (зеркало).
    static func previewFrame(mouth: CGRect, camera: CGSize, container: CGSize, mirrored: Bool) -> CGRect {
        let aspect = container.height / container.width
        var regionWidth = mouth.width * zoom
        if regionWidth * aspect < mouth.height * 1.8 {
            regionWidth = mouth.height * 1.8 / aspect
        }
        let scale = container.width / max(regionWidth, 1)
        let size = CGSize(width: camera.width * scale, height: camera.height * scale)
        let centerX = mirrored ? camera.width - mouth.midX : mouth.midX
        return CGRect(x: container.width / 2 - centerX * scale,
                      y: container.height / 2 - mouth.midY * scale,
                      width: size.width, height: size.height)
    }

    /// Весь кадр камеры, заполняющий контейнер (лица нет — показываем сцену).
    static func fillFrame(camera: CGSize, container: CGSize) -> CGRect {
        let scale = max(container.width / camera.width, container.height / camera.height)
        let size = CGSize(width: camera.width * scale, height: camera.height * scale)
        return CGRect(x: (container.width - size.width) / 2, y: (container.height - size.height) / 2,
                      width: size.width, height: size.height)
    }
}

/// Сглаживание бокса рта для зеркала: экспоненциальное среднее и мёртвая
/// зона — кадр не дрожит за каждым пикселем бокса, но плавно догоняет
/// поворот головы.
struct LipMirrorSmoother {
    static let response: CGFloat = 0.25
    /// Доля ширины рта, меньше которой сдвиг не считается движением.
    static let deadZone: CGFloat = 0.02

    private(set) var current: CGRect?

    /// nil — лица нет: прежнее положение сохраняется.
    mutating func update(_ rect: CGRect?) -> CGRect? {
        guard let rect else { return nil }
        guard let previous = current else {
            current = rect
            return rect
        }
        let threshold = previous.width * Self.deadZone
        let moved = abs(rect.midX - previous.midX) > threshold
            || abs(rect.midY - previous.midY) > threshold
            || abs(rect.width - previous.width) > threshold
        guard moved else { return previous }
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * Self.response }
        let width = mix(previous.width, rect.width)
        let height = mix(previous.height, rect.height)
        let next = CGRect(x: mix(previous.midX, rect.midX) - width / 2,
                          y: mix(previous.midY, rect.midY) - height / 2,
                          width: width, height: height)
        current = next
        return next
    }

    mutating func reset() { current = nil }
}
