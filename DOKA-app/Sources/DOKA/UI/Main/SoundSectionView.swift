import SwiftUI

/// Секция «Звук»: микрофон (буст громкости, удаление тишины)
/// и звуковые эффекты (сигналы записи, громкость).
struct SoundSectionView: View {
    @ObservedObject var settings = SettingsStore.shared

    var body: some View {
        SettingsForm(title: L("section.sound")) {
            SettingsCard(header: L("sound.micCard")) {
                SettingsRow(title: L("sound.autoBoost"),
                            help: L("sound.autoBoost.hint")) {
                    SettingsSwitch(isOn: $settings.micAutoBoost)
                }
                CardDivider()
                SettingsRow(title: L("sound.silenceRemoval"),
                            help: L("sound.silenceRemoval.hint")) {
                    SettingsSwitch(isOn: $settings.silenceRemoval)
                }
                CardDivider()
                SettingsRow(title: L("sound.skipSilent"),
                            help: L("sound.skipSilent.hint")) {
                    SettingsSwitch(isOn: $settings.skipSilentRecordings)
                }
            }

            SettingsCard(header: L("sound.effectsCard")) {
                SettingsRow(title: L("sound.cues")) {
                    SettingsSwitch(isOn: $settings.soundsEnabled)
                }
                CardDivider()
                SettingsRow(title: L("sound.volume")) {
                    HStack(spacing: 8) {
                        Image(systemName: "speaker.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Slider(value: $settings.soundVolume, in: 0...1) { editing in
                            // Пробный звук по отпусканию — слышно выбранную громкость.
                            if !editing { SoundPlayer.play(.recordStop) }
                        }
                        .controlSize(.small)
                        .frame(width: 180)
                        Image(systemName: "speaker.wave.3.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .disabled(!settings.soundsEnabled)
                    .opacity(settings.soundsEnabled ? 1 : 0.5)
                }
            }
        }
    }
}
