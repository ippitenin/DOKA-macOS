//  EdgeBlur.metal
//  Прогрессивный блюр верхнего края прокрутки сайдбара: список уезжает под
//  кнопки окна, размытие нарастает к кромке ПОПИКСЕЛЬНО, а у самого края
//  контент растворяется в стекле — как системный scroll edge effect Apple.
//  Системный `scrollEdgeEffectStyle` в нашем сайдбаре не рисуется (он только
//  у системных сайдбаров и тулбаров), поэтому эффект свой.
//  [[stitchable]] для SwiftUI `layerEffect` (macOS 14+).
//
//  Файл ВНЕ Sources намеренно — см. шапку AuroraDrop.metal и
//  scripts/build-shaders.sh.

#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>

using namespace metal;

namespace dokaEdge {
inline float sat(float v) { return clamp(v, 0.0f, 1.0f); }
inline float smoothUnit(float v) { return v * v * (3.0f - 2.0f * v); }
}

/// position — точка в координатах КОНТЕНТА прокрутки; offset — сдвиг
/// прокрутки (contentOffset.y), так что `position.y - offset` — высота над
/// верхней кромкой видимой области. edge — высота зоны эффекта, maxRadius —
/// радиус размытия у самой кромки, strength — 0…1 (0 в покое, растёт с
/// первыми пунктами прокрутки, чтобы эффект не включался рывком).
[[ stitchable ]] half4 dokaEdgeBlur(float2 position, SwiftUI::Layer layer,
                                    float offset, float edge, float maxRadius,
                                    float strength) {
    float y = position.y - offset;
    float t = dokaEdge::smoothUnit(1.0f - dokaEdge::sat(y / edge)) * strength;
    if (t <= 0.001f) {
        return layer.sample(position);
    }

    // Размытие по диску: 24 точки по спирали Фогеля (равномерно без сетки),
    // вес чуть падает к краю диска — мягче, без «кольца».
    float radius = maxRadius * t;
    const int count = 24;
    half4 sum = half4(0.0h);
    float weights = 0.0f;
    for (int i = 0; i < count; i++) {
        float fi = float(i) + 0.5f;
        float r = sqrt(fi / float(count)) * radius;
        float angle = fi * 2.39996323f;
        float2 tap = position + float2(cos(angle), sin(angle)) * r;
        float w = 1.0f - 0.5f * (r / max(radius, 0.001f));
        sum += layer.sample(tap) * half(w);
        weights += w;
    }
    half4 color = sum / half(weights);

    // Уход в непрозрачность: верхняя часть зоны растворяет контент в стекле
    // (цвет премультиплицирован — множим все каналы).
    float fade = 1.0f - dokaEdge::smoothUnit(dokaEdge::sat((t - 0.3f) / 0.7f));
    return color * half(fade);
}
