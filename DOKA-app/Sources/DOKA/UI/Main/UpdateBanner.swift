import SwiftUI

/// Плашка «Доступна DOKA X» внизу сайдбара. Что показывать — решает чистый
/// `UpdateBannerModel` (`Update/UpdateState.swift`); здесь только вёрстка.
/// Стекла нет намеренно: плашка лежит на стеклянном сайдбаре, а стекло на
/// стекле даёт двойную линзу — вместо него тёплая подложка акцента.
struct UpdateBanner: View {
    let model: UpdateBannerModel
    @ObservedObject var updates: UpdateController
    @State private var showNotes = false

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: DS.Radius.badge, style: .continuous)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 9) {
                IconTile(symbol: "arrow.down", color: DS.accent, size: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("update.banner.title", model.version))
                        .font(.callout.weight(.semibold))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if let key = model.statusKey {
                        Text(L(key))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if updates.state.info?.notes != nil {
                        Button(L("update.whatsNew")) { showNotes = true }
                            .buttonStyle(.plain)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(DS.accent)
                    }
                }
                Spacer(minLength: 0)
                if model.dismissible {
                    Button {
                        updates.dismissBanner()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 18, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(L("update.banner.hide"))
                }
            }

            switch model.action {
            case .install:
                Button {
                    updates.installNow()
                } label: {
                    Text(L("update.install"))
                        .frame(maxWidth: .infinity)
                }
                .dsProminentButton()
                .controlSize(.small)
            case .progress:
                progressBar
            }
        }
        .padding(11)
        .background(shape.fill(DS.accent.opacity(0.10)))
        .overlay(shape.strokeBorder(DS.accent.opacity(0.28), lineWidth: 0.5))
        .sheet(isPresented: $showNotes) {
            ReleaseNotesSheet(updates: updates) { showNotes = false }
        }
    }

    /// Прогресс: доля — при скачивании с известным размером, иначе бегущая полоса.
    @ViewBuilder
    private var progressBar: some View {
        if case .downloading(_, let fraction?) = updates.state {
            ProgressView(value: fraction)
                .progressViewStyle(.linear)
                .tint(DS.accent)
        } else {
            ProgressView()
                .progressViewStyle(.linear)
                .tint(DS.accent)
        }
    }
}

/// «Что нового»: заметки релиза из ленты и та же кнопка «Обновить».
struct ReleaseNotesSheet: View {
    @ObservedObject var updates: UpdateController
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                LogoIconTile(size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("update.banner.title", updates.state.info?.version ?? ""))
                        .font(.title3.weight(.semibold))
                    Text(L("about.version", AppVersion.short, AppVersion.build))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            ScrollView {
                MarkdownView(updates.state.info?.notes ?? "")
                    .padding(.trailing, 6)
            }
            .frame(maxHeight: 320)
            HStack {
                Spacer()
                Button(L("update.later"), action: onClose)
                    .dsGlassButton()
                Button(L("update.install")) {
                    onClose()
                    updates.installNow()
                }
                .dsProminentButton()
                .disabled(updates.state.info == nil)
            }
        }
        .padding(22)
        .frame(width: 460)
    }
}

/// Версия текущего бандла для интерфейса («1.0.3», сборка «4»).
enum AppVersion {
    static var short: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }
}
