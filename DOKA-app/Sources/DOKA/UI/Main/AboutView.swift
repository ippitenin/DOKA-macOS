import AppKit
import SwiftUI

/// Под-страница «О DOKA» секции «Общие»: логотип, версия, проверка
/// обновлений и их настройки, ссылка на исходники (GPL-3.0). Списка
/// компонентов нет намеренно — решение владельца.
struct AboutView: View {
    @ObservedObject var updates = UpdateController.shared
    let onBack: () -> Void

    private static let repoURL = URL(string: "https://github.com/ippitenin/DOKA-macOS")!
    private static let releasesURL = URL(string: "https://github.com/ippitenin/DOKA-macOS/releases")!

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
                SettingsCard {
                    linkRow(L("about.source"), url: Self.repoURL)
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
            LogoIconTile(size: 64)
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

    private var statusCard: some View {
        SettingsCard {
            HStack(spacing: 12) {
                statusIcon
                VStack(alignment: .leading, spacing: 2) {
                    Text(statusTitle)
                    if let subtitle = statusSubtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 16)
                statusAction
            }
            .padding(.horizontal, DS.Spacing.cardPadding)
            .padding(.vertical, 11)
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch updates.state {
        case .checking, .waitingForIdle, .downloading, .installing:
            ProgressView().controlSize(.small).frame(width: 22)
        case .ready:
            Image(systemName: "arrow.down.circle.fill")
                .font(.title3).foregroundStyle(DS.accent).frame(width: 22)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title3).foregroundStyle(.orange).frame(width: 22)
        case .idle, .upToDate:
            Image(systemName: "checkmark.circle.fill")
                .font(.title3).foregroundStyle(.green).frame(width: 22)
        }
    }

    private var statusTitle: String {
        switch updates.state {
        case .idle, .upToDate: return L("about.status.upToDate")
        case .checking: return L("about.status.checking")
        case .ready(let info): return L("update.banner.title", info.version)
        case .waitingForIdle: return L("update.banner.waiting")
        case .downloading: return L("update.banner.downloading")
        case .installing: return L("update.banner.installing")
        case .failed: return L("about.status.failed")
        }
    }

    private var statusSubtitle: String? {
        switch updates.state {
        case .failed(let message):
            return message
        case .idle, .upToDate:
            guard let date = updates.lastCheck else { return nil }
            return L("about.status.checkedAt", Self.relative(date))
        default:
            return nil
        }
    }

    @ViewBuilder
    private var statusAction: some View {
        switch updates.state {
        case .ready:
            Button(L("update.install")) { updates.installNow() }
                .dsProminentButton()
                .controlSize(.small)
        case .waitingForIdle, .downloading, .installing:
            EmptyView()
        default:
            Button(L("about.checkNow")) { updates.checkNow() }
                .dsGlassButton()
                .controlSize(.small)
                .disabled(!updates.canCheck)
        }
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

    /// Сборка без ленты (самосборка из исходников): обновлять нечем, ведём
    /// на страницу релизов.
    private var selfBuildCard: some View {
        SettingsCard(footer: L("about.selfBuild.footer")) {
            linkRow(L("about.releases"), url: Self.releasesURL)
        }
    }

    private func linkRow(_ title: String, url: URL) -> some View {
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            HStack(spacing: 12) {
                Text(title)
                Spacer(minLength: 16)
                Image(systemName: "arrow.up.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, DS.Spacing.cardPadding)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// «сегодня в 14:02» / «вчера в 09:10» / «3 нояб. в 18:00».
    private static func relative(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter.string(from: date)
    }
}
