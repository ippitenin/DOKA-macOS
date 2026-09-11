import Combine
import SwiftUI

/// Активный сегмент под позицией плеера. Плеер публикует время 20 раз в
/// секунду, а список сегментов в часовой записи — сотни строк: список
/// наблюдает этот объект, который публикует ТОЛЬКО смену индекса.
@MainActor
final class SegmentFollower: ObservableObject {
    @Published private(set) var activeIndex: Int?

    private var recordID: UUID?
    private var starts: [Double] = []
    private var cancellable: AnyCancellable?

    /// Подписка — с первого `configure`, а не в init: вью держит объект в
    /// `@State`, а выражение начального значения выполняется при каждой
    /// пересборке структуры вью — лишние экземпляры должны быть бесплатными.
    func configure(recordID: UUID, starts: [Double]) {
        self.recordID = recordID
        self.starts = starts
        let player = RecordingPlayer.shared
        if cancellable == nil {
            // combineLatest сразу отдаёт текущие значения — индекс посчитается здесь же.
            cancellable = player.$currentTime
                .combineLatest(player.$currentRecordID)
                .sink { [weak self] time, current in self?.update(time: time, current: current) }
        } else {
            update(time: player.currentTime, current: player.currentRecordID)
        }
    }

    private func update(time: TimeInterval, current: UUID?) {
        let index = current == recordID
            ? SegmentTimeline.activeIndex(starts: starts, time: time)
            : nil
        if index != activeIndex { activeIndex = index }
    }
}

/// Якорь строки сегмента для `scrollTo`. Свой тип, а не голый `Int`: в том же
/// ScrollView у блоков Markdown анализа id — те же смещения 0…N, и прокрутка
/// к «5» уехала бы к пятому блоку анализа.
struct SegmentAnchor: Hashable {
    let index: Int
}

/// Что нужно строке реплики для правок: документ (правки идут через него) и
/// ростер спикеров. Документ сравнивается по ссылке — строки `Equatable`.
struct SegmentEditContext: Equatable {
    let document: TranscriptDocument
    let roster: [SpeakerInfo]

    static func == (lhs: SegmentEditContext, rhs: SegmentEditContext) -> Bool {
        lhs.document === rhs.document && lhs.roster == rhs.roster
    }
}

/// Сегменты расшифровки: тайм-код (с архивом звука — кнопка перемотки),
/// спикер, текст; звучащий сегмент подсвечен. В детали библиотеки лента
/// ленивая и следует за воспроизведением, в карточке страницы — обычная.
struct TranscriptSegmentsView: View {
    let result: TranscriptResult
    let recordID: UUID
    /// Есть архив звука — тайм-коды кликабельны.
    let canSeek: Bool
    /// Ленивый список: у детали свой скролл и сотни строк.
    let lazy: Bool
    /// Прокрутка за воспроизведением; nil — не прокручивать (карточка страницы).
    let scrollProxy: ScrollViewProxy?
    @ObservedObject var follower: SegmentFollower
    /// nil — правка недоступна (тело не загружено, библиотека заморожена).
    let editContext: SegmentEditContext?
    let onSeek: (Double) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if result.segments.isEmpty {
            Text(result.fullText)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            rowsContainer
                .frame(maxWidth: .infinity, alignment: .leading)
                .contextMenu {
                    Button(L("common.copy")) {
                        ClipboardManager.setString(TranscriptFormatter.plainText(result))
                    }
                }
                .onAppear { follower.configure(recordID: recordID, starts: starts) }
                // Смена детализации или словаря — другая нарезка, другие начала.
                .onChange(of: starts) { _, newStarts in
                    follower.configure(recordID: recordID, starts: newStarts)
                }
                .onChange(of: follower.activeIndex) { _, index in follow(index) }
        }
    }

    private var starts: [Double] { result.segments.map(\.start) }

    @ViewBuilder
    private var rowsContainer: some View {
        let colors = result.speakerColorIndices
        let active = follower.activeIndex
        if lazy {
            LazyVStack(alignment: .leading, spacing: 4) {
                rows(colors: colors, active: active)
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                rows(colors: colors, active: active)
            }
        }
    }

    private func rows(colors: [String: Int], active: Int?) -> some View {
        ForEach(Array(result.segments.enumerated()), id: \.offset) { index, segment in
            SegmentRow(segment: segment,
                       isActive: index == active,
                       colorIndex: segment.speaker.flatMap { colors[$0] },
                       speakerLabel: segment.speaker.map(result.speakerLabel),
                       canSeek: canSeek,
                       edit: editContext,
                       onSeek: { onSeek(segment.start) })
                .equatable()
                .id(SegmentAnchor(index: index))
        }
    }

    /// Автоследование: только при воспроизведении и включённом «Следовать»
    /// (ручная прокрутка его выключает). Reduce Motion — без анимации.
    private func follow(_ index: Int?) {
        guard let index, let scrollProxy,
              LibraryModel.shared.followPlayback,
              RecordingPlayer.shared.isPlaying else { return }
        let anchor = SegmentAnchor(index: index)
        if reduceMotion {
            scrollProxy.scrollTo(anchor, anchor: .center)
        } else {
            withAnimation(DS.Anim.section) { scrollProxy.scrollTo(anchor, anchor: .center) }
        }
    }
}

/// Строка сегмента. Equatable: при смене активного сегмента перерисовываются
/// две строки, а не весь список (замыкание в сравнении не участвует).
private struct SegmentRow: View, Equatable {
    let segment: TranscriptSegment
    let isActive: Bool
    let colorIndex: Int?
    /// Имя спикера с учётом правок (nil — у сегмента нет спикера).
    let speakerLabel: String?
    let canSeek: Bool
    let edit: SegmentEditContext?
    let onSeek: () -> Void

    static func == (lhs: SegmentRow, rhs: SegmentRow) -> Bool {
        lhs.segment == rhs.segment && lhs.isActive == rhs.isActive
            && lhs.colorIndex == rhs.colorIndex && lhs.speakerLabel == rhs.speakerLabel
            && lhs.canSeek == rhs.canSeek && lhs.edit == rhs.edit
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            timeCode
                .frame(width: 56, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                if let speaker = segment.speaker, !speaker.isEmpty {
                    SpeakerBadge(label: speakerLabel ?? SpeakerName.displayName(for: speaker),
                                 colorIndex: colorIndex ?? 0,
                                 info: edit?.roster.first { $0.id == speaker },
                                 roster: edit?.roster ?? [],
                                 document: edit?.document)
                }
                Text(segment.text)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isActive ? DS.accent.opacity(0.10) : Color.clear)
        )
        .overlay(alignment: .leading) {
            if isActive {
                Capsule()
                    .fill(DS.accent)
                    .frame(width: 3)
                    .padding(.vertical, 4)
            }
        }
    }

    @ViewBuilder
    private var timeCode: some View {
        let label = TranscriptFormatter.clock(segment.start)
        if canSeek {
            TimeCodeButton(label: label, action: onSeek)
        } else {
            Text(label)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
    }
}

/// Тайм-код-кнопка: клик — воспроизведение с начала сегмента.
private struct TimeCodeButton: View {
    let label: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.caption.monospaced())
                .foregroundStyle(isHovering ? DS.accent : .secondary)
                .underline(isHovering)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(L("library.segment.play"))
    }
}
