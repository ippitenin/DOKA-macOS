import SwiftUI

/// Под-страница «О DOKA» секции «Общие»: логотип, версия, проверка
/// обновлений и их настройки. Списка компонентов и ссылок на GitHub нет
/// намеренно — решение владельца 8.11.2026: в приложении нет путей на GitHub
/// (уведомление GPL-3.0 — в бинарнике и в «Свойствах» Finder).
struct AboutView: View {
    @ObservedObject var updates = UpdateController.shared
    let onBack: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.cardPadding) {
                backButton
                header
                    .padding(.top, 6)
                    .padding(.bottom, 4)
                if updates.isAvailable {
                    statusCard
                    settingsCard
                } else {
                    selfBuildCard
                }
            }
            .padding(.horizontal, DS.Spacing.section)
            .padding(.top, 46)
            .padding(.bottom, 20)
        }
    }

    private var backButton: some View {
        Button(action: onBack) {
            HStack(spacing: 5) {
                Image(systemName: "chevron.left")
                    .font(.footnote.weight(.semibold))
                Text(L("advanced.back"))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(DS.accent)
    }

    private var header: some View {
        HStack(spacing: 16) {
            DokaBrandLogo(size: 72)
            VStack(alignment: .leading, spacing: 3) {
                Text("DOKA")
                    .font(.largeTitle.weight(.bold))
                Text(L("about.version", AppVersion.short, AppVersion.build))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Text(L("about.tagline"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Обновления

    /// Карточка статуса. Раскладка НЕ меняется ни в одном состоянии: две
    /// строки текста всегда, иконка в рамке фиксированного размера, кнопки в
    /// общем слоте постоянной ширины — нажатие «Проверить обновления» только
    /// перекрёстно проявляет тексты, без скачков высоты и ширины (HIG; прежняя
    /// версия теряла подзаголовок на время проверки и прыгала дважды).
    private var statusCard: some View {
        SettingsCard {
            HStack(spacing: 12) {
                statusIcon
                    .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(statusTitle)
                        .contentTransition(.opacity)
                    Text(statusSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .contentTransition(.opacity)
                }
                Spacer(minLength: 16)
                statusAction
            }
            .padding(.horizontal, DS.Spacing.cardPadding)
            .padding(.vertical, 11)
            .animation(reduceMotion ? nil : DS.Anim.section, value: updates.state)
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch updates.state {
        case .checking, .waitingForIdle, .downloading, .installing:
            ProgressView().controlSize(.small)
                .transition(.opacity)
        case .ready:
            Image(systemName: "arrow.down.circle.fill")
                .font(.title3).foregroundStyle(DS.accent)
                .transition(.opacity)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title3).foregroundStyle(.orange)
                .transition(.opacity)
        case .idle, .upToDate, .updated:
            Image(systemName: "checkmark.circle.fill")
                .font(.title3).foregroundStyle(.green)
                .transition(.opacity)
        }
    }

    private var statusTitle: String {
        switch updates.state {
        case .idle, .upToDate: return L("about.status.upToDate")
        case .updated: return L("update.banner.updated")
        case .checking: return L("about.status.checking")
        case .ready(let info): return L("update.banner.title", info.version)
        case .waitingForIdle: return L("update.banner.waiting")
        case .downloading: return L("update.banner.downloading")
        case .installing: return L("update.banner.installing")
        case .failed: return L("about.status.failed")
        }
    }

    /// Вторая строка есть у каждого состояния — иначе карточка меняет высоту.
    private var statusSubtitle: String {
        switch updates.state {
        case .failed(let message):
            return message
        case .checking, .waitingForIdle, .downloading, .installing:
            return L("about.status.checkingHint")
        case .ready, .updated:
            return L("update.installedVersion", AppVersion.short)
        case .idle, .upToDate:
            guard let date = updates.lastCheck else { return L("update.installedVersion", AppVersion.short) }
            return L("about.status.checkedAt", Self.relative(date))
        }
    }

    /// Обе кнопки лежат в одном слоте, видна одна: ширина слота постоянна.
    private var statusAction: some View {
        let isReady: Bool = { if case .ready = updates.state { return true }; return false }()
        let isBusy: Bool = {
            switch updates.state {
            case .checking, .waitingForIdle, .downloading, .installing: return true
            default: return false
            }
        }()
        return ZStack(alignment: .trailing) {
            Button(L("about.checkNow")) { updates.checkNow() }
                .dsGlassButton()
                .disabled(!updates.canCheck)
                .opacity(isReady ? 0 : 1)
                .allowsHitTesting(!isReady)
            Button(L("update.install")) { updates.installNow() }
                .dsProminentButton()
                .opacity(isReady ? 1 : 0)
                .allowsHitTesting(isReady)
        }
        .controlSize(.small)
        // Во время проверки и установки кнопка видна, но неактивна — не исчезает.
        .disabled(isBusy)
    }

    private var settingsCard: some View {
        SettingsCard(header: L("about.updates")) {
            SettingsRow(title: L("about.autoCheck")) {
                SettingsSwitch(isOn: Binding(get: { updates.automaticallyChecks },
                                             set: { updates.automaticallyChecks = $0 }))
            }
            CardDivider()
            SettingsRow(title: L("about.autoDownload"), help: L("about.autoDownload.help")) {
                SettingsSwitch(isOn: Binding(get: { updates.automaticallyDownloads },
                                             set: { updates.automaticallyDownloads = $0 }))
            }
            .disabled(!updates.automaticallyChecks)
        }
    }

    /// Сборка без ленты (самосборка из исходников): обновлять нечем —
    /// только пояснение, без ссылок.
    private var selfBuildCard: some View {
        SettingsCard {
            Text(L("about.selfBuild"))
                .foregroundStyle(.secondary)
                .padding(.horizontal, DS.Spacing.cardPadding)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// «сегодня в 14:02» / «вчера в 09:10» / «3 нояб. в 18:00».
    private static func relative(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        // «Сегодня, 18:30» после двоеточия — со строчной: «Проверено: сегодня, 18:30».
        let text = formatter.string(from: date)
        guard let first = text.first, first.isUppercase,
              formatter.locale.language.languageCode?.identifier == "ru" else { return text }
        return first.lowercased() + text.dropFirst()
    }
}
