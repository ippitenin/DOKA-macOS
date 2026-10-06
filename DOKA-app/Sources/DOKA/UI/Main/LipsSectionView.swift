import AppKit
import SwiftUI

/// Раздел «Губы» (эксперимент): сбор пар «видео губ + текст» во время
/// диктовки — данные для будущего чтения по губам. Виден, только пока в
/// «Расширенных» включён эксперимент. Камера запрашивается здесь по кнопке
/// и никогда — посреди диктовки.
struct LipsSectionView: View {
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var permissions = PermissionsManager.shared
    @ObservedObject private var store = LipDataStore.shared
    @State private var confirmDeleteAll = false

    var body: some View {
        SettingsForm(title: L("section.lips")) {
            SettingsCard(header: L("lips.capture.header")) {
                SettingsRow(title: L("lips.learn"), help: L("lips.learn.hint")) {
                    SettingsSwitch(isOn: $settings.lipsLearn)
                }
                CardDivider()
                SettingsRow(title: L("lips.camera.title")) {
                    cameraStatus
                }
            }

            SettingsCard(header: L("lips.training.header")) {
                SettingsRow(title: L("lips.training.title"), help: L("lips.training.hint")) {
                    HStack(spacing: 10) {
                        Text(L("lips.training.count", store.summary.silent))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Button(L("lips.training.start")) { WindowManager.shared.showTraining() }
                            .dsGlassButton()
                            .disabled(!permissions.cameraAuthorized)
                    }
                }
            }

            SettingsCard(header: L("lips.mirror.header")) {
                SettingsRow(title: L("lips.mirror.notchVariant"), help: L("lips.mirror.notchVariant.hint")) {
                    SettingsPopup(selection: $settings.lipsMirrorNotchVariant, title: \.title)
                }
            }

            SettingsCard(header: L("lips.data.header"), footer: L("lips.data.footer")) {
                SettingsRow(title: L("lips.stats.pairs.title")) {
                    Text(L("lips.stats.pairs", store.summary.voice, store.summary.whisper, store.summary.silent))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                if store.summary.pending > 0 {
                    CardDivider()
                    SettingsRow(title: L("lips.stats.pending")) {
                        Text("\(store.summary.pending)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                if !store.summary.rejected.isEmpty {
                    CardDivider()
                    SettingsRow(title: L("lips.stats.rejected"), help: L("lips.stats.rejected.hint")) {
                        VStack(alignment: .trailing, spacing: 2) {
                            ForEach(store.summary.rejected, id: \.reason) { item in
                                Text("\(item.reason.title) — \(item.count)")
                            }
                        }
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    }
                }
                if store.summary.stats.headMissing > 0 {
                    CardDivider()
                    SettingsRow(title: L("lips.stats.headMissing"), help: L("lips.stats.headMissing.hint")) {
                        Text("\(store.summary.stats.headMissing)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                CardDivider()
                VStack(alignment: .leading, spacing: 10) {
                    Text(AppDataFolder.lipDataURL.path)
                        .font(.callout.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(usageText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    HStack(spacing: 10) {
                        Button(L("advanced.revealInFinder")) { revealInFinder() }
                            .dsGlassButton()
                        Button(L("lips.deleteAll")) { confirmDeleteAll = true }
                            .dsGlassButton()
                            .disabled(!store.summary.hasData)
                        Spacer(minLength: 0)
                    }
                }
                .padding(.horizontal, DS.Spacing.cardPadding)
                .padding(.vertical, 10)
            }
        }
        .onAppear {
            permissions.refresh()
            store.refreshSummary()
        }
        .alert(L("lips.deleteAll.title"), isPresented: $confirmDeleteAll) {
            Button(L("lips.deleteAll.confirm"), role: .destructive) {
                // Посреди диктовки тоже можно: её дубль при фиксации не найдёт
                // своей папки и будет выброшен.
                store.deleteAll()
            }
            Button(L("common.cancel"), role: .cancel) {}
        } message: {
            Text(L("lips.deleteAll.message"))
        }
        // Вернулись из Системных настроек — доступ к камере могли выдать.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissions.refresh()
        }
    }

    @ViewBuilder
    private var cameraStatus: some View {
        if permissions.cameraAuthorized {
            Label(L("lips.camera.authorized"), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.secondary)
        } else if permissions.cameraDenied {
            HStack(spacing: 10) {
                Text(L("lips.camera.denied"))
                    .foregroundStyle(.secondary)
                CameraAccessButton()
            }
        } else {
            CameraAccessButton()
        }
    }

    private var usageText: String {
        guard store.summary.loaded else { return L("lips.usage.calculating") }
        return L("lips.usage", ByteCountFormatter.string(fromByteCount: store.summary.bytes, countStyle: .file))
    }

    private func revealInFinder() {
        let url = AppDataFolder.lipDataURL
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([AppDataFolder.defaultURL])
        }
    }
}

/// Доступ к камере: «Открыть настройки», если в нём отказано (повторно
/// система не спросит), иначе «Разрешить» — системный запрос. Общая у
/// раздела «Губы» и окна «Тренировка».
struct CameraAccessButton: View {
    @ObservedObject private var permissions = PermissionsManager.shared

    var body: some View {
        if permissions.cameraDenied {
            Button(L("lips.camera.openSettings")) { permissions.openCameraSettings() }
                .dsGlassButton()
        } else {
            Button(L("lips.camera.allow")) {
                Task { _ = await permissions.requestCamera() }
            }
            .dsGlassButton()
        }
    }
}
