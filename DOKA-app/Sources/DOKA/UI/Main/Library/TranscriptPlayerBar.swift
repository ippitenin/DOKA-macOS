import SwiftUI

/// Действия плеера записи библиотеки — общие для кнопок плеер-бара и
/// клавиатуры детали (пробел, ←/→).
@MainActor
enum TranscriptPlayback {
    static func toggle(url: URL, recordID: UUID) {
        let player = RecordingPlayer.shared
        if player.currentRecordID == recordID {
            player.isPlaying ? player.pause() : player.play()
        } else {
            player.play(url: url, recordID: recordID, from: 0)
        }
    }

    static func skip(url: URL, recordID: UUID, by delta: TimeInterval) {
        let player = RecordingPlayer.shared
        guard player.ensureLoaded(url: url, recordID: recordID) else { return }
        player.skip(by: delta)
    }
}

/// Плеер архива звука записи: play/pause, ±5 с, слайдер, скорость и
/// «Следовать». Отдельная вью намеренно: плеер публикует время 20 раз в
/// секунду, и наблюдать его должен только этот ряд, а не вся запись.
struct TranscriptPlayerBar: View {
    let url: URL
    let recordID: UUID
    let fallbackDuration: TimeInterval
    /// Тумблер автоследования — только в детали библиотеки: у результата на
    /// странице «Транскрибация» своего скролла нет.
    var showsFollow = true

    @ObservedObject private var player = RecordingPlayer.shared
    @ObservedObject private var model = LibraryModel.shared

    private static let rates: [Float] = [1, 1.25, 1.5, 2]

    private var isCurrent: Bool { player.currentRecordID == recordID }
    private var duration: TimeInterval {
        isCurrent && player.duration > 0 ? player.duration : fallbackDuration
    }
    private var time: TimeInterval { isCurrent ? player.currentTime : 0 }

    var body: some View {
        HStack(spacing: 10) {
            iconButton("gobackward.5", help: L("library.player.back5")) {
                TranscriptPlayback.skip(url: url, recordID: recordID, by: -5)
            }
            Button {
                TranscriptPlayback.toggle(url: url, recordID: recordID)
            } label: {
                Image(systemName: (isCurrent && player.isPlaying) ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(DS.accent)
            }
            .buttonStyle(.plain)
            .help((isCurrent && player.isPlaying) ? L("library.player.pause") : L("library.player.play"))
            iconButton("goforward.5", help: L("library.player.forward5")) {
                TranscriptPlayback.skip(url: url, recordID: recordID, by: 5)
            }

            Text(TranscriptFormatter.clock(time))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 38, alignment: .trailing)

            // Протокол скраббинга — как у плеера истории: пока тянут ползунок,
            // тикер не перетирает позицию. Запись грузится в момент захвата —
            // перематывать можно и до первого «Play».
            Slider(value: sliderBinding, in: 0...max(duration, 0.01)) { editing in
                if editing {
                    guard player.ensureLoaded(url: url, recordID: recordID) else { return }
                    player.isScrubbing = true
                } else {
                    player.isScrubbing = false
                    if isCurrent { player.seek(to: player.currentTime) }
                }
            }
            .controlSize(.small)

            Text(TranscriptFormatter.clock(duration))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 38, alignment: .leading)

            speedMenu

            if showsFollow {
                iconButton("scope", help: L("library.player.follow"),
                           tint: model.followPlayback ? DS.accent : .secondary) {
                    model.followPlayback.toggle()
                }
            }
        }
    }

    private var sliderBinding: Binding<Double> {
        Binding(
            get: { isCurrent ? player.currentTime : 0 },
            set: { newValue in if isCurrent { player.currentTime = newValue } }
        )
    }

    /// Скорость — `Picker` внутри меню: галочка у выбранного пункта нативная.
    private var speedMenu: some View {
        Menu {
            Picker(L("library.player.speed"), selection: $player.rate) {
                ForEach(Self.rates, id: \.self) { rate in
                    Text(Self.rateLabel(rate)).tag(rate)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Text(Self.rateLabel(player.rate))
                .font(.caption.monospacedDigit().weight(.medium))
                .foregroundStyle(DS.accent)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L("library.player.speed"))
    }

    /// «1×», «1.25×» — не локализуется, как на любом плеере.
    private static func rateLabel(_ rate: Float) -> String {
        String(format: "%g×", rate)
    }

    private func iconButton(_ symbol: String, help: String, tint: Color = .secondary,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .foregroundStyle(tint)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
