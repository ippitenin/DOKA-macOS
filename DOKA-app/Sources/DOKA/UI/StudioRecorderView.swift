import AppKit
import SwiftUI

/// Стиль панели записи «Студия»: компактная стеклянная плашка внизу экрана с
/// яркой звуковой волной-спектром — десятки светящихся столбиков с
/// колоколообразной огибающей (ярче/выше в центре, кончики затухают), которые
/// сильно реагируют на уровень микрофона. По центру — крупный тикающий таймер,
/// под ним подсказка «Esc — отмена». Подложка — адаптивное «стекло» (Liquid
/// Glass / материал, `glassSurface`), волна — в фирменном персике DOKA.
struct StudioRecorderView: View {
    @ObservedObject var controller: DictationController
    let size: CGSize

    /// EMA-сглаженный уровень микрофона — волна дышит плавно, но отзывчиво.
    @State private var smoothedLevel: Float = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        content
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            // Как у классической панели: на macOS 26 — настоящий Liquid Glass,
            // на 15 — материал со светящейся кромкой. Внешних теней нет
            // намеренно: окно панели размером ровно с плашку, тень обрезалась
            // бы его квадратной границей — тёмные углы в светлой теме.
            .glassSurface(radius: 22)
            .onChange(of: controller.audioLevel) { _, level in
                // Огибающая: резкий отклик на голос, мягкое затухание.
                smoothedLevel = smoothedLevel.envelope(toward: level)
            }
            .onChange(of: isRecording) { _, recording in
                if !recording { smoothedLevel = 0 }
            }
    }

    private var isRecording: Bool {
        if case .recording = controller.state { return true }
        return false
    }

    /// Контент по состояниям. Волна — фон на всю ширину; таймер и подпись esc —
    /// по центру поверх неё (с лёгким затемнением для читаемости).
    @ViewBuilder private var content: some View {
        switch controller.state {
        case .recording(let startedAt):
            ZStack {
                StudioWave(level: smoothedLevel, tint: DS.RecorderTone.recording)
                centerLabel {
                    TimerText(
                        startedAt: startedAt,
                        color: .primary,
                        font: .system(size: 26, weight: .medium, design: .monospaced)
                    )
                    .shadow(color: DS.glow.opacity(0.45), radius: 8)
                    Text(L("recorder.escHint"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        case .transcribing:
            ZStack {
                // «Дыхание» волны с фиксированным уровнем вместо спиннера.
                StudioWave(level: 0.32, tint: DS.RecorderTone.transcribing)
                centerLabel {
                    Text(L("common.transcribing"))
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.primary)
                }
            }
        case .error(let message):
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title3)
                    .foregroundStyle(DS.RecorderTone.error)
                    .symbolEffect(.bounce, value: message)
                Text(message)
                    .font(.title3)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity)
        case .idle:
            EmptyView()
        }
    }

    /// Подпись по центру с мягким локальным затемнением — крупные яркие
    /// столбики в центре не мешают читать таймер.
    private func centerLabel<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 5) {
            content()
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 8)
        .background(
            Capsule(style: .continuous)
                .fill(Color.black.opacity(0.20))
                .blur(radius: 14)
        )
    }
}

// MARK: - Волна-спектр

/// Звуковая волна-спектр: десятки тонких вертикальных столбиков с
/// колоколообразной огибающей. Высота и яркость = огибающая × «драйв»
/// (усиленный уровень микрофона) × мерцание; кончики затухают вертикальным
/// градиентом, под резким слоем — двухслойный bloom. Чем громче голос, тем
/// выше амплитуда и горячее (светлее к белому) ядро. Reduce Motion замораживает
/// мерцание.
struct StudioWave: View {
    let level: Float
    var tint: Color = DS.accent

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Число столбиков — плотно, как в референсе.
    private static let barCount = 76

    /// Колоколообразная «подпись»-огибающая (0…1): главная гауссиана чуть левее
    /// центра + вторичный «плечевой» горб справа + низкий левый горб + дальние
    /// затухающие хвосты. Несимметрия даёт органику живого голоса. Считается раз.
    private static let envelope: [CGFloat] = {
        func gauss(_ p: Double, _ mu: Double, _ sigma: Double) -> Double {
            let z = (p - mu) / sigma
            return exp(-z * z)
        }
        var raw = [Double]()
        raw.reserveCapacity(barCount)
        for i in 0..<barCount {
            let p = Double(i) / Double(barCount - 1)
            let v = 1.00 * gauss(p, 0.46, 0.20)   // главный пик
                  + 0.58 * gauss(p, 0.63, 0.12)   // правое «плечо»
                  + 0.40 * gauss(p, 0.29, 0.10)    // левый горб
                  + 0.20 * gauss(p, 0.14, 0.07)    // дальний левый хвост
                  + 0.16 * gauss(p, 0.83, 0.09)    // дальний правый хвост
            raw.append(v)
        }
        let maxV = raw.max() ?? 1
        return raw.map { CGFloat($0 / maxV) }
    }()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: reduceMotion)) { context in
            let t = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
            // «Драйв»: уровень с сильным усилением — речь резко раскачивает волну.
            let drive = min(1, CGFloat(max(level, 0)) * 3.4)
            Canvas { gc, size in
                // Двухслойный bloom — ярче при громком голосе.
                gc.drawLayer { layer in
                    layer.addFilter(.blur(radius: 22))
                    layer.opacity = 0.40 + Double(drive) * 0.35
                    drawBars(in: &layer, size: size, time: t, drive: drive, glow: true)
                }
                gc.drawLayer { layer in
                    layer.addFilter(.blur(radius: 9))
                    layer.opacity = 0.80 + Double(drive) * 0.20
                    drawBars(in: &layer, size: size, time: t, drive: drive, glow: true)
                }
                // Резкий слой поверх.
                var sharp = gc
                drawBars(in: &sharp, size: size, time: t, drive: drive, glow: false)
            }
        }
    }

    private func drawBars(in ctx: inout GraphicsContext, size: CGSize,
                          time: TimeInterval, drive: CGFloat, glow: Bool) {
        let count = Self.barCount
        let step = size.width / CGFloat(count)
        let barWidth = min(3, step * 0.42)
        let midY = size.height / 2
        let maxBar = size.height * 0.96
        // Громкость → амплитуда: тихо — низкая «дышащая» линия, громко — во весь рост.
        let amp = 0.07 + drive * 0.93

        // Базовый цвет тинта (sRGB-компоненты) — для подсветки ядра к белому.
        let base = NSColor(tint).usingColorSpace(.sRGB) ?? NSColor.white
        let br = Double(base.redComponent)
        let bg = Double(base.greenComponent)
        let bb = Double(base.blueComponent)

        for i in 0..<count {
            let env = Self.envelope[i]
            // Пер-столбиковое мерцание из двух синусов — спектр «живёт».
            let shimmer: CGFloat
            if reduceMotion {
                shimmer = 1
            } else {
                let a = sin(time * 3.1 + Double(i) * 0.55)
                let b = sin(time * 6.3 + Double(i) * 0.27 + 1.3)
                let mix: Double = (0.6 * a + 0.4 * b) * 0.5 + 0.5   // 0…1
                shimmer = 0.72 + 0.28 * CGFloat(mix)
            }
            var h = env * amp * shimmer * maxBar
            h = max(barWidth, h)               // даже тихие столбики — точки-чёрточки

            let x = step * (CGFloat(i) + 0.5)
            let rect = CGRect(x: x - barWidth / 2, y: midY - h / 2,
                              width: barWidth, height: h)
            let bar = Path(roundedRect: rect, cornerRadius: barWidth / 2,
                           style: .continuous)

            // Ядро тем горячее (светлее), чем выше столбик И чем громче голос.
            let color: Color
            if glow {
                color = tint
            } else {
                let k = Double(env) * (0.42 + Double(drive) * 0.42)
                color = Color(red: br + (1 - br) * k,
                              green: bg + (1 - bg) * k,
                              blue: bb + (1 - bb) * k)
            }
            // Края тусклее центра; свечение чуть ярче резкого слоя.
            let edgeFade = 0.32 + 0.68 * env
            let opacity = (glow ? 0.9 : 1.0) * edgeFade

            // Вертикальный градиент: кончики затухают в прозрачность.
            let shading = GraphicsContext.Shading.linearGradient(
                Gradient(stops: [
                    .init(color: color.opacity(0), location: 0.0),
                    .init(color: color.opacity(opacity), location: 0.5),
                    .init(color: color.opacity(0), location: 1.0)
                ]),
                startPoint: CGPoint(x: rect.midX, y: rect.minY),
                endPoint: CGPoint(x: rect.midX, y: rect.maxY)
            )
            ctx.fill(bar, with: shading)
        }
    }
}
