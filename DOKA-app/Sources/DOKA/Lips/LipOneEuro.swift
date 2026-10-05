import CoreGraphics
import Foundation

/// Фильтр One Euro (Casiez и др., 2012) для точек губ в зеркале — та же
/// формула, что у MediaPipe (`one_euro_filter.cc`) и встроенного сглаживания
/// lipflow. Это адаптивный экспоненциальный фильтр: в покое срез низкий и
/// дрожь Vision гасится, на быстром движении срез растёт со скоростью, и
/// маска не отстаёт от артикуляции.
///
/// - `α = 1/(1 + 1/(2π·fc·dt))`, `dt` — разница host-меток кадров (с), срезы — в Гц;
/// - производная — от прошлого СЫРОГО значения, как у MediaPipe (у Casiez —
///   от отфильтрованного). На метриках стенда разница пренебрежима (дрожь
///   0,459 / 0,966 против 0,458 / 0,932 % межглазного), поточечно — нет:
///   на золотом векторе выходы расходятся до 4 px, и `testGoldenVector`
///   варианты различает;
/// - `scale` умножает ТОЛЬКО производную: параметры не зависят от того, в
///   каких единицах точки и насколько лицо близко к камере;
/// - первый отсчёт проходит как есть, сглаженная производная стартует с нуля.
///
/// Правила для кривого времени свои. У MediaPipe на неубывающей метке —
/// СЫРОЕ значение и никакого перезапуска. У нас шаг меньше `minInterval` или
/// назад — прошлое ОТФИЛЬТРОВАННОЕ значение, состояние не трогается; разрыв
/// дольше `restartAfter` — фильтр начинает заново (лицо уходило, прошлое к
/// новому кадру отношения не имеет); нечисловой отсчёт (NaN, ±inf) —
/// прошлое значение, состояние не трогается.
///
/// Python-порт у стенда сравнения (функция `one_euro` в `analyze.py`; стенд
/// временный, вне репозитория) сверен с этим кодом общим «золотым» вектором —
/// `LipOneEuroTests.testGoldenVector`: параметры, подобранные стендом,
/// переносятся сюда без пересчёта.
struct LipOneEuro {
    struct Parameters: Equatable {
        /// Срез в покое, Гц: чем ниже, тем меньше дрожи и тем дольше
        /// догоняется медленный дрейф.
        var minCutoff: Double
        /// Прибавка к срезу на единицу скорости (в единицах `scale` в секунду).
        /// Запаздывание на ровном движении — `v/(2π·(minCutoff + beta·v))`,
        /// то есть всегда меньше `1/(2π·beta)` в единицах `scale` — для точек
        /// губ это доля размера лица, ≈ `44/beta` pt экрана зеркала. Ни `dt`,
        /// ни `derivativeCutoff` эту границу не меняют, поэтому при `beta`
        /// ниже ~44 маска заметно отстанет от губ — снижать только осознанно.
        var beta: Double
        /// Срез фильтра производной, Гц: как быстро срез реагирует на начало движения.
        var derivativeCutoff: Double

        /// Точки губ, `scale = 2/(box.w + box.h)` бокса лица
        /// (`LipPointsFilter.valueScale`). Не умолчание MediaPipe 0.05 / 80 / 1:
        /// стенд (48 роликов 1280×720, Vision rev3/76; 1 % межглазного ≈ 1,2 pt
        /// зеркала) выбрал 1 / 80 / 2 по метрике плана — дрожь против опоры
        /// СЫРОГО ряда, она штрафует и запаздывание — при запаздывании
        /// раскрытия рта не больше полкадра. По ней: покой 0,46 % межглазного
        /// против 0,57 у MediaPipe, речь 0,97 против 1,43, запаздывание 0,30
        /// кадра против 0,54.
        ///
        /// Компромисс: по ВИДИМОМУ колебанию маски (выход против собственного
        /// сглаженного тренда, запаздывание не штрафует) 1 / 80 / 2 ХУЖЕ
        /// умолчания MediaPipe — 0,36 / 0,61 % межглазного (покой / речь)
        /// против 0,26 / 0,53. Если на живой проверке маска дрожит в покое —
        /// запасной вариант 0.3 / 44 / 2: колебание 0,25 / 0,51, запаздывание
        /// ≈ 0,49 кадра; β = 44 — на границе по запаздыванию (см. `beta`).
        /// Окончательно — по живой проверке в зеркале.
        static let lips = Parameters(minCutoff: 1, beta: 80, derivativeCutoff: 2)
    }

    /// Меньший шаг времени — тот же кадр: частоты нет, прошлое значение.
    static let minInterval = 1e-4
    /// Разрыв дольше этого, с, — фильтр начинает заново.
    static let restartAfter = 0.5

    let parameters: Parameters
    private var state: State?

    private struct State {
        /// Отфильтрованное значение.
        var value: Double
        /// Прошлое СЫРОЕ значение — от него считается производная.
        var raw: Double
        /// Сглаженная производная, в единицах `scale` в секунду.
        var derivative: Double
        var time: Double
    }

    init(parameters: Parameters) {
        self.parameters = parameters
    }

    /// Коэффициент экспоненциального сглаживания для среза `cutoff` (Гц) на шаге `dt` (с).
    static func alpha(cutoff: Double, dt: Double) -> Double {
        1 / (1 + 1 / (2 * .pi * cutoff * dt))
    }

    /// Очередной отсчёт `value` в момент `time` (host-метка кадра, с).
    /// `scale` переводит значение в единицы, в которых задан `beta`.
    mutating func filter(_ value: Double, at time: Double, scale: Double = 1) -> Double {
        // До `start`: NaN первой меткой отсёк бы по `minInterval` все
        // следующие кадры, и фильтр навсегда отдавал бы первое значение.
        guard time.isFinite, value.isFinite, scale.isFinite else { return state?.value ?? value }
        guard var s = state else { return start(value, at: time) }
        let dt = time - s.time
        guard dt >= Self.minInterval else { return s.value }
        if dt > Self.restartAfter { return start(value, at: time) }
        let rate = (value - s.raw) * scale / dt
        let derivativeAlpha = Self.alpha(cutoff: parameters.derivativeCutoff, dt: dt)
        s.derivative = derivativeAlpha * rate + (1 - derivativeAlpha) * s.derivative
        let cutoff = parameters.minCutoff + parameters.beta * abs(s.derivative)
        let alpha = Self.alpha(cutoff: cutoff, dt: dt)
        s.value = alpha * value + (1 - alpha) * s.value
        s.raw = value
        s.time = time
        state = s
        return s.value
    }

    mutating func reset() { state = nil }

    private mutating func start(_ value: Double, at time: Double) -> Double {
        state = State(value: value, raw: value, derivative: 0, time: time)
        return value
    }
}

/// One Euro для точек губ: свой фильтр на x и на y каждой точки. Точки
/// сопоставляются по индексу Vision, поэтому другое НЕНУЛЕВОЕ число точек
/// (другое созвездие) начинает все фильтры заново — сопоставлять не с чем.
///
/// Кадр без губ — пустой массив или пропуск вызова — состояние не трогает:
/// одиночный промах Vision фильтр переживает, а долгий (дольше
/// `LipOneEuro.restartAfter`, лицо уходило) перезапускает его сам по
/// разрыву меток. Сброс на пустом кадре пропускал бы первый кадр после
/// каждого промаха сырым, с нулевой производной.
///
/// Состояние — на `visionQueue` камеры, рядом с конвейером зеркала.
struct LipPointsFilter {
    let parameters: LipOneEuro.Parameters
    /// По два фильтра на точку: x — `2i`, y — `2i + 1`.
    private var filters: [LipOneEuro] = []

    init(parameters: LipOneEuro.Parameters = .lips) {
        self.parameters = parameters
    }

    /// Масштаб значения для точек в пикселях кадра: обратный средний размер
    /// бокса лица, `2/(w + h)`. Скорость считается в «лицах в секунду», и
    /// `beta` не зависит от того, близко ли лицо к камере.
    static func valueScale(faceBox: CGRect) -> Double {
        2 / max(Double(faceBox.width + faceBox.height), 1)
    }

    mutating func filter(_ points: [CGPoint], at time: Double, scale: Double) -> [CGPoint] {
        guard !points.isEmpty else { return [] }
        if filters.count != 2 * points.count {
            filters = Array(repeating: LipOneEuro(parameters: parameters), count: 2 * points.count)
        }
        var result: [CGPoint] = []
        result.reserveCapacity(points.count)
        for (i, p) in points.enumerated() {
            let x = filters[2 * i].filter(p.x, at: time, scale: scale)
            let y = filters[2 * i + 1].filter(p.y, at: time, scale: scale)
            result.append(CGPoint(x: x, y: y))
        }
        return result
    }

    mutating func reset() { filters = [] }
}
