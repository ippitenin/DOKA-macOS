//  AuroraDrop.metal
//  Эффекты «капельки» стиля «Аврора»: волна во время записи, жидкие точки во
//  время распознавания и стеклянная оболочка с преломлением содержимого.
//  Все три — [[stitchable]] для SwiftUI (`colorEffect` / `layerEffect`, macOS 14+).
//
//  ВНИМАНИЕ: файл лежит ВНЕ Sources намеренно — SwiftPM .metal не компилирует,
//  а лежащий в Sources выдаёт предупреждение «unhandled file» и роняет гейт
//  предупреждений. Сборка — scripts/build-shaders.sh (зовётся из build.sh).
//
//  Палитра НЕ хардкодится: цвета приходят аргументами из DS (дизайн-система).
//  Числовые константы формы подобраны не на глаз: это параметры эталонного
//  эффекта (см. CLAUDE.md), при которых волна выглядит «сочно». Менять их
//  наугад не стоит — сперва прогон офскрин-превью.

#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>

using namespace metal;

namespace doka {

inline float sat(float v) { return clamp(v, 0.0f, 1.0f); }

/// Плавный шаг 3t²−2t³ на уже нормированном значении.
inline float smoothUnit(float v) { return v * v * (3.0f - 2.0f * v); }

/// Мягкий минимум (polynomial smooth min) — склеивает SDF-фигуры в каплю.
inline float smoothMin(float a, float b, float k) {
    float h = max(k - fabs(a - b), 0.0f) / k;
    return min(a, b) - h * h * k * 0.25f;
}

/// Палитра из трёх цветов по индексу нити/сэмпла.
inline float3 paletteAt(int index, float3 c0, float3 c1, float3 c2) {
    int i = index % 3;
    return (i == 0) ? c0 : ((i == 1) ? c1 : c2);
}

/// Знаковое расстояние до горизонтальной капсулы с центром в середине `size`.
inline float capsuleSDF(float2 pos, float2 size, thread float2 &normal) {
    float2 d = pos - size * 0.5f;
    float r = max(size.y * 0.5f, 0.0001f);
    float flat = max(size.x * 0.5f - r, 0.0f);
    float2 q = float2(max(fabs(d.x) - flat, 0.0f), d.y);
    float len = length(q);
    normal = (len > 0.0001f) ? normalize(float2(q.x * sign(d.x), q.y))
                             : float2(0.0f, 1.0f);
    return len - r;
}

}

// MARK: - Волна (состояние «идёт запись»)

/// Три синусоидальные нити с расходящейся фазой: вокруг каждой ореол `1/r`,
/// между ними наливается свет, ядро выбеливается на пиках. Амплитуда и яркость
/// растут от уровня микрофона, к торцам всё сходит на нет.
///
/// - Parameters:
///   - size: размер вью в точках;
///   - phase: фаза бега волны (интегрируется в Swift — скорость зависит от голоса);
///   - level: уровень микрофона 0…1.
[[ stitchable ]] half4 dokaDropWave(
    float2 position, half4 color,
    float2 size, float phase, float level,
    half3 c0, half3 c1, half3 c2, half3 hi)
{
    using namespace doka;

    constexpr float kAmplitude  = 0.22f;   // базовая амплитуда нити
    constexpr float kLowAmp     = 6.0f;    // добавка амплитуды от голоса (×0.01)
    constexpr float kFreq       = 1.1f;    // частота вдоль капсулы
    constexpr float kAberration = 2.6f;    // расхождение фаз крайних нитей
    constexpr float kThickness  = 3.0f;    // толщина ядра нити (×0.01)
    constexpr float kIntensity  = 2.0f;    // яркость ореола (×0.01)
    constexpr float kLowGlow    = 1.5f;    // добавка яркости от голоса
    constexpr float kSoftness   = 2.5f;    // мягкость ореола (×0.01)
    constexpr float kBandFill   = 3.0e4f;  // заливка между нитями (×0.0001)
    constexpr float kBandThick  = 0.08f;
    constexpr float kFalloff    = 1.7f;    // гауссово затухание к торцам
    constexpr float kEdgeMask   = 0.4f;    // растворение у верхней/нижней кромки
    constexpr float kWaveScale  = 0.9f;    // масштаб поля волны

    float lo = sat(level);
    float thickness = kThickness * 0.01f;
    float glowK = (lo * kLowGlow + kIntensity) * 0.01f;
    float softness = kSoftness * 0.01f;
    float fillK = kBandFill * 0.0001f * glowK;
    float amp = (kLowAmp * 0.01f) * lo + kAmplitude;

    float2 uv = (position + 0.5f) * 2.0f / size - 1.0f;
    float aspect = size.x / size.y;
    uv.x *= aspect;
    float2 p = uv / max(kWaveScale, 0.01f);

    // Опорные пропорции капельки. Фаза считается в ЭТИХ единицах, а не в
    // фактических: иначе при росте ширины волна уплотняется (больше колебаний
    // на ту же капсулу), а нужно, чтобы картинка просто растягивалась.
    constexpr float kRefAspect = 90.0f / 63.0f;
    float aC = max(aspect, 1.0f);
    float px = p.x / aC;
    float py = p.y;
    float xArg = px * kRefAspect;

    // Огибающая: нити прижимаются к оси у торцов.
    float env = pow(cos(min(fabs(px * 0.9f), 1.0f) * M_PI_F * 0.5f), 2.0f);
    float centerWave = env * amp * sin(xArg * kFreq + phase);

    float3 base = float3(0.0f);
    float3 highlight = float3(0.0f);
    float baseWeight = 0.0001f;
    float highlightWeight = 0.0001f;

    for (int i = 0; i < 3; ++i) {
        float t = float(i) * 0.5f;                       // 0, 0.5, 1
        float3 hue = paletteAt(i, float3(c0), float3(c1), float3(c2));

        float w = env * amp * sin(xArg * kFreq + phase + mix(-kAberration, kAberration, t));
        float dist = fabs(py - w);
        float radius = sqrt(dist * dist + softness * softness) + thickness;
        float halo = glowK / radius;

        // Свет между этой нитью и центральной — «тело» волны.
        float band = max(0.0f, max(py - max(centerWave, w), min(centerWave, w) - py));
        float fill = fillK / (band + kBandThick);

        float energy = halo + fill;
        base += hue * energy;
        highlight += float3(hi) * energy;
        baseWeight += max(max(hue.r, hue.g), hue.b);
        highlightWeight += max(max(float3(hi).r, float3(hi).g), float3(hi).b);
    }

    float3 col = base / baseWeight;
    float3 hiCol = highlight / highlightWeight;

    // Центральная нить светится отдельно, сумма возводится в степень —
    // так пики уходят в пересвет, а полутона остаются цветными.
    float dC = fabs(py - centerWave);
    float softC = 1.0f / (pow(dC * 0.02f, 2.0f) + 1.0f);
    float centerGlow = (glowK * 0.5f * softC) / (dC + thickness);
    float3 boosted = pow(float3(centerGlow) + col, float3(1.5f));

    float energy = max(max(boosted.r, boosted.g), boosted.b);
    float iceMix = smoothstep(0.35f, 0.95f, sat(energy));
    float3 tint = col / max(max(max(col.r, col.g), col.b), 0.0001f);
    float3 hiTint = hiCol / max(max(max(hiCol.r, hiCol.g), hiCol.b), 0.0001f);
    float3 outCol = mix(tint, hiTint, iceMix) * energy;

    float edge = sat((1.0f - fabs(py)) / max(kEdgeMask, 0.0001f));
    outCol *= smoothUnit(edge) * exp(-pow(px * kFalloff, 2.0f));

    float peak = max(max(outCol.r, outCol.g), outCol.b);
    outCol *= (peak > 1.0f) ? (1.0f / peak) : 1.0f;

    float alpha = sat(peak * 1.15f) * float(color.a);
    return half4(half3(outCol), half(alpha));
}

// MARK: - Точки (состояние «идёт распознавание»)

/// Шесть пар светящихся капель по кольцу, склеенных мягким минимумом. Кольцо
/// вращается, каждая пара по очереди «дышит» размером почти от нуля до полного.
///
/// - Parameter appear: 0…1 — появление (кольцо стягивается к центру на нуле).
[[ stitchable ]] half4 dokaDropDots(
    float2 position, half4 color,
    float2 size, float time, float appear,
    half3 c0, half3 c1, half3 c2)
{
    using namespace doka;

    constexpr int   kDots       = 6;
    constexpr int   kSamples    = 5;      // сэмплов аберрации (у эталона 12 — дорого)
    constexpr float kRing       = 0.45f;
    constexpr float kDotRadius  = 0.1f;
    constexpr float kPairOffset = 0.085f;
    constexpr float kPairSmooth = 0.2f;
    constexpr float kBlend      = 0.2f;
    constexpr float kRotation   = 1.4f;
    constexpr float kScaleDur   = 2.0f;   // период «дыхания», с
    constexpr float kStagger    = 0.167f; // сдвиг фаз по кругу (1/6)
    constexpr float kScaleMin   = 0.001f;
    constexpr float kScaleMax   = 0.65f;
    constexpr float kGlow       = 0.04f;
    constexpr float kFalloffPow = 0.7f;
    constexpr float kFadeStart  = 0.0f;
    constexpr float kFadeEnd    = 0.7f;
    constexpr float kAberration = 0.05f;

    float app = sat(appear);

    // Единицы — полувысоты вью: кольцо круглое при любой ширине.
    float half_ = max(min(size.x, size.y) * 0.5f, 0.0001f);
    float2 P = (position + 0.5f - size * 0.5f) / half_;

    float spin = time * kRotation;

    float2 centersA[kDots];
    float2 centersB[kDots];
    float2 dirs[kDots];
    float  radii[kDots];

    for (int i = 0; i < kDots; ++i) {
        float fi = float(i);
        float angle = fi * (M_PI_F / 3.0f) + spin;
        float2 dir = float2(cos(angle), sin(angle));
        float2 perp = float2(-dir.y, dir.x);

        // Треугольная волна с фазовым сдвигом — капли пульсируют по очереди.
        float fr = fract((fi * kStagger * kScaleDur + time) / kScaleDur);
        float tri = 1.0f - fabs(fr * 2.0f - 1.0f);
        float amp = mix(kScaleMin, kScaleMax, smoothUnit(sat(tri)));

        float2 base = dir * (kRing * app);
        float spread = kPairOffset * amp * app;
        centersA[i] = base - perp * spread;
        centersB[i] = base + perp * spread;
        dirs[i] = dir;
        radii[i] = amp * kDotRadius;
    }

    float3 acc = float3(0.0f);
    float3 weight = float3(0.0001f);

    for (int s = 0; s < kSamples; ++s) {
        float3 hue = paletteAt(s, float3(c0), float3(c1), float3(c2));
        float2 offset = float2(kAberration * float(s) / float(kSamples));

        float field = 1.0e9f;
        for (int i = 0; i < kDots; ++i) {
            float2 p = P + offset * dirs[i];
            float dA = length(p - centersA[i]) - radii[i];
            float dB = length(p - centersB[i]) - radii[i];
            float pair = smoothMin(dA, dB, kPairSmooth);
            field = smoothMin(field, pair, kBlend);
        }

        float d = max(field, 0.0f);
        float glow = sat(kGlow / pow(d + 0.0001f, kFalloffPow));
        float fadeT = sat((d - kFadeStart) / max(kFadeEnd - kFadeStart, 0.0001f));
        acc += hue * (glow * (1.0f - smoothUnit(fadeT)));
        weight += hue;
    }

    // Оттенок отдельно от яркости: иначе сумма сэмплов в центре капли
    // насыщает все каналы и точки выцветают в белые пятна.
    float3 mixed = acc / weight;
    float energy = max(max(mixed.r, mixed.g), mixed.b);
    float3 tint = mixed / max(energy, 0.0001f);
    float core = smoothstep(0.85f, 2.2f, energy);
    float3 col = mix(tint, float3(c2), core) * min(energy, 1.0f) * app;

    float peak = max(max(col.r, col.g), col.b);
    float alpha = sat(peak * 1.05f) * float(color.a);
    return half4(half3(col), half(alpha));
}

// MARK: - Стекло

/// Стеклянная оболочка капельки: содержимое слоя преломляется у кромки (свет
/// «заламывается», как в толстом стекле), по самому краю идёт светящийся блик
/// с угловым градиентом. Вне капсулы — прозрачность.
///
/// Кромка умеет быть ЖИВОЙ (стиль «Мини»): свет волны вытекает на обводку,
/// бежит по ней приливами и расщепляется хроматической аберрацией — «Аврора»
/// передаёт `bleed/tide/aberration` нулями и получает прежний ровный блик,
/// поэтому отдельной функции для неё не нужно.
///
/// - Parameters:
///   - refract: сила преломления в точках (сдвиг сэмпла у кромки);
///   - rimAmount: яркость блика; rimWidth — его ширина в точках;
///   - phase: фаза бега волны (та же, что у `dokaDropWave` — приливы
///     ускоряются под голос вместе с ней);
///   - bleed: 0…1 — насколько кромка подчиняется содержимому под ней;
///   - tide: 0…1 — глубина приливов вдоль кромки;
///   - aberration: доля от `refract` на расхождение каналов R/B.
[[ stitchable ]] half4 dokaDropGlass(
    float2 position, SwiftUI::Layer layer,
    float2 size, float refract, float rimAmount, float rimWidth,
    half3 rimTop, half3 rimBottom,
    float phase, float bleed, float tide, float aberration)
{
    using namespace doka;

    float2 normal;
    float sdf = capsuleSDF(position, size, normal);
    float r = max(size.y * 0.5f, 0.0001f);

    // Толщина «стекла» растёт к краю — там же сильнее преломление.
    float t = sat(1.0f + sdf / r);
    float bend = pow(t, 2.6f);
    float depth = bend * refract;

    // Хроматическая аберрация: красный преломляется слабее синего, у кромки
    // свет расщепляется. При aberration = 0 все три сэмпла совпадают.
    float ab = sat(aberration);
    half4 sG = layer.sample(position - normal * depth);
    half4 sR = layer.sample(position - normal * (depth * (1.0f - ab)));
    half4 sB = layer.sample(position - normal * (depth * (1.0f + ab)));
    float3 sampleRGB = float3(sR.r, sG.g, sB.b);
    float sampleA = max(float(sG.a), max(float(sR.a), float(sB.a)));

    // Блик по кромке: узкая полоса вокруг sdf ≈ 0, цвет — по вертикали.
    float band = exp(-pow(sdf / max(rimWidth, 0.5f), 2.0f));
    float2 d = position - size * 0.5f;
    float vertical = sat(d.y / r * 0.5f + 0.5f);
    float3 rim = mix(float3(rimTop), float3(rimBottom), vertical);

    // Что светится ПОД кромкой: сэмпл заметно глубже преломлённого — именно
    // он даёт «волна забежала на обводку».
    float bleedDepth = rimWidth * 2.0f + refract * 1.5f;
    half4 inner = layer.sample(position - normal * bleedDepth);
    float3 innerRGB = float3(inner.rgb);
    float lit = max(max(innerRGB.r, innerRGB.g), innerRGB.b) * float(inner.a);

    // Приливы вдоль кромки. Параметр — в полувысотах, а не долях ширины:
    // при стягивании капсулы в круг узор укорачивается, но не сжимается.
    float along = d.x / r;
    float side = (d.y >= 0.0f) ? 1.0f : -1.0f;      // верх и низ бегут навстречу
    float fast = 0.5f + 0.5f * sin(along * 2.6f * side - phase * 0.55f);
    float slow = 0.5f + 0.5f * sin(along * 1.1f + phase * 0.31f * side);
    float tideWave = 0.6f * fast + 0.4f * slow;
    float tideFactor = mix(1.0f - sat(tide), 1.0f, tideWave);

    // Мягкая граница: жёсткий step дал бы рваный край на Retina.
    float inside = 1.0f - smoothstep(-1.0f, 0.5f, sdf);
    float dynamic = mix(1.0f, (0.30f + 1.5f * lit) * tideFactor, sat(bleed));
    float rimEnergy = band * rimAmount * inside * dynamic;

    // Оттенок кромки подхватывается у содержимого: пик волны у края красит
    // обводку в свой цвет, а не в фиксированный токен.
    float tintMix = sat(bleed) * smoothstep(0.05f, 0.6f, lit);
    float3 innerTint = innerRGB / max(max(max(innerRGB.r, innerRGB.g), innerRGB.b), 0.0001f);
    rim = mix(rim, innerTint, tintMix);

    float3 col = sampleRGB + rim * rimEnergy;
    float peak = max(max(col.r, col.g), col.b);
    col *= (peak > 1.0f) ? (1.0f / peak) : 1.0f;

    float alpha = max(sampleA, rimEnergy) * inside;
    return half4(half3(col), half(alpha));
}
