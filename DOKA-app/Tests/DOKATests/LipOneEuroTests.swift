import CoreGraphics
import XCTest
@testable import DOKA

/// Фильтр One Euro для точек губ в зеркале.
///
/// Зачем: маска должна и не дрожать в покое, и не отставать от губ на речи.
/// Математика проверяется на ЯВНЫХ параметрах, а не на пресете `lips`:
/// пресет подбирается стендом и живой проверкой, и его смена не должна
/// ломать тесты формул. Золотой вектор держит порт стенда на Python в
/// согласии с этим кодом — иначе подобранные там параметры не перенесутся.
final class LipOneEuroTests: XCTestCase {

    /// Умолчание MediaPipe и lipflow.
    private let mediaPipe = LipOneEuro.Parameters(minCutoff: 0.05, beta: 80, derivativeCutoff: 1)

    /// Масштаб значения для лица ~300 px: скорость — в «лицах в секунду».
    private let faceScale = 1.0 / 300

    /// Метки кадров: `count` кадров с частотой `fps` от 1000 с.
    private func times(_ count: Int, fps: Double = 30) -> [Double] {
        (0..<count).map { 1000 + Double($0) / fps }
    }

    /// Прогон ряда через свежий фильтр.
    private func run(_ values: [Double], at times: [Double], scale: Double,
                     parameters: LipOneEuro.Parameters) -> [Double] {
        var filter = LipOneEuro(parameters: parameters)
        return zip(values, times).map { filter.filter($0, at: $1, scale: scale) }
    }

    /// Установившееся запаздывание на ровном движении со скоростью
    /// `facesPerSecond` при частоте `fps` — в пикселях.
    private func rampLag(facesPerSecond: Double, fps: Double, parameters: LipOneEuro.Parameters) -> Double {
        let t = times(Int(6 * fps) + 1, fps: fps)
        let speed = facesPerSecond / faceScale                  // px/с
        let x = t.map { 200 + speed * ($0 - 1000) }
        let out = run(x, at: t, scale: faceScale, parameters: parameters)
        return x[x.count - 1] - out[out.count - 1]
    }

    // MARK: - Покой

    /// Неподвижная точка проходит как есть: фильтр не сдвигает её и не «плывёт»,
    /// даже если метки кадров неровные.
    func testConstantInputPassesThrough() {
        let t = times(90).enumerated().map { i, time in time + 0.004 * sin(Double(i) * 1.7) }
        let out = run(Array(repeating: 512.25, count: t.count), at: t, scale: faceScale, parameters: mediaPipe)
        for value in out { XCTAssertEqual(value, 512.25, accuracy: 1e-9) }
    }

    /// Дрожь Vision в покое (±1 px на лице 300 px) гасится больше чем вдвое,
    /// а среднее остаётся на месте.
    func testStillJitterIsDamped() {
        let t = times(300)
        let x = t.indices.map { 400 + sin(Double($0 * $0) * 0.7) }
        let out = run(x, at: t, scale: faceScale, parameters: mediaPipe)
        func rms(_ values: ArraySlice<Double>) -> Double {
            (values.reduce(0) { $0 + ($1 - 400) * ($1 - 400) } / Double(values.count)).squareRoot()
        }
        let settled = 30...
        XCTAssertLessThan(rms(out[settled]), 0.5 * rms(x[settled]))
        let mean = out[settled].reduce(0, +) / Double(out[settled].count)
        XCTAssertEqual(mean, 400, accuracy: 0.2)
    }

    // MARK: - Движение

    /// На ровном движении фильтр отстаёт ровно на `v/(2π·(minCutoff + beta·v))`
    /// и никогда — больше чем на `1/(2π·beta)` размера лица, как бы быстро
    /// ни двигались губы. Это и есть цена гладкости для «маска ложится на губы».
    func testRampLagIsBelowOneOverTwoPiBeta() {
        let parameters = LipOneEuro.Parameters(minCutoff: 0.05, beta: 20, derivativeCutoff: 1)
        let bound = 1 / (2 * Double.pi * parameters.beta)
        for v in [0.1, 1, 10] {                                 // лиц в секунду
            let lag = rampLag(facesPerSecond: v, fps: 30, parameters: parameters) * faceScale
            let expected = v / (2 * Double.pi * (parameters.minCutoff + parameters.beta * v))
            XCTAssertEqual(lag, expected, accuracy: expected * 1e-6, "v = \(v)")
            XCTAssertLessThan(lag, bound, "v = \(v)")
        }
    }

    /// Срезы заданы в герцах, а не «на кадр»: при 25 и 30 к/с запаздывание
    /// на том же движении одинаковое — камера на 25 к/с маску не замедлит.
    func testSameRampLagAt25And30Fps() {
        let parameters = LipOneEuro.Parameters(minCutoff: 1, beta: 20, derivativeCutoff: 2)
        let lag30 = rampLag(facesPerSecond: 1, fps: 30, parameters: parameters)
        let lag25 = rampLag(facesPerSecond: 1, fps: 25, parameters: parameters)
        XCTAssertGreaterThan(lag30, 0.1)
        XCTAssertEqual(lag25, lag30, accuracy: 1e-6)
    }

    // MARK: - Время

    /// Тот же кадр ещё раз, метка назад или шаг меньше `minInterval` — прошлое
    /// значение, а состояние не тронуто: следующий нормальный кадр даёт то же,
    /// что у фильтра, который этих отсчётов не видел.
    func testNonIncreasingTimeKeepsLastValue() {
        let t = times(12)
        let x = t.indices.map { 300 + 4 * Double($0) }
        var filter = LipOneEuro(parameters: mediaPipe)
        var clean = LipOneEuro(parameters: mediaPipe)
        var last = 0.0
        for i in 0..<11 {
            last = filter.filter(x[i], at: t[i], scale: faceScale)
            XCTAssertEqual(clean.filter(x[i], at: t[i], scale: faceScale), last)
        }
        XCTAssertEqual(filter.filter(900, at: t[10], scale: faceScale), last)
        XCTAssertEqual(filter.filter(900, at: t[10] - 0.01, scale: faceScale), last)
        XCTAssertEqual(filter.filter(900, at: t[10] + 0.5 * LipOneEuro.minInterval, scale: faceScale), last)
        XCTAssertEqual(filter.filter(900, at: .nan, scale: faceScale), last)
        XCTAssertEqual(filter.filter(x[11], at: t[11], scale: faceScale),
                       clean.filter(x[11], at: t[11], scale: faceScale))
    }

    /// Нечисловой отсчёт ПЕРВЫМ (метка, значение или масштаб) не становится
    /// состоянием: иначе NaN в метке отсекал бы все следующие кадры, и фильтр
    /// навсегда отдавал бы первое значение. Дальше — как у свежего фильтра.
    /// Посреди ряда нечисловое значение или масштаб — прошлое значение.
    func testNonFiniteSampleDoesNotPoisonState() {
        let t = times(4)
        var filter = LipOneEuro(parameters: mediaPipe)
        var fresh = LipOneEuro(parameters: mediaPipe)
        _ = filter.filter(300, at: .nan, scale: faceScale)
        _ = filter.filter(300, at: .infinity, scale: faceScale)
        _ = filter.filter(.nan, at: t[0] - 1.0 / 30, scale: faceScale)
        _ = filter.filter(300, at: t[0] - 1.0 / 30, scale: .nan)
        XCTAssertEqual(filter.filter(310, at: t[0], scale: faceScale), 310)
        _ = fresh.filter(310, at: t[0], scale: faceScale)
        let second = filter.filter(330, at: t[1], scale: faceScale)
        XCTAssertEqual(second, fresh.filter(330, at: t[1], scale: faceScale))
        XCTAssertNotEqual(second, 330)

        XCTAssertEqual(filter.filter(.nan, at: t[2], scale: faceScale), second)
        XCTAssertEqual(filter.filter(500, at: t[2], scale: .infinity), second)
        XCTAssertEqual(filter.filter(345, at: t[2], scale: faceScale),
                       fresh.filter(345, at: t[2], scale: faceScale))
    }

    /// Разрыв дольше `restartAfter` (лицо уходило) — фильтр начинает заново:
    /// первый кадр после разрыва проходит как есть, дальше — как у свежего
    /// фильтра. Разрыв короче — обычный шаг, без перезапуска.
    func testLongGapRestarts() {
        let t = times(10)
        let x = t.indices.map { 300 + 6 * Double($0) }
        var filter = LipOneEuro(parameters: mediaPipe)
        for i in t.indices { _ = filter.filter(x[i], at: t[i], scale: faceScale) }

        var shortGap = filter
        let afterShort = shortGap.filter(380, at: t[9] + 0.4, scale: faceScale)
        XCTAssertGreaterThan(abs(afterShort - 380), 1e-3)

        let restart = t[9] + 0.6
        XCTAssertEqual(filter.filter(380, at: restart, scale: faceScale), 380)
        var fresh = LipOneEuro(parameters: mediaPipe)
        _ = fresh.filter(380, at: restart, scale: faceScale)
        XCTAssertEqual(filter.filter(392, at: restart + 1.0 / 30, scale: faceScale),
                       fresh.filter(392, at: restart + 1.0 / 30, scale: faceScale))
    }

    /// `reset()` — то же, что свежий фильтр: следующий отсчёт проходит как
    /// есть, а за ним всё совпадает с фильтром, который прошлого не видел.
    func testResetStartsFresh() {
        let t = times(8)
        var filter = LipOneEuro(parameters: mediaPipe)
        for i in 0..<6 { _ = filter.filter(300 + 9 * Double(i), at: t[i], scale: faceScale) }
        filter.reset()
        var fresh = LipOneEuro(parameters: mediaPipe)
        XCTAssertEqual(filter.filter(250, at: t[6], scale: faceScale), 250)
        _ = fresh.filter(250, at: t[6], scale: faceScale)
        XCTAssertEqual(filter.filter(262, at: t[7], scale: faceScale),
                       fresh.filter(262, at: t[7], scale: faceScale))
    }

    // MARK: - Масштаб

    /// Масштаб значения умножает только производную: те же точки в других
    /// единицах (`k·x` при масштабе `scale/k`) фильтруются так же — `k·out`.
    /// Поэтому параметры не зависят от того, насколько лицо близко к камере.
    func testValueScaleEquivariance() {
        let t = times(120)
        let x = t.indices.map { i -> Double in
            let time = Double(i) / 30
            return 300 + 40 * sin(2 * .pi * 1.5 * time) + sin(Double(i * i) * 0.7)
        }
        let base = run(x, at: t, scale: faceScale, parameters: mediaPipe)
        for k in [3.7, 0.25] {
            let scaled = run(x.map { k * $0 }, at: t, scale: faceScale / k, parameters: mediaPipe)
            for (a, b) in zip(base, scaled) { XCTAssertEqual(b, k * a, accuracy: abs(k * a) * 1e-12) }
        }
    }

    /// Масштаб точек — обратный СРЕДНИЙ размер бокса лица, `2/(w + h)`: в этих
    /// единицах («лиц в секунду») стенд подбирал `beta`. Формула с `1/(w + h)`
    /// или `1/max(w, h)` молча сдвинула бы смысл подобранного `beta` вдвое.
    /// Вырожденный бокс даёт конечный масштаб, а не деление на ноль.
    func testValueScaleIsInverseMeanBoxSide() {
        XCTAssertEqual(LipPointsFilter.valueScale(faceBox: CGRect(x: 0, y: 0, width: 200, height: 400)),
                       1.0 / 300, accuracy: 1e-15)
        XCTAssertEqual(LipPointsFilter.valueScale(faceBox: CGRect(x: 512, y: 96, width: 280, height: 320)),
                       1.0 / 300, accuracy: 1e-15)
        XCTAssertEqual(LipPointsFilter.valueScale(faceBox: .zero), 2)
    }

    // MARK: - Точки губ

    /// Каждая координата каждой точки — свой фильтр, ровно как скалярный. Другое
    /// ненулевое число точек (другое созвездие) начинает всё заново. Кадр без
    /// губ (пустой массив) состояние не трогает: одиночный промах Vision не
    /// пускает следующий кадр сырым. `reset()` — снова как свежий фильтр.
    func testPointsFilterRestartsWhenCountChanges() {
        var points = LipPointsFilter(parameters: mediaPipe)
        var scalarX = LipOneEuro(parameters: mediaPipe)
        var scalarY = LipOneEuro(parameters: mediaPipe)
        let t = times(8)
        for i in 0..<5 {
            let input = (0..<3).map { CGPoint(x: 600 + 7 * Double(i) + Double($0), y: 400 - 3 * Double(i)) }
            let out = points.filter(input, at: t[i], scale: faceScale)
            XCTAssertEqual(out.count, 3)
            XCTAssertEqual(out[0].x, scalarX.filter(input[0].x, at: t[i], scale: faceScale))
            XCTAssertEqual(out[0].y, scalarY.filter(input[0].y, at: t[i], scale: faceScale))
        }

        let four = (0..<4).map { CGPoint(x: 660 + Double($0), y: 380) }
        XCTAssertEqual(points.filter(four, at: t[5], scale: faceScale), four)
        var fresh = LipPointsFilter(parameters: mediaPipe)
        _ = fresh.filter(four, at: t[5], scale: faceScale)
        let moved = four.map { CGPoint(x: $0.x + 9, y: $0.y - 2) }
        XCTAssertEqual(points.filter(moved, at: t[6], scale: faceScale),
                       fresh.filter(moved, at: t[6], scale: faceScale))

        XCTAssertEqual(points.filter([], at: t[7], scale: faceScale), [])
        let next = moved.map { CGPoint(x: $0.x + 6, y: $0.y + 3) }
        let afterMiss = points.filter(next, at: t[7] + 1.0 / 30, scale: faceScale)
        XCTAssertEqual(afterMiss, fresh.filter(next, at: t[7] + 1.0 / 30, scale: faceScale))
        XCTAssertNotEqual(afterMiss, next)

        points.reset()
        let again = next.map { CGPoint(x: $0.x - 40, y: $0.y + 25) }
        XCTAssertEqual(points.filter(again, at: t[7] + 2.0 / 30, scale: faceScale), again)
    }

    // MARK: - Золотой вектор

    /// Живой ряд со стенда: y середины нижней губы (внешний контур Vision
    /// rev3/76, пиксели кадра 1280×720) на беззвучной речи, 60 кадров с одним
    /// пропущенным (шаг 2/30 с), масштаб — по боксу лица каждого кадра. Выход —
    /// Python-порт стенда (функция `one_euro` в `analyze.py`; стенд временный,
    /// вне репозитория) во float64 при двух наборах параметров: умолчание
    /// MediaPipe и лучший по стенду. Тот же вектор лежит у стенда:
    /// разойдутся — разошлись порты, и подобранные параметры не перенесутся.
    func testGoldenVector() {
        XCTAssertEqual(goldenTime.count, 60)
        XCTAssertEqual(goldenValue.count, 60)
        XCTAssertEqual(goldenScale.count, 60)
        let sets: [(LipOneEuro.Parameters, [Double])] = [
            (mediaPipe, goldenMediaPipeDefaults),
            (LipOneEuro.Parameters(minCutoff: 1, beta: 80, derivativeCutoff: 2), goldenStandBest),
        ]
        for (parameters, expected) in sets {
            XCTAssertEqual(expected.count, 60)
            var filter = LipOneEuro(parameters: parameters)
            for i in goldenTime.indices {
                let out = filter.filter(goldenValue[i], at: goldenTime[i], scale: goldenScale[i])
                XCTAssertEqual(out, expected[i], accuracy: 1e-9, "\(parameters), кадр \(i)")
            }
        }
    }

    // MARK: - Данные золотого вектора

    // Метки (PTS ролика + 100 с), значения, масштаб 2/(w + h) бокса лица и
    // выход фильтра при двух наборах параметров — литералами из файла стенда.
    private let goldenTime: [Double] = [
        103.433333, 103.466667, 103.5, 103.533333, 103.566667, 103.6,
        103.633333, 103.666667, 103.7, 103.733333, 103.766667, 103.8,
        103.833333, 103.866667, 103.9, 103.933333, 103.966667, 104.0,
        104.033333, 104.066667, 104.1, 104.133333, 104.166667, 104.2,
        104.233333, 104.266667, 104.3, 104.333333, 104.366667, 104.4,
        104.433333, 104.5, 104.533333, 104.566667, 104.6, 104.633333,
        104.666667, 104.7, 104.733333, 104.766667, 104.8, 104.833333,
        104.866667, 104.9, 104.933333, 104.966667, 105.0, 105.033333,
        105.066667, 105.1, 105.133333, 105.166667, 105.2, 105.233333,
        105.266667, 105.3, 105.333333, 105.366667, 105.4, 105.433333
    ]

    private let goldenValue: [Double] = [
        506.629, 506.763, 504.462, 501.576, 494.197, 484.721, 486.34, 491.883,
        496.215, 502.267, 504.871, 504.394, 494.396, 486.577, 483.424, 485.347,
        491.594, 490.243, 491.338, 487.098, 484.533, 487.858, 491.212, 494.432,
        496.446, 492.558, 483.632, 481.911, 483.662, 489.104, 489.205, 490.227,
        489.707, 490.239, 489.689, 483.459, 482.851, 485.282, 491.376, 491.666,
        491.411, 490.521, 488.052, 483.066, 481.283, 481.334, 484.965, 486.828,
        482.669, 479.438, 477.772, 476.995, 473.233, 471.916, 470.331, 470.413,
        471.089, 472.034, 471.369, 471.394
    ]

    private let goldenScale: [Double] = [
        0.003076194255514847, 0.003012329464498191, 0.0030733107547436553,
        0.0030885264331534782, 0.0030878874526781247, 0.0031043656694409345,
        0.0030956589574439764, 0.0030597789003766586, 0.0030614462884555925,
        0.00299491762479073, 0.0030089305057410393, 0.0030182665491554892,
        0.0030272116051184095, 0.0030490593651858397, 0.003114071555136194,
        0.0030839830257574264, 0.0030382023564297475, 0.003049068661977199,
        0.002977014471267345, 0.0030859244812560943, 0.00305413453462625,
        0.0030495335738398815, 0.0030985797659642705, 0.0031832636729132915,
        0.0031699941038109665, 0.0030750118387955793, 0.0030727913543942454,
        0.00309083659674164, 0.003115488025621774, 0.002998141152485459,
        0.0030300551167025728, 0.0029739423174148113, 0.003004311186552703,
        0.003018808687527641, 0.003083155794945474, 0.003070866383532786,
        0.0030884501230747374, 0.0030443346454415657, 0.0030576551454220787,
        0.0030699236509987996, 0.0031039705991904843, 0.0030575242614550146,
        0.003015308722383541, 0.00307243259850987, 0.0030339529676610953,
        0.00310776163468262, 0.003069330026641785, 0.003083231843618481,
        0.003066017488563755, 0.003097193013971438, 0.003093571249586235,
        0.003074860555073827, 0.0031434579923991187, 0.0030814551863972243,
        0.0030488920326353403, 0.0031359464129476957, 0.003053519028003823,
        0.0031456531791543853, 0.003080325652027932, 0.003056159996088115
    ]

    private let goldenMediaPipeDefaults: [Double] = [
        506.629, 506.63484498450623, 505.8226035046698,
        503.4456988715233, 496.4883401624486, 486.6586854484128,
        486.4069510768743, 489.80434020685925, 490.8672453469865,
        497.58054912719024, 502.32927045451356, 503.5412353706064,
        498.0858062761449, 489.25373698273614, 484.6955985262865,
        485.1581569037535, 486.9134439202513, 488.24977981024534,
        488.91092556403316, 487.86424197717315, 485.71718049049514,
        486.5351616002493, 487.9009356984004, 491.5099219454868,
        494.53185284947256, 494.11651634880326, 486.9225803435918,
        483.44243853947614, 483.5707421764797, 484.77061787197124,
        485.6783559228951, 487.7277778739608, 488.06426630870635,
        488.58013689145264, 488.6912178979202, 485.4773142451183,
        483.90917807148213, 484.41470530097035, 488.151860488422,
        489.94146065006237, 490.5904477786098, 490.56994475223075,
        489.95837054212564, 485.716398892003, 482.86860581046096,
        481.954527822389, 482.55597808833727, 483.5735904188283,
        483.1525921395145, 480.87073551865717, 478.89177322187277,
        477.7051182237067, 474.5433875484846, 472.7002811851314,
        471.0349670430175, 470.6248897291514, 470.8974034866267,
        471.44174868229754, 471.40649847711313, 471.40105164596423
    ]

    private let goldenStandBest: [Double] = [
        506.629, 506.6574336313447, 505.45244963175446,
        502.77171165094876, 495.62060918510593, 485.9364913046327,
        486.27199246720653, 489.10799394181026, 493.4865649829899,
        500.4686513913042, 503.9835952421934, 504.2812421405316,
        496.8748309358366, 488.11272894997114, 484.14094604027383,
        485.0518468647919, 488.3202911780048, 488.7226941077571,
        489.75702088191906, 488.03506663853113, 485.5280800451827,
        486.10986099058124, 489.29729505283507, 493.064965200254,
        495.59040240189466, 494.77466190225084, 485.7881953337653,
        482.72068353513225, 483.3399024341028, 486.72539819786255,
        488.0300397029149, 489.5173428584319, 489.58608676090637,
        489.85512788943026, 489.8163853163087, 485.0556698547575,
        483.49152922737665, 484.21915992455774, 489.40960874098414,
        490.9272455785548, 491.2087769372671, 490.94057741617416,
        489.4881681261812, 484.6525828831246, 482.122750543775,
        481.5834791567181, 482.69159631523814, 484.99589381206215,
        483.6537718753948, 480.64000088045157, 478.5700578498258,
        477.4804656119305, 474.19867247630634, 472.4783427013399,
        470.876691665914, 470.56295485033456, 470.8531134256077,
        471.2402140483566, 471.29366388123924, 471.3292889383591
    ]
}
