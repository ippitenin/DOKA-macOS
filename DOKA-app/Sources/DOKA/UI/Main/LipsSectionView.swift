import AppKit
import SwiftUI

/// Раздел «Губы» (эксперимент): сбор пар «видео губ + текст» во время
/// диктовки — данные для будущего чтения по губам. Виден, только пока в
/// «Расширенных» включён эксперимент. Камера запрашивается здесь по кнопке
/// и никогда — посреди диктовки.
struct LipsSectionView: View {
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var permissions = PermissionsManager.shared

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

            SettingsCard(header: L("lips.data.header"), footer: L("lips.data.footer")) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(AppDataFolder.lipDataURL.path)
                        .font(.callout.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 10) {
                        Button(L("advanced.revealInFinder")) { revealInFinder() }
                            .dsGlassButton()
                        Spacer(minLength: 0)
                    }
                }
                .padding(.horizontal, DS.Spacing.cardPadding)
                .padding(.vertical, 10)
            }
        }
        .onAppear { permissions.refresh() }
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
                Button(L("lips.camera.openSettings")) { permissions.openCameraSettings() }
                    .dsGlassButton()
            }
        } else {
            Button(L("lips.camera.allow")) {
                Task { _ = await permissions.requestCamera() }
            }
            .dsGlassButton()
        }
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
