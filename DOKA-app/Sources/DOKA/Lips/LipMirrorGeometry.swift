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

    /// Сцена: наибольший прямоугольник с аспектом окна (`aspect` — высота к
    /// ширине) по центру кадра камеры.
    static func sceneRegion(camera: CGSize, aspect: CGFloat) -> CGRect {
        var width = camera.width
        var height = width * aspect
        if height > camera.height {
            height = camera.height
            width = height / aspect
        }
        return CGRect(x: (camera.width - width) / 2, y: (camera.height - height) / 2,
                      width: width, height: height)
    }

    /// Точка кадра камеры в картинке размера `size`, показывающей `region`.
    /// Начало сверху слева у обоих; `size` — в любых единицах (пиксели
    /// картинки или точки маски). `mirrored` — картинка отражена.
    static func map(_ p: CGPoint, region: CGRect, size: CGSize, mirrored: Bool) -> CGPoint {
        let sx = size.width / region.width, sy = size.height / region.height
        let x = mirrored ? region.maxX - p.x : p.x - region.minX
        return CGPoint(x: x * sx, y: (p.y - region.minY) * sy)
    }

    /// То же, что `map`, одним аффинным преобразованием для `CIImage` (начало
    /// снизу слева у кадра и у картинки): переворот y, отражение и масштаб.
    static func ciTransform(region: CGRect, camera: CGSize, size: CGSize, mirrored: Bool) -> CGAffineTransform {
        let sx = size.width / region.width, sy = size.height / region.height
        return CGAffineTransform(a: mirrored ? -sx : sx, b: 0, c: 0, d: sy,
                                 tx: mirrored ? sx * region.maxX : -sx * region.minX,
                                 ty: -sy * (camera.height - region.maxY))
    }
}
