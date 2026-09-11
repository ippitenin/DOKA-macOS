import SwiftUI
import AppKit

/// Секция «Общие»: язык, поведение, автозапуск и стиль панели записи.
struct GeneralSectionView: View {
    @ObservedObject var settings = SettingsStore.shared
    @State private var showRestartAlert = false
    /// Значение языка до выбора в пикере — для отката по «Отмене».
    @State private var revertLanguage: AppLanguage?
    /// Программный откат не должен показывать алерт повторно.
    @State private var isReverting = false
    /// Подтверждение удаления всего кэша аудио истории.
    @State private var confirmClearAudio = false
    /// Открыта ли под-страница «Расширенные» (drill-in, как в SuperWhisper).
    @State private var showAdvanced = false

    var body: some View {
        // Смена экрана мгновенная, без слайда — как в SuperWhisper.
        Group {
            if showAdvanced {
                AdvancedSettingsView { showAdvanced = false }
            } else {
                generalForm
            }
        }
        // Переход «сразу в Расширенные» извне (плашка библиотеки о сроке
        // хранения): секция пересоздаётся при каждом показе, запрос забираем тут.
        .onAppear {
            if WindowManager.shared.consumeAdvancedRequest() { showAdvanced = true }
        }
    }

    private var generalForm: some View {
        SettingsForm(title: L("section.general")) {
            SettingsCard {
                SettingsRow(title: L("general.uiLanguage")) {
                    SettingsPopup(
                        titles: AppLanguage.allCases.map(\.title),
                        selectionIndex: Binding(
                            get: { AppLanguage.allCases.firstIndex(of: settings.appLanguage) ?? 0 },
                            set: { settings.appLanguage = AppLanguage.allCases[$0] }
                        )
                    )
                }
                CardDivider()
                SettingsRow(title: L("general.transcriptionLanguage")) {
                    SettingsPopup(
                        titles: TranscriptionLanguage.all.map(\.title),
                        selectionIndex: Binding(
                            get: {
                                TranscriptionLanguage.all.firstIndex { $0.id == settings.language } ?? 0
                            },
                            set: { settings.language = TranscriptionLanguage.all[$0].id }
                        )
                    )
                }
                CardDivider()
                SettingsRow(title: L("general.restoreClipboard")) {
                    SettingsSwitch(isOn: $settings.restoreClipboard)
                }
                CardDivider()
                SettingsRow(title: L("general.launchAtLogin")) {
                    SettingsSwitch(isOn: $settings.launchAtLogin)
                }
            }

            SettingsCard(header: L("general.recorderPanel")) {
                RecorderStylePicker(selection: $settings.recorderStyle)
                    .padding(.horizontal, DS.Spacing.cardPadding)
                    .padding(.vertical, 10)
            }

            SettingsCard(header: L("general.data")) {
                SettingsRow(title: L("general.saveAudio"),
                            help: L("general.saveAudio.subtitle")) {
                    SettingsSwitch(isOn: $settings.saveAudio)
                }
                if settings.saveAudio {
                    CardDivider()
                    SettingsRow(title: L("general.audioRetention")) {
                        SettingsPopup(
                            titles: AudioRetention.allCases.map(\.title),
                            selectionIndex: Binding(
                                get: { AudioRetention.allCases.firstIndex(of: settings.audioRetention) ?? 0 },
                                set: { settings.audioRetention = AudioRetention.allCases[$0] }
                            )
                        )
                    }
                }
                CardDivider()
                HStack {
                    Button(role: .destructive) {
                        confirmClearAudio = true
                    } label: {
                        Label(L("general.clearAudio"), systemImage: "trash")
                            .foregroundStyle(.red)
                    }
                    .dsGlassButton()
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, DS.Spacing.cardPadding)
                .padding(.vertical, 10)
            }
            // Алерт на самой карточке, а не на корне формы: на корне уже висит
            // restart-алерт смены языка, а два .alert на одной вью конфликтуют.
            .alert(L("general.clearAudio.confirm.title"), isPresented: $confirmClearAudio) {
                Button(L("general.clearAudio.confirm.ok"), role: .destructive) {
                    AudioStore.shared.removeAll()
                }
                Button(L("common.cancel"), role: .cancel) {}
            } message: {
                Text(L("general.clearAudio.confirm.message"))
            }

            // Плашка-переход в «Расширенные» (Dock, окно при запуске, папка данных).
            SettingsCard {
                Button {
                    showAdvanced = true
                } label: {
                    HStack(spacing: 12) {
                        Text(L("general.advanced"))
                        Spacer(minLength: 16)
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, DS.Spacing.cardPadding)
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .onChange(of: settings.appLanguage) { oldValue, _ in
            if isReverting {
                isReverting = false
                return
            }
            revertLanguage = oldValue
            showRestartAlert = true
        }
        .alert(L("general.restartAlert.title"), isPresented: $showRestartAlert) {
            Button(L("general.restartAlert.now")) { AppRelaunch.relaunch() }
            Button(L("general.restartAlert.cancel"), role: .cancel) { cancelLanguageChange() }
        } message: {
            Text(L("general.restartAlert.message"))
        }
        // Сменили срок или включили запись — сразу подчищаем просроченное аудио.
        .onChange(of: settings.audioRetention) { _, _ in applyRetention() }
        .onChange(of: settings.saveAudio) { _, isOn in if isOn { applyRetention() } }
    }

    /// Удаляет аудио старше выбранного срока (когда запись включена и срок не «всегда»).
    private func applyRetention() {
        guard settings.saveAudio, let days = settings.audioRetention.days else { return }
        HistoryStore.shared.pruneAudio(olderThan: days)
    }

    /// Отмена смены языка: настройка возвращается к прежнему значению,
    /// didSet в SettingsStore восстанавливает AppleLanguages.
    private func cancelLanguageChange() {
        guard let previous = revertLanguage else { return }
        revertLanguage = nil
        isReverting = true
        settings.appLanguage = previous
    }
}

/// Выбор стиля панели записи карточками-превью.
struct RecorderStylePicker: View {
    @Binding var selection: RecorderStyle

    /// Две строки по три крупные карточки.
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 14), count: 3)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 14) {
            ForEach(RecorderStyle.allCases) { style in
                StylePreviewCard(style: style, isSelected: selection == style) {
                    selection = style
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct StylePreviewCard: View {
    let style: RecorderStyle
    let isSelected: Bool
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack {
                    backdrop
                    preview
                }
                .frame(maxWidth: .infinity)
                .frame(height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(
                            isSelected ? DS.accent : .white.opacity(0.06),
                            lineWidth: isSelected ? 2 : 1
                        )
                )
                Text(style.title)
                    .font(.callout)
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .scaleEffect(isSelected && !reduceMotion ? 1.02 : 1.0)
        .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: isSelected)
    }

    /// Тёмный «мини-экран» — общий фон карточек, чтобы стекло и свечение
    /// читались на нём как на реальном рабочем столе.
    private var backdrop: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(LinearGradient(
                colors: [Color(red: 0.09, green: 0.09, blue: 0.13),
                         Color(red: 0.14, green: 0.12, blue: 0.18)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            ))
    }

    /// Реалистичная миниатюра панели в её стилистике (бренд-цвета, стекло).
    @ViewBuilder
    private var preview: some View {
        switch style {
        case .classic:
            // Внизу по центру — как настоящая панель на экране.
            HStack(spacing: 4) {
                Text("0:12")
                    .font(.system(size: 7, design: .monospaced))
                    .foregroundStyle(.secondary)
                PreviewBars(count: 8)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .glassSurface(radius: 7, forceMaterial: true)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, 12)
        case .mini:
            // Та же капелька, что у «Авроры», но вдвое уже и без свечения
            // краёв экрана — в этом и вся разница между стилями.
            DropPreview(size: CGSize(width: 30, height: 21), look: .mini)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 12)
        case .notch:
            // Чёрная плашка нотча — приклеена к верхней кромке «мини-экрана»
            // без отступа, как настоящая бровка у кромки экрана.
            UnevenRoundedRectangle(
                bottomLeadingRadius: 6,
                bottomTrailingRadius: 6,
                style: .continuous
            )
            .fill(.black)
            .frame(width: 64, height: 16)
            .overlay(
                HStack(spacing: 7) {
                    PreviewBars(count: 4)
                    Text("0:12")
                        .font(.system(size: 6, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.7))
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        case .aurora:
            // Нижнее тёплое свечение (подсветка края экрана) + плашка по центру.
            ZStack {
                Rectangle().fill(LinearGradient(stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .clear, location: 0.5),
                    .init(color: DS.glow.opacity(0.50), location: 1)
                ], startPoint: .top, endPoint: .bottom))
                Circle().fill(DS.glow)
                    .frame(width: 56, height: 56).blur(radius: 18)
                    .opacity(0.6).offset(x: -48, y: 40)
                Circle().fill(DS.coral)
                    .frame(width: 46, height: 46).blur(radius: 16)
                    .opacity(0.45).offset(x: 54, y: 40)
                // Капелька внизу по центру — как настоящая на экране
                // (главное в стиле — свечение краёв, оно уже внизу).
                // Тот же шейдер, что и в живой панели, со статичной фазой.
                DropPreview(size: CGSize(width: 60, height: 15), look: .aurora)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 12)
            }
        case .studio:
            // Компактная стеклянная плашка у нижней кромки «мини-экрана» —
            // соразмерно реальной панели (она не во весь экран, а прижата
            // к низу), как у остальных стилей.
            VStack {
                Spacer()
                ZStack {
                    StudioPreviewSpectrum()
                        .padding(.horizontal, 6)
                    Text("0:12")
                        .font(.system(size: 7, weight: .medium, design: .monospaced))
                        .foregroundStyle(.primary)
                        .shadow(color: .black.opacity(0.4), radius: 2)
                }
                .frame(width: 118, height: 30)
                .glassSurface(radius: 8, forceMaterial: true)
                .padding(.bottom, 8)
            }
        case .hidden:
            Image(systemName: "eye.slash")
                .font(.system(size: 16))
                .foregroundStyle(DS.accent.opacity(0.9))
        }
    }
}

/// Мини-спектр для превью «Студии»: тонкие персиковые столбики с
/// колоколообразной огибающей и затухающими кончиками. Масштаб — под
/// компактную плашку превью (высотой ~30), а не во всю карточку.
private struct StudioPreviewSpectrum: View {
    private static let count = 26

    var body: some View {
        let half = Double(Self.count - 1) / 2
        HStack(spacing: 1.3) {
            ForEach(0..<Self.count, id: \.self) { index in
                let x = (Double(index) - half) / half          // −1…1
                let env = max(0.12, 1 - x * x)                 // центр выше
                Capsule()
                    .fill(LinearGradient(
                        colors: [.clear, DS.accent, .clear],
                        startPoint: .top, endPoint: .bottom
                    ))
                    .frame(width: 1.4, height: 3 + CGFloat(env) * 17)
                    .opacity(0.4 + env * 0.6)
            }
        }
    }
}

private struct PreviewBars: View {
    let count: Int

    var body: some View {
        HStack(spacing: 1.5) {
            ForEach(0..<count, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(LinearGradient(
                        colors: [DS.accent, DS.coral],
                        startPoint: .top, endPoint: .bottom
                    ))
                    .opacity(index < count * 2 / 3 ? 1 : 0.3)
                    .frame(width: 2, height: 4 + CGFloat(index % 4) * 2.0)
            }
        }
    }
}
