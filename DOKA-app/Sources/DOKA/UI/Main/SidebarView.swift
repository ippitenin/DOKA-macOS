import SwiftUI

/// Сайдбар главного окна: шапка с логотипом и список секций.
/// Фон даёт стеклянная плашка в MainWindowView, ширина фиксированная.
struct SidebarView: View {
    @ObservedObject var state: MainWindowState
    @Namespace private var selectionNS
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Смысловые группы секций: первая — без заголовка,
    /// дальше — как Favourites/Locations в Finder.
    private static let groups: [(titleKey: String?, sections: [MainSection])] = [
        (nil, [.home, .dashboard]),
        ("sidebar.group.dictation", [.transcribe, .library, .history, .dictionary]),
        ("sidebar.group.settings", [.general, .sound, .hotkeys, .service])
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Зона трафик-лайтов: с unified-тулбаром кнопки окна сидят
            // по центру 52-пунктового тайтлбара, внутри плашки.
            Spacer().frame(height: 54)

            VStack(alignment: .leading, spacing: 18) {
                ForEach(Array(Self.groups.enumerated()), id: \.offset) { _, group in
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

            Spacer()
        }
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                // Секция DOKA — фирменная лого-марка вместо SF-символа.
                if section == .home {
                    LogoIconTile(size: 24)
                } else {
                    IconTile(symbol: section.symbol, color: section.tileColor,
                             size: 24, bounce: isSelected)
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
    /// Триггер symbol-анимации: смена значения заставляет иконку подпрыгнуть.
    var bounce: Bool = false
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
        if breathe, #available(macOS 15.0, *) {
            base.symbolEffect(.breathe)
        } else {
            base
        }
    }
}
