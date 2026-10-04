import SwiftUI

/// Край плашки, который прирастает к кромке экрана.
enum PlateEdge: Equatable {
    case top
    case bottom
}

/// Плашка, «вытекающая» из кромки экрана: плоский край у кромки с вогнутыми
/// «плечами» (у самого края плашка шире тела и сужается вогнутой дугой),
/// противоположный край скруглён. Общая у notch-плашки панели записи и
/// зеркала губ — прямой угол у кромки читается как приклеенная полоска.
/// Окно под такую плашку шире её тела на `2 × shoulder`.
struct EdgeFlowShape: Shape {
    let flatEdge: PlateEdge
    let shoulder: CGFloat
    let corner: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width, h = rect.height, s = shoulder
        let r = min(corner, (w - 2 * s) / 2, h / 2)
        // Рисуем для плоского верха; для плоского низа отражаем по вертикали.
        path.move(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: w, y: 0))
        path.addQuadCurve(to: CGPoint(x: w - s, y: s), control: CGPoint(x: w - s, y: 0))
        path.addLine(to: CGPoint(x: w - s, y: h - r))
        path.addQuadCurve(to: CGPoint(x: w - s - r, y: h), control: CGPoint(x: w - s, y: h))
        path.addLine(to: CGPoint(x: s + r, y: h))
        path.addQuadCurve(to: CGPoint(x: s, y: h - r), control: CGPoint(x: s, y: h))
        path.addLine(to: CGPoint(x: s, y: s))
        path.addQuadCurve(to: CGPoint(x: 0, y: 0), control: CGPoint(x: s, y: 0))
        path.closeSubpath()
        guard flatEdge == .bottom else { return path.offsetBy(dx: rect.minX, dy: rect.minY) }
        return path.applying(CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: 0, y: -h))
            .offsetBy(dx: rect.minX, dy: rect.minY)
    }
}
