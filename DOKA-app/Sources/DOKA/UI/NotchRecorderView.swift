import SwiftUI

/// Нотч-рекордер: чёрная плашка, прирастающая к вырезу камеры MacBook.
/// Контент раскладывается по бокам выреза; на экранах без выреза —
/// компактная чёрная пилюля под менюбаром (notchWidth == 0).
/// Фон намеренно чисто чёрный (сливается с корпусом камеры), не стекло.
struct NotchRecorderView: View {
    @ObservedObject var controller: DictationController
    /// Ширина аппаратного выреза; 0 — эмуляция на экране без выреза.
    let notchWidth: CGFloat
    /// Полный размер панели (считает RecorderPanelController).
    let size: CGSize

    /// Плашка развёрнута (spring-анимация от ширины выреза).
    @State private var expanded = false
    /// EMA-сглаженный уровень микрофона.
    @State private var smoothedLevel: Float = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var hasNotch: Bool { notchWidth > 0 }

    /// Ширина боковой зоны контента (слева и справа от выреза).
    static let sideWidth: CGFloat = 120
    /// Плечи у кромки экрана — за пределами тела плашки.
    private let shoulder = DS.EdgePlate.shoulder
    /// Тело плашки (без плеч) — по нему раскладывается контент.
    private var bodyWidth: CGFloat { size.width - 2 * shoulder }

    var body: some View {
        ZStack(alignment: .top) {
            shape
                .fill(.black)
                .frame(width: expanded ? size.width : collapsedWidth,
                       height: size.height)

            content
                .frame(width: bodyWidth, height: size.height)
                .opacity(expanded ? 1 : 0)
                // Каскад: контент догоняет плашку с небольшой задержкой.
                .animation(
                    reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.80).delay(0.09),
                    value: expanded
                )
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .onAppear {
            if reduceMotion {
                expanded = true
            } else {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.80)) {
                    expanded = true
                }
            }
        }
        .onChange(of: controller.audioLevel) { _, level in
            smoothedLevel = smoothedLevel.envelope(toward: level)
        }
    }

    /// В свёрнутом виде плашка прячется за вырезом (или ужимается в точку);
    /// плечи остаются по бокам и раскрываются вместе с ней.
    private var collapsedWidth: CGFloat {
        (hasNotch ? notchWidth : 60) + 2 * shoulder
    }

    /// Верх плоский и вытекает из кромки экрана вогнутыми плечами, низ
    /// скруглён — и у выреза, и в эмуляции на экране без выреза. Та же форма,
    /// что у зеркала губ.
    private var shape: EdgeFlowShape {
        EdgeFlowShape(flatEdge: .top, shoulder: shoulder, corner: 14)
    }

    /// Контент по бокам выреза; в эмуляции — одной строкой по центру.
    @ViewBuilder
    private var content: some View {
        if hasNotch {
            HStack(spacing: 0) {
                leftContent
                    .frame(width: Self.sideWidth)
                Spacer(minLength: notchWidth)
                rightContent
                    .frame(width: Self.sideWidth)
            }
            .padding(.horizontal, 10)
        } else {
            HStack(spacing: 8) {
                leftContent
                rightContent
            }
            .padding(.horizontal, 14)
        }
    }

    @ViewBuilder
    private var leftContent: some View {
        switch controller.state {
        case .recording:
            HStack(spacing: 7) {
                RecordingDot(diameter: 7)
                WaveformBars(level: smoothedLevel, tint: DS.RecorderTone.recording,
                             barCount: 9, maxHeight: barMaxHeight)
            }
        case .transcribing:
            WaveformBars(level: 0.35, tint: DS.RecorderTone.transcribing,
                         barCount: 9, maxHeight: barMaxHeight)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(DS.RecorderTone.error)
        case .idle:
            EmptyView()
        }
    }

    @ViewBuilder
    private var rightContent: some View {
        switch controller.state {
        case .recording(let startedAt):
            TimerText(startedAt: startedAt, color: .white.opacity(0.85))
        case .transcribing:
            Text(L("common.transcribing"))
                .font(.caption)
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
        case .error(let message):
            Text(message)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        case .idle:
            EmptyView()
        }
    }

    /// Высота волны ограничена высотой плашки.
    private var barMaxHeight: CGFloat {
        max(10, size.height - 18)
    }
}
