import SwiftUI

/// Сайдбар главного окна: прокручиваемый список секций и плашка обновления,
/// приклеенная к нижней кромке. Фон даёт стеклянная плашка в MainWindowView,
/// ширина фиксированная.
///
/// Список уезжает вверх ПОД зону кнопок окна (54 pt) в прогрессивный блюр:
/// размытие нарастает к кромке попиксельно, у самого края контент
/// растворяется в стекле (шейдер `dokaEdgeBlur`, `Shaders/EdgeBlur.metal`) —
/// как боковая колонка «Системных настроек» (решения владельца 8.11.2026).
/// Системный `scrollEdgeEffectStyle` пробовали (под прозрачным
/// `safeAreaBar`) — в нашем сайдбаре он не рисуется вовсе: эффект есть
/// только у системных сайдбаров и тулбаров, а этот — своя стеклянная плашка.
/// Шейдер стоит на КОНТЕНТЕ прокрутки, а не на `ScrollView`: на macOS это
/// NSScrollView, а платформенные вью `layerEffect` не рисует. В покое
/// эффект выключен и включается плавно с первыми пунктами прокрутки.
/// Нижний край — мягкий фейд над плашкой, только если ниже есть пункты.
struct SidebarView: View {
    @ObservedObject var state: MainWindowState
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var updates = UpdateController.shared
    @Namespace private var selectionNS
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Есть ли контент за верхним / нижним краем прокрутки.
    @State private var overflow = EdgeOverflow()
    /// `contentOffset.y` прокрутки — для шейдера края.
    @State private var scrollOffset: CGFloat = -Self.titlebar

    /// Высота фейда у нижнего края прокрутки.
    private static let fade: CGFloat = 22

    private var groups: [(titleKey: String?, sections: [MainSection])] {
        MainSection.sidebarGroups(lipsEnabled: settings.lipsExperiment)
    }

    /// Зона кнопок окна: с unified-тулбаром они сидят по центру
    /// 52-пунктового тайтлбара, внутри плашки.
    private static let titlebar: CGFloat = 54
    /// Запас над первым пунктом внутри слоя шейдера: свечение выбранной
    /// пилюли выходит за её рамку и обрезалось бы границей слоя.
    private static let glowRoom: CGFloat = 8
    /// Зона блюра (на ~строку ниже зоны кнопок — размытие нарастает плавно
    /// через несколько пунктов, а не обрывается на одном) и радиус у кромки.
    /// Подобраны офскрин-рендером шейдера 8.11.2026.
    private static let blurZone: CGFloat = titlebar + 32
    private static let blurRadius: CGFloat = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView(.vertical) {
                edgeBlurred(
                    sectionList
                        .padding(.top, Self.glowRoom)
                        .padding(.bottom, 10)
                )
            }
            .contentMargins(.top, Self.titlebar - Self.glowRoom, for: .scrollContent)
            // `.never`, а не `.hidden`: иначе при прокрутке колесом система
            // всё равно показывает overlay-скроллер поверх пунктов.
            .scrollIndicators(.never)
            .onScrollGeometryChange(for: EdgeOverflow.self) { geo in
                EdgeOverflow(geometry: geo)
            } action: { _, new in
                overflow = new
            }
            .onScrollGeometryChange(for: CGFloat.self) { geo in
                geo.contentOffset.y
            } action: { _, new in
                scrollOffset = new
            }
            .mask { edgeMask }

            if let banner = updates.banner {
                UpdateBanner(model: banner, updates: updates)
                    .padding(.horizontal, 10)
                    .padding(.top, 4)
                    .padding(.bottom, 10)
                    .transition(reduceMotion ? .opacity
                                : .opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(reduceMotion ? nil : DS.Anim.section, value: updates.banner)
    }

    /// Сила блюра: 0 в покое, до 1 за первые 24 pt прокрутки — без рывка.
    private var blurStrength: CGFloat {
        let scrolled = scrollOffset + (Self.titlebar - Self.glowRoom)
        return min(max(scrolled / 24, 0), 1)
    }

    @ViewBuilder
    private func edgeBlurred<Content: View>(_ content: Content) -> some View {
        if DropShaders.isAvailable {
            content.layerEffect(
                ShaderLibrary.bundle(.module).dokaEdgeBlur(
                    .float(Float(scrollOffset)),
                    .float(Float(Self.blurZone)),
                    .float(Float(Self.blurRadius)),
                    .float(Float(blurStrength))
                ),
                maxSampleOffset: CGSize(width: Self.blurRadius, height: Self.blurRadius),
                isEnabled: blurStrength > 0
            )
        } else {
            content
        }
    }

    /// Маска: снизу — прозрачный спад над плашкой; сверху — только если нет
    /// шейдера (без `default.metallib`), тогда край хотя бы растворяется.
    private var edgeMask: some View {
        VStack(spacing: 0) {
            if !DropShaders.isAvailable {
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                    .frame(height: overflow.top ? Self.titlebar : 0)
            }
            Color.black
            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: overflow.bottom ? Self.fade : 0)
        }
        .animation(DS.Anim.control, value: overflow)
    }

    private var sectionList: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                VStack(alignment: .leading, spacing: 2) {
                    if let titleKey = group.titleKey {
                        Text(L(titleKey))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.leading, 12)
                            .padding(.bottom, 3)
                    }
                    ForEach(group.sections) { section in
                        SidebarItemView(
                            section: section,
                            isSelected: state.section == section,
                            namespace: selectionNS
                        ) {
                            withAnimation(reduceMotion ? nil : DS.Anim.section) {
                                state.section = section
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 10)
    }
}

/// Есть ли контент за краями прокрутки (порог — полпункта, чтобы дрожание
/// при упругой прокрутке не мигало фейдом).
struct EdgeOverflow: Equatable {
    var top = false
    var bottom = false

    init() {}

    init(geometry geo: ScrollGeometry) {
        let offset = geo.contentOffset.y + geo.contentInsets.top
        top = offset > 0.5
        bottom = geo.contentSize.height - offset - geo.containerSize.height > 0.5
    }
}

/// Пункт сайдбара: цветная плитка-иконка + название, hover-подсветка
/// и скользящая «пилюля» выделения (matchedGeometryEffect).
private struct SidebarItemView: View {
    let section: MainSection
    let isSelected: Bool
    let namespace: Namespace.ID
    let action: () -> Void

    @State private var hovering = false
    /// Счётчик прыжков иконки: растёт только при ВЫБОРЕ пункта — иначе
    /// прыгала бы и иконка пункта, с которого ушли (у него тоже меняется `isSelected`).
    @State private var bounceCount = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                // Секция DOKA — фирменная лого-марка вместо SF-символа.
                if section == .home {
                    LogoIconTile(size: 24)
                } else {
                    IconTile(symbol: section.symbol, color: section.tileColor,
                             size: 24, bounce: bounceCount)
                }
                Text(section.title)
                    .font(.body)
                    .foregroundStyle(isSelected ? Color.white : .primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        // Системное синее кольцо фокуса выбивается из дизайна.
        .focusEffectDisabled()
        .background {
            if isSelected {
                selectionPill
            } else if hovering {
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(0.07))
            }
        }
        .onHover { hovering = $0 }
        .onChange(of: isSelected) { _, selected in
            if selected { bounceCount += 1 }
        }
        .animation(reduceMotion ? nil : DS.Anim.hover, value: hovering)
    }

    /// «Таблетка» выделения: акцентный градиент с мягким свечением.
    /// glassEffect здесь намеренно не используется: внутри контейнера стекло
    /// позиционируется самим контейнером и конфликтует с matchedGeometryEffect
    /// (пилюля отрисовывалась отдельным блоком).
    private var selectionPill: some View {
        Capsule(style: .continuous)
            .fill(
                LinearGradient(
                    colors: [DS.accent, DS.accent.opacity(0.82)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .shadow(color: DS.accent.opacity(0.40), radius: 7, y: 2)
            .matchedGeometryEffect(id: "selection", in: namespace)
    }
}

/// Цветная плитка с белым SF Symbol — как иконки разделов Системных настроек,
/// но с подсвеченной верхней кромкой и градиентом на символе.
struct IconTile: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 24
    /// Триггер symbol-анимации: каждое новое значение — один прыжок иконки.
    var bounce: Int = 0
    /// Непрерывное «дыхание» символа (только macOS 15+, ниже — статично).
    var breathe: Bool = false

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [color.opacity(0.85), color],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .frame(width: size, height: size)
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(0.35), .white.opacity(0.05)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 0.5
                    )
            )
            .overlay(symbolImage)
            .shadow(color: .black.opacity(0.10), radius: 1, y: 0.5)
    }

    @ViewBuilder
    private var symbolImage: some View {
        let base = Image(systemName: symbol)
            .font(.system(size: size * 0.52, weight: .medium))
            .foregroundStyle(
                LinearGradient(
                    colors: [.white, .white.opacity(0.8)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .symbolEffect(.bounce, value: bounce)
        if breathe {
            base.symbolEffect(.breathe)
        } else {
            base
        }
    }
}
