import SwiftUI

/// Корневая вью главного окна: mesh-фон на всё окно, «парящая» стеклянная
/// плашка сайдбара и контент выбранной секции.
struct MainWindowView: View {
    @ObservedObject var state: MainWindowState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            AppBackground()
                .ignoresSafeArea()

            HStack(spacing: 0) {
                SidebarView(state: state)
                    .frame(width: DS.Sidebar.expanded)
                    .glassSurface(radius: DS.Radius.sidebar, shadow: true)
                    .padding(.leading, DS.Spacing.windowInset)
                    .padding(.vertical, DS.Spacing.windowInset)

                sectionContent
            }
            .ignoresSafeArea()
        }
        .frame(minWidth: 840, minHeight: 560)
    }

    private var sectionContent: some View {
        ZStack {
            Group {
                switch state.section {
                case .home:
                    HomeSectionView()
                case .dashboard:
                    DashboardSectionView()
                case .general:
                    GeneralSectionView()
                case .sound:
                    SoundSectionView()
                case .hotkeys:
                    HotkeysSectionView()
                case .dictionary:
                    DictionarySectionView()
                case .service:
                    ServiceSectionView()
                case .history:
                    HistorySectionView()
                case .transcribe:
                    TranscribeAudioSectionView()
                case .library:
                    LibrarySectionView()
                }
            }
            // Разные identity у секций — иначе SwiftUI не проигрывает transition.
            .id(state.section)
            .transition(.asymmetric(
                insertion: .opacity.combined(with: .offset(y: 10)),
                removal: .opacity
            ))
        }
        .animation(reduceMotion ? nil : DS.Anim.section, value: state.section)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
