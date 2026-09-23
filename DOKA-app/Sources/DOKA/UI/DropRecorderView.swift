import SwiftUI

/// Стиль панели записи «Аврора»: компактная светящаяся «капелька» снизу экрана
/// плюс полноэкранная персиковая подсветка краёв (`ScreenGlowView`,
/// показывается отдельной клик-сквозной панелью из RecorderPanelController).
///
/// Вся графика капельки — Metal-шейдеры (`Shaders/AuroraDrop.metal`): волна во
/// время записи, жидкие точки во время распознавания и стеклянная оболочка,
/// преломляющая содержимое у кромки. На SwiftUI-примитивах такое не собирается —
/// это попиксельное свечение, ему нужен шейдер.

// MARK: - Доступ к шейдерам

/// Обёртка над скомпилированной библиотекой шейдеров.
///
/// `default.metallib` собирается ОТДЕЛЬНЫМ шагом (`scripts/build-shaders.sh`,
/// зовётся из `build.sh`): SwiftPM .metal не компилирует, а build-tool-плагин
/// ломал мультиарх-сборку. Если библиотеки в бандле нет (забыли прогнать
/// скрипт перед голым `swift build`) — капелька рисуется без эффекта, а не
/// падает и не показывает мусор.
enum DropShaders {
    static let isAvailable: Bool = {
        let found = Bundle.module.url(forResource: "default", withExtension: "metallib") != nil
        if !found {
            NSLog("[DOKA] default.metallib не найден — панель «Аврора» без эффекта. "
                  + "Прогоните scripts/build-shaders.sh")
        }
        return found
    }()

    private static var library: ShaderLibrary { ShaderLibrary.bundle(.module) }

    /// Волна записи. `phase` интегрируется снаружи: скорость бега зависит от голоса.
    static func wave(size: CGSize, phase: Double, level: Float, look: DropLook) -> Shader {
        library.dokaDropWave(
            .float2(Float(size.width), Float(size.height)),
            .float(Float(phase)),
            .float(level),
            .color(look.wave[0]),
            .color(look.wave[1]),
            .color(look.wave[2]),
            .color(look.waveHighlight)
        )
    }

    /// Точки распознавания: кольцо жидких капель, `appear` — появление 0…1.
    static func dots(size: CGSize, time: Double, appear: Double) -> Shader {
        library.dokaDropDots(
            .float2(Float(size.width), Float(size.height)),
            .float(Float(time)),
            .float(Float(appear)),
            .color(DS.RecorderTone.transcribing),
            .color(DS.Aurora.indigo),
            .color(DS.Aurora.dotHighlight)
        )
    }

    /// Стеклянная оболочка: преломление содержимого у кромки + светящийся блик.
    /// У «Мини» (`look.liveRim`) блик вдобавок живой: подхватывает свет волны
    /// из-под себя, бежит приливами и расщепляется аберрацией. «Аврора»
    /// передаёт нули и получает прежнюю ровную кромку.
    static func glass(size: CGSize, phase: Double, level: Float, look: DropLook) -> Shader {
        library.dokaDropGlass(
            .float2(Float(size.width), Float(size.height)),
            .float(Float(DropGeometry.refraction)),
            .float(0.42 + 0.28 * min(max(level, 0), 1)),   // блик разгорается под голос
            .float(1.2),
            .color(look.rimTop),
            .color(look.rimBottom),
            .float(Float(phase)),
            .float(look.liveRim ? DropLook.bleed : 0),
            .float(look.liveRim ? DropLook.tide : 0),
            .float(look.liveRim ? DropLook.aberration : 0)
        )
    }
}

// MARK: - Геометрия и движение

/// Габариты капельки — единственный источник размеров для обоих стилей,
/// которые её используют. Форма волны от ширины НЕ зависит: она считается от
/// опорного аспекта (`kRefAspect` в шейдере), поэтому узкая капелька получает
/// ту же картинку, просто сжатую по ширине.
/// Чем стили отличаются по ГРАФИКЕ (габариты — в `DropGeometry`).
///
/// «Аврора» — исходная капелька: космическая подложка и ровный блик по кромке.
/// «Мини» — глубже по индиго и с живой кромкой: свет волны вытекает на обводку,
/// бежит по ней приливами и расщепляется хроматической аберрацией (эффект в
/// духе Liquid Glass). Разводить их просил пользователь — «Аврору» не трогать.
struct DropLook {
    /// Подложка под волной (сверху-слева → снизу-справа).
    let cosmic: [Color]
    /// Три нити волны: ведущая (самая светлая) → средняя → «хвост».
    let wave: [Color]
    /// Пересвеченное ядро волны на пиках.
    let waveHighlight: Color
    /// Тона кромки: верх и низ (между ними шейдер интерполирует по вертикали).
    let rimTop: Color
    let rimBottom: Color
    /// Живая кромка: приливы, аберрация и цвет в тон содержимому.
    let liveRim: Bool

    /// Насколько кромка подчиняется свету под ней (0 — совсем не подчиняется).
    static let bleed: Float = 0.85
    /// Глубина приливов вдоль кромки: 0.45 — гуляет примерно от 55% до 100%.
    static let tide: Float = 0.45
    /// Расхождение каналов R/B в долях от преломления. Подобрано живьём:
    /// 0.35 — почти незаметно, 0.7 — толсто, 0.5 — чуть больше нужного.
    static let aberration: Float = 0.4

    static let aurora = DropLook(
        cosmic: DS.Aurora.cosmic,
        wave: [DS.accent, DS.glow, DS.Aurora.indigo],
        waveHighlight: DS.Aurora.waveHighlight,
        rimTop: DS.glow,
        rimBottom: DS.Aurora.indigo,
        liveRim: false
    )
    /// «Мини» — холодная тема целиком: ледяная ведущая нить, бирюза Тиффани
    /// и сине-фиолетовый хвост на тёмно-синей подложке. Тёплых оттенков здесь
    /// нет намеренно — не подмешивать `DS.accent`/`DS.glow` без просьбы.
    static let mini = DropLook(
        cosmic: DS.Aurora.cosmicDeep,
        wave: [DS.Aurora.miniIce, DS.Aurora.miniTiffany, DS.Aurora.miniViolet],
        waveHighlight: DS.Aurora.miniHighlight,
        rimTop: DS.Aurora.miniTiffany,
        rimBottom: DS.Aurora.miniViolet,
        liveRim: true
    )
}

struct DropGeometry {
    /// Капсула во время записи.
    let recording: CGSize
    /// Окно панели: запас вокруг капельки под ореол, блик и перелёт пружин.
    let panel: CGSize
    /// Тёплый ореол за капелькой: часть свечения «Авроры». У «Мини» его нет —
    /// она задумана как чистая капелька без подсветки вокруг.
    let halo: Bool
    /// Графика капельки: подложка и характер кромки.
    let look: DropLook

    /// «Аврора» — широкая и низкая капелька, ореол и подсветка краёв экрана.
    /// Высота 44 (на 30% ниже прежних 63) — форма волны от этого не меняется,
    /// она считается от опорного аспекта, а не от фактического.
    static let wide = DropGeometry(
        recording: CGSize(width: 180, height: 44),
        panel: CGSize(width: 260, height: 119),
        halo: true,
        look: .aurora
    )
    /// «Мини» — та же капелька вдвое уже, БЕЗ ореола и без подсветки экрана.
    static let compact = DropGeometry(
        recording: CGSize(width: 90, height: 63),
        panel: CGSize(width: 170, height: 119),
        halo: false,
        look: .mini
    )

    /// Во время распознавания капсула стягивается в КРУГ, поэтому цель по
    /// ширине — собственная высота стиля: у «Мини» это 63, у более низкой
    /// «Авроры» — 44. Общая константа здесь дала бы овал.
    var transcribing: CGSize {
        CGSize(width: recording.height, height: recording.height)
    }
    /// Волна рисуется крупнее капсулы и обрезается ею — свет «забегает» за кромку.
    static let waveOverscan: CGFloat = 1.18
    /// Сдвиг сэмпла у кромки в стекле (точки).
    static let refraction: CGFloat = 6
}

/// Фаза волны и пружина ширины капсулы.
///
/// Ссылочный тип намеренно: значения пересчитываются на каждом кадре внутри
/// `TimelineView`, а мутация `@State`-значения прямо в `body` — ошибка.
@MainActor final class DropMotion {
    private(set) var phase: Double = 0
    private(set) var width: Double = DropGeometry.wide.recording.width
    /// Появление: 0 — точка, 1 — полный размер. Пружина даёт лёгкий перелёт,
    /// поэтому капелька «надувается» пузырём, а не просто возникает.
    private(set) var appear: Double = 0
    private var velocity: Double = 0
    private var appearVelocity: Double = 0
    private var last: Date?

    /// Скорость бега волны: в тишине спокойная, на голосе втрое быстрее.
    /// Коэффициенты — 95% от эталонных (2.5 и 12): на полной скорости волна
    /// бежала суетливо, а заметное замедление читалось как вялость.
    private static func waveSpeed(level: Double) -> Double {
        2.375 + 11.4 * min(1, 0.4 * level)
    }

    /// Пружина ширины: недодемпфированная (ζ ≈ 0.45) — капсула стягивается
    /// в круг плавно и с лёгким отскоком, как капля на батуте.
    private static let stiffness: Double = 400
    private static let damping: Double = 18

    /// Пружина появления помягче (ζ ≈ 0.6): перелёт около 10% — заметный,
    /// но капелька не выпрыгивает за пределы окна панели.
    private static let appearStiffness: Double = 320
    private static let appearDamping: Double = 21

    /// Полный оборот фазы держим малым числом: `Float` в шейдере не вытянет
    /// секунды от точки отсчёта (~8·10⁸) — волна начнёт дёргаться.
    private static let phaseWrap: Double = 2 * .pi * 10

    func advance(to date: Date, level: Double, targetWidth: Double, animated: Bool) {
        defer { last = date }
        guard animated else {                 // Reduce Motion — сразу готовый кадр
            width = targetWidth
            appear = 1
            return
        }
        // Первый кадр только фиксирует время: dt от него посчитать не из чего.
        guard let previous = last else { return }
        // Кадр после сна/скрытой панели может быть длинным — иначе пружина взорвётся.
        let dt = min(max(date.timeIntervalSince(previous), 0), 0.1)
        guard dt > 0 else { return }

        phase = (phase + Self.waveSpeed(level: level) * dt)
            .truncatingRemainder(dividingBy: Self.phaseWrap)

        let acceleration = (width - targetWidth) * -Self.stiffness + velocity * -Self.damping
        velocity += acceleration * dt
        width += velocity * dt

        let appearForce = (appear - 1) * -Self.appearStiffness + appearVelocity * -Self.appearDamping
        appearVelocity += appearForce * dt
        appear += appearVelocity * dt
    }

    /// Сброс при появлении панели: без него первый кадр получит огромный dt.
    func reset(width targetWidth: Double) {
        last = nil
        velocity = 0
        width = targetWidth
        appear = 0
        appearVelocity = 0
    }
}

// MARK: - Капелька

/// Оболочка капельки: космическая подложка, шейдерное содержимое и стекло.
/// Используется и живой панелью, и миниатюрой в пикере — вид стиля задаётся
/// в одном месте.
private struct DropSurface: View {
    let size: CGSize
    let content: Shader?
    let level: Float
    let phase: Double
    let look: DropLook

    var body: some View {
        ZStack {
            Capsule(style: .continuous)
                .fill(
                    LinearGradient(
                        colors: look.cosmic,
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
            if let content {
                Rectangle()
                    .fill(.white)
                    .colorEffect(content)
                    .frame(width: size.width * DropGeometry.waveOverscan,
                           height: size.height * DropGeometry.waveOverscan)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(Capsule(style: .continuous))
        .glassShell(size: size, phase: phase, level: level, look: look)
        // Преломление уводит сэмплы за границу капсулы — без повторной обрезки
        // вокруг капельки остаётся размытый ореол чужого цвета.
        .clipShape(Capsule(style: .continuous))
    }
}

private extension View {
    @ViewBuilder
    func glassShell(size: CGSize, phase: Double, level: Float, look: DropLook) -> some View {
        if DropShaders.isAvailable {
            // Запас выборки втрое, а не вдвое: аберрация и «подкромочный»
            // сэмпл живой кромки уходят глубже обычного преломления.
            layerEffect(
                DropShaders.glass(size: size, phase: phase, level: level, look: look),
                maxSampleOffset: CGSize(width: DropGeometry.refraction * 3,
                                        height: DropGeometry.refraction * 3)
            )
        } else {
            overlay(
                Capsule(style: .continuous)
                    .strokeBorder(DS.glow.opacity(0.5), lineWidth: 1)
            )
        }
    }
}

/// Статичная миниатюра капельки для пикера стилей (`RecorderStylePicker`).
/// `look` обязателен: карточки «Авроры» и «Мини» показывают РАЗНЫЕ капельки,
/// и миниатюра должна совпадать с живой панелью.
struct DropPreview: View {
    let size: CGSize
    let look: DropLook

    /// Фаза статична — та же, что у волны миниатюры.
    private static let phase: Double = 1.6

    var body: some View {
        DropSurface(
            size: size,
            content: DropShaders.isAvailable
                ? DropShaders.wave(size: size, phase: Self.phase, level: 0.7, look: look)
                : nil,
            level: 0.7,
            phase: Self.phase,
            look: look
        )
    }
}

// MARK: - Панель «Аврора»

/// Окно панели заметно больше самой капельки: ореол вокруг неё рисуется
/// ВНУТРИ окна. Внешних теней у корня по-прежнему нет — окно borderless
/// обрезало бы их своей квадратной границей (тёмные углы в светлой теме).
///
/// Одна и та же вью обслуживает два стиля: «Аврора» (широкая капелька, ореол
/// вокруг неё и полноэкранная подсветка краёв) и «Мини» (та же капелька вдвое
/// уже, без ореола и без подсветки). Отличает их только `geometry` (ширина и
/// флаг `halo`) и то, поднимает ли контроллер панель со `ScreenGlowView`.
struct DropRecorderView: View {
    @ObservedObject var controller: DictationController
    let size: CGSize
    let geometry: DropGeometry

    /// Появление точек распознавания: кольцо разлетается из центра.
    @State private var dotsAppear: Double = 0
    @State private var motion = DropMotion()

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: reduceMotion)) { context in
            let level = Double(min(max(controller.audioLevel, 0), 1))
            let target = isTranscribing
                ? geometry.transcribing.width
                : geometry.recording.width
            let _ = motion.advance(to: context.date, level: level,
                                   targetWidth: target, animated: !reduceMotion)
            let capsule = CGSize(width: motion.width, height: geometry.recording.height)

            ZStack {
                if isRecording || isTranscribing {
                    if geometry.halo { halo(capsule: capsule, level: level) }
                    DropSurface(size: capsule, content: content(capsule: capsule, level: level),
                                level: Float(level), phase: motion.phase, look: geometry.look)
                }
            }
            .frame(width: size.width, height: size.height)
            // Прозрачность набирается быстрее размера: точка не должна
            // мелькать полупрозрачным пятном, пока пузырь раздувается.
            .scaleEffect(max(motion.appear, 0))
            .opacity(min(1, max(motion.appear, 0) * 1.6))
        }
        .onChange(of: isTranscribing) { _, transcribing in
            withAnimation(reduceMotion ? nil : .spring(duration: 0.45)) {
                dotsAppear = transcribing ? 1 : 0
            }
        }
        .onAppear { motion.reset(width: geometry.recording.width) }
        .onChange(of: isRecording) { _, recording in
            // Панель переживает цикл диктовки: без сброса новая запись
            // начнётся с чужой фазы импульса и уже разогнанной пружины.
            if recording { motion.reset(width: geometry.recording.width) }
        }
    }

    private func content(capsule: CGSize, level: Double) -> Shader? {
        guard DropShaders.isAvailable else { return nil }
        let field = CGSize(width: capsule.width * DropGeometry.waveOverscan,
                           height: capsule.height * DropGeometry.waveOverscan)
        switch controller.state {
        case .recording:
            return DropShaders.wave(size: field, phase: motion.phase, level: Float(level),
                                    look: geometry.look)
        case .transcribing:
            return DropShaders.dots(size: field, time: motion.phase, appear: dotsAppear)
        case .idle, .error:
            // Ошибка в капельку не помещается — её показывает классическая
            // панель (см. RecorderPanelController.show).
            return nil
        }
    }

    /// Тёплый ореол вокруг капельки, разгорается под голос. Только «Аврора»:
    /// у «Мини» (`geometry.halo == false`) капелька рисуется без него.
    private func halo(capsule: CGSize, level: Double) -> some View {
        Capsule(style: .continuous)
            .fill(isTranscribing ? DS.RecorderTone.transcribing : DS.glow)
            .frame(width: capsule.width * 0.92, height: capsule.height * 0.8)
            .blur(radius: 22)
            .opacity(0.20 + 0.35 * level)
    }

    private var isRecording: Bool {
        if case .recording = controller.state { return true }
        return false
    }

    private var isTranscribing: Bool {
        if case .transcribing = controller.state { return true }
        return false
    }
}

// MARK: - Полноэкранная подсветка краёв

/// Только для стиля «Аврора» (в «Мини» капелька живёт без неё).
/// Полноэкранная подсветка в духе Claude/Siri с акцентом в ЦЕНТРЕ нижнего
/// края — ровно под капелькой: свет разгорается по центру и пологим колоколом
/// спадает к левому и правому нижним углам (маска `centerFalloff`, края —
/// 0.64 от центра: углы приглушены, но не гаснут), а не наоборот.
/// Верх экрана чист. Пульсирует под уровень микрофона, но сдержанно: после
/// перехода на новую (линейную) кривую уровня прежние коэффициенты давали
/// резкую вспышку на каждом слоге — база, вклад голоса и огибающая приглушены
/// намеренно, не возвращать яркость без просьбы.
/// Рисуется в клик-сквозной панели: не перехватывает мышь и не забирает фокус.
/// Окно накладывается на экран обычной альфой (sourceOver) — смешение
/// нормальное, без plusLighter.
/// Reduce Motion — статично; Reduce Transparency — приглушённо.
struct ScreenGlowView: View {
    @ObservedObject var controller: DictationController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    /// Уровень с envelope-сглаживанием: быстрый attack, медленный decay.
    @State private var level: Double = 0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { context in
            let t = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
            let breathe = reduceMotion ? 0.0 : (0.5 + 0.5 * sin(t * 0.8))
            let lvl = reduceMotion ? 0.35 : level   // рост «героя» под голос
            // Показатель мягче квадратного корня: тихая речь больше не
            // вздёргивает подсветку на полную.
            let shaped = pow(lvl, 0.7)
            // Подсветка дышит, а не мигает, но и не выглядит полупрозрачной:
            // коэффициенты — прежние приглушённые, поднятые в 1.4 раза.
            let intensity = reduceMotion
                ? 0.56
                : min(1.0, 0.22 + 0.64 * shaped + breathe * 0.04)
            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height
                let m = min(w, h)
                let d1 = reduceMotion ? 0 : CGFloat(sin(t * 0.13)) * w * 0.02
                let d2 = reduceMotion ? 0 : CGFloat(cos(t * 0.17)) * w * 0.02
                // Граница, выше которой свет уходит в прозрачность; поднимается под голос.
                let clearTo = 0.80 - 0.22 * lvl
                ZStack {
                    // Нижний вертикальный wash: тёплый низ → плавно в прозрачность
                    // вверх (без резкой кромки), по ширине — колокол с максимумом
                    // под капелькой.
                    Rectangle()
                        .fill(LinearGradient(stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .clear, location: clearTo),
                            .init(color: DS.ScreenGlow.peach.opacity(0.18),
                                  location: clearTo + (1 - clearTo) * 0.55),
                            .init(color: DS.ScreenGlow.amber.opacity(0.42), location: 1.0)
                        ], startPoint: .top, endPoint: .bottom))
                        .mask(Self.centerFalloff)
                    // Центр-низ — «герой» под самой капелькой, растёт под голос.
                    orb(DS.ScreenGlow.amber, 0.46, x: w * 0.5 + d1, y: h + m * 0.03,
                        r: m * (0.62 + 0.24 * lvl))
                    // Плечи колокола: заметно тусклее центра и не достают до углов.
                    orb(DS.ScreenGlow.peach, 0.26, x: w * 0.22 + d2, y: h + m * 0.05, r: m * 0.54)
                    orb(DS.ScreenGlow.coral, 0.22, x: w * 0.78 - d2, y: h + m * 0.05, r: m * 0.50)
                }
                .frame(width: w, height: h)
                .opacity(intensity * (reduceTransparency ? 0.55 : 1.0))
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .onChange(of: controller.audioLevel) { _, raw in
            // Быстрый подъём, медленное затухание — общая огибающая панелей.
            // Attack сознательно мягче, чем у капельки: полноэкранный свет на
            // резком подъёме читается как вспышка.
            level = level.envelope(toward: Double(min(max(raw, 0), 1)), attack: 0.25, release: 0.08)
        }
    }

    /// Пологий колокол по ширине: под капелькой — полная яркость, у левого и
    /// правого нижних углов — 0.64 от неё (углы гаснуть не должны, свет идёт
    /// вдоль всего низа). Линейного градиента из двух стопов мало — он даёт
    /// клин, а не колокол.
    private static var centerFalloff: some View {
        LinearGradient(stops: [
            .init(color: .white.opacity(0.64), location: 0.00),
            .init(color: .white.opacity(0.72), location: 0.18),
            .init(color: .white.opacity(0.88), location: 0.34),
            .init(color: .white, location: 0.50),
            .init(color: .white.opacity(0.88), location: 0.66),
            .init(color: .white.opacity(0.72), location: 0.82),
            .init(color: .white.opacity(0.64), location: 1.00)
        ], startPoint: .leading, endPoint: .trailing)
    }

    /// Мягкий радиальный орб с ярким ядром.
    private func orb(_ c: Color, _ peak: Double, x: CGFloat, y: CGFloat, r: CGFloat) -> some View {
        RadialGradient(
            colors: [c.opacity(peak), c.opacity(peak * 0.45), .clear],
            center: .center, startRadius: 0, endRadius: r / 2
        )
        .frame(width: r, height: r)
        .blur(radius: r * 0.12)
        .position(x: x, y: y)
    }
}
