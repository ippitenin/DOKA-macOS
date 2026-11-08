import SwiftUI

/// Плашка «Доступно обновление» внизу сайдбара. Что показывать — решает чистый
/// `UpdateBannerModel` (`Update/UpdateState.swift`); здесь только вёрстка.
/// Стекла нет намеренно: плашка лежит на стеклянном сайдбаре, а стекло на
/// стекле даёт двойную линзу — вместо него тёплая подложка акцента.
struct UpdateBanner: View {
    let model: UpdateBannerModel
    @ObservedObject var updates: UpdateController
    @State private var showNotes = false

    /// Первый запуск после обновления: «DOKA обновлена» без кнопки.
    private var isUpdated: Bool {
        if case .updated = updates.state { return true }
        return false
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: DS.Radius.badge, style: .continuous)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Без иконки и без номера версии (решение владельца 8.11.2026):
            // версия — в «Что нового» и в «О DOKA».
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(isUpdated ? L("update.banner.updated") : L("update.banner.available"))
                        .font(.callout.weight(.semibold))
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
                        .padding(.vertical, 3)
                }
                .dsProminentButton()
            case .progress:
                progressBar
            case .none:
                EmptyView()
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

    /// Лист открыт после обновления: что нового в уже установленной версии.
    private var isUpdated: Bool {
        if case .updated = updates.state { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                DokaBrandLogo(size: 52)
                VStack(alignment: .leading, spacing: 2) {
                    Text(isUpdated ? L("update.banner.updated")
                         : L("update.banner.title", updates.state.info?.version ?? ""))
                        .font(.title3.weight(.semibold))
                    Text(isUpdated ? L("about.version", AppVersion.short, AppVersion.build)
                         : L("update.installedVersion", AppVersion.short))
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
                if isUpdated {
                    Button(L("common.ok"), action: onClose)
                        .dsProminentButton()
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button(L("update.later"), action: onClose)
                        .dsGlassButton()
                        .keyboardShortcut(.cancelAction)
                    Button(L("update.install")) {
                        onClose()
                        updates.installNow()
                    }
                    .dsProminentButton()
                    .keyboardShortcut(.defaultAction)
                    .disabled(updates.state.info == nil)
                }
            }
            // Системное синее кольцо фокуса на первой кнопке выбивается из дизайна.
            .focusEffectDisabled()
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
