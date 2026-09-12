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

/// Что строка сообщает записи. Пока открыт редактор реплики или поповер
/// спикера, лента не следует за плеером (автопрокрутка выгрузила бы строку из
/// ленивой ленты и сохранила недописанное), а клавиши плеера молчат.
enum SegmentInteraction: Equatable {
    case editorOpened
    /// `returnFocus` — закрыли явно (Return, Esc, кнопки): фокус обратно на запись.
    case editorClosed(returnFocus: Bool)
    case popoverOpened
    case popoverClosed
}

/// Сегменты расшифровки: тайм-код (с архивом звука — кнопка перемотки),
/// спикер, текст; звучащий сегмент подсвечен. В детали библиотеки лента
/// ленивая и следует за воспроизведением, в карточке страницы — обычная.
/// С правкой: двойной клик по тексту — инлайн-редактор, меню «⋯» и
/// контекстное меню реплики, бэйдж спикера — поповер спикера.
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
    /// Тексты сегментов ДО словаря (параллельно `result.segments`) — с ними
    /// открывается редактор; nil — совпадают с показанными.
    let sourceTexts: [String]?
    /// Не следовать за плеером: у строки открыт редактор или поповер.
    let suspendsFollow: Bool
    /// События строк: (индекс строки, событие).
    let onInteraction: (Int, SegmentInteraction) -> Void
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
                    Button(L("transcribe.segment.copyAll")) {
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
        // Адреса есть только у результата, собранного через правки.
        let targets = result.canEditSegments ? result.segmentTargets : nil
        let sources = sourceTexts?.count == result.segments.count ? sourceTexts : nil
        return ForEach(Array(result.segments.enumerated()), id: \.offset) { index, segment in
            let target = targets?[index]
            SegmentRow(segment: segment,
                       editableText: sources?[index] ?? segment.text,
                       isActive: index == active,
                       colorIndex: segment.speaker.flatMap { colors[$0] },
                       speakerLabel: segment.speaker.map(result.speakerLabel),
                       originalSpeakerLabel: target.flatMap { target in
                           target.isSpeakerOverridden ? target.originalSpeaker.map(result.speakerLabel) : nil
                       },
                       canSeek: canSeek,
                       edit: target == nil ? nil : editContext,
                       target: target,
                       onInteraction: { onInteraction(index, $0) },
                       onCopyAll: { ClipboardManager.setString(TranscriptFormatter.plainText(result)) },
                       onSeek: { onSeek(segment.start) })
                .equatable()
                .id(SegmentAnchor(index: index))
        }
    }

    /// Автоследование: только при воспроизведении и включённом «Следовать»
    /// (ручная прокрутка его выключает) и не во время правки. Reduce Motion —
    /// без анимации.
    private func follow(_ index: Int?) {
        guard let index, let scrollProxy, !suspendsFollow,
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
/// две строки, а не весь список (замыкания в сравнении не участвуют).
/// Состояние редактора — своё, у строки: ввод не перерисовывает список.
private struct SegmentRow: View, Equatable {
    let segment: TranscriptSegment
    /// Текст до словаря — с ним открывается редактор.
    let editableText: String
    let isActive: Bool
    let colorIndex: Int?
    /// Имя спикера с учётом правок (nil — у сегмента нет спикера).
    let speakerLabel: String?
    /// Имя исходного спикера, если реплику переназначили.
    let originalSpeakerLabel: String?
    let canSeek: Bool
    /// nil — правка недоступна.
    let edit: SegmentEditContext?
    let target: EditTarget?
    let onInteraction: (SegmentInteraction) -> Void
    let onCopyAll: () -> Void
    let onSeek: () -> Void

    @State private var isHovering = false
    /// Меню «⋯» уже создано (с первого наведения).
    @State private var hasMenu = false
    @State private var isEditing = false
    @State private var draft = ""
    /// Адрес и текст на момент открытия редактора: сохраняется по ним, даже
    /// если строку за это время перенарезали (адрес от нарезки не зависит).
    @State private var editingTarget: EditTarget?
    @State private var editingOriginal = ""
    @FocusState private var editorFocused: Bool

    static func == (lhs: SegmentRow, rhs: SegmentRow) -> Bool {
        lhs.segment == rhs.segment && lhs.editableText == rhs.editableText
            && lhs.isActive == rhs.isActive
            && lhs.colorIndex == rhs.colorIndex && lhs.speakerLabel == rhs.speakerLabel
            && lhs.originalSpeakerLabel == rhs.originalSpeakerLabel
            && lhs.canSeek == rhs.canSeek && lhs.edit == rhs.edit && lhs.target == rhs.target
    }

    private var canEdit: Bool { edit != nil && target != nil }

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
                                 document: edit?.document,
                                 help: originalSpeakerLabel.map { L("transcribe.segment.speakerChanged", $0) },
                                 onPopoverChanged: { onInteraction($0 ? .popoverOpened : .popoverClosed) })
                }
                if isEditing {
                    editor
                } else {
                    text
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let edit, let target, !isEditing {
                // Меню создаётся с первого наведения и дальше живёт: лента страницы
                // «Транскрибация» не ленивая, и сотни AppKit-меню разом тормозили
                // бы показ, а убирать меню по уходу курсора нельзя — курсор
                // уходит в само открытое меню. Место держится всегда.
                ZStack {
                    if hasMenu {
                        actionsMenu(edit, target)
                            .opacity(isHovering ? 1 : 0)
                    }
                }
                .frame(width: 18, height: 16)
            }
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
        .onHover { hovering in
            isHovering = hovering
            if hovering { hasMenu = true }
        }
        // Контекстное меню строки перекрывает меню списка — поэтому
        // «Скопировать всё» есть и здесь, в том числе у строки без правки.
        .contextMenu {
            if let edit, let target, !isEditing {
                actionItems(edit, target)
                Divider()
            }
            Button(L("transcribe.segment.copyAll"), action: onCopyAll)
        }
        // Строку перенарезали (смена детализации) — открытая правка
        // сохраняется, как при потере фокуса.
        .onChange(of: target) { _, _ in
            if isEditing { finishEditing(commit: true) }
        }
        // Строка ушла из ленивой ленты — тоже сохранить.
        .onDisappear {
            if isEditing { finishEditing(commit: true, force: true) }
        }
    }

    // MARK: - Текст и редактор

    @ViewBuilder
    private var text: some View {
        if canEdit {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(segment.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let target, target.isTextEdited {
                    Image(systemName: "pencil")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .help(L("transcribe.segment.original", target.originalText))
                        .accessibilityLabel(L("transcribe.segment.edited"))
                }
            }
            // Двойной клик — правка. `.textSelection` здесь нельзя: он съедает
            // двойной клик (выделение слова). Копировать — «Скопировать
            // реплику» или внутри редактора.
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { startEditing() }
        } else {
            Text(segment.text)
                .textSelection(.enabled)
        }
    }

    /// Инлайн-редактор: Return — сохранить (Option+Return — перевод строки,
    /// при сохранении он станет пробелом), Esc — отмена, клик мимо — сохранить.
    private var editor: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...12)
                .focused($editorFocused)
                .onSubmit(submit)
                .onExitCommand { finishEditing(commit: false, returnFocus: true) }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(DS.accent.opacity(0.6), lineWidth: 1)
                )
            HStack(spacing: 8) {
                // Кнопки не забирают фокус у поля (при полном доступе с
                // клавиатуры): потеря фокуса сохраняет, и «Отмена» стала бы «Сохранить».
                Button(L("transcribe.edits.save"), action: submit)
                    .dsProminentButton()
                    .controlSize(.small)
                    .focusable(false)
                    .disabled(!canSaveDraft)
                Button(L("common.cancel")) { finishEditing(commit: false, returnFocus: true) }
                    .dsGlassButton()
                    .controlSize(.small)
                    .focusable(false)
                Text(L("transcribe.segment.editHint"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        // Поле только что вставлено в иерархию — фокус со следующего цикла.
        .onAppear { DispatchQueue.main.async { editorFocused = true } }
        .onChange(of: editorFocused) { _, focused in
            if !focused { finishEditing(commit: true) }
        }
    }

    /// Пустой текст запрещён: реплика исчезла бы, и вернуть её было бы нечем.
    private var canSaveDraft: Bool {
        let normalized = TranscriptEdits.normalizeText(draft)
        return !normalized.isEmpty && normalized != TranscriptEdits.normalizeText(editingOriginal)
    }

    private func startEditing() {
        guard canEdit, !isEditing, let target else { return }
        draft = editableText
        editingOriginal = editableText
        editingTarget = target
        isEditing = true
        onInteraction(.editorOpened)
    }

    /// Return: пустое не сохраняется и редактор не закрывает.
    private func submit() {
        guard !TranscriptEdits.normalizeText(draft).isEmpty else { return }
        finishEditing(commit: true, returnFocus: true)
    }

    /// Единый выход из редактора; повторный вызов (фокус уходит вслед за
    /// Esc или сохранением) ничего не делает. Если адрес устарел (реплику
    /// успели сбросить или вернуть иначе), черновик не теряется: редактор
    /// остаётся открытым на текущем адресе строки. `force` — строка уходит из
    /// ленты, держать редактор негде.
    private func finishEditing(commit: Bool, returnFocus: Bool = false, force: Bool = false) {
        guard isEditing else { return }
        if commit, canSaveDraft, let editingTarget, let document = edit?.document,
           document.setSegmentText(draft, at: editingTarget) == .stale, !force, let target {
            self.editingTarget = target
            editingOriginal = editableText
            return
        }
        isEditing = false
        onInteraction(.editorClosed(returnFocus: returnFocus))
    }

    // MARK: - Действия

    /// Меню «⋯» реплики — SF Symbol-лейбл, как у «Сохранить как…»: кастомный
    /// лейбл SwiftUI `Menu` на macOS ломает.
    private func actionsMenu(_ edit: SegmentEditContext, _ target: EditTarget) -> some View {
        Menu {
            actionItems(edit, target)
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L("transcribe.segment.menu"))
    }

    /// Пункты действий — общие у меню «⋯» и контекстного меню строки.
    @ViewBuilder
    private func actionItems(_ edit: SegmentEditContext, _ target: EditTarget) -> some View {
        Button(L("transcribe.segment.edit")) { startEditing() }
        if !edit.roster.isEmpty {
            Menu(L("transcribe.segment.assign")) {
                ForEach(edit.roster.filter { $0.id != segment.speaker }) { info in
                    Button(info.label) { edit.document.reassignSegment(at: target, to: info.id) }
                }
                Divider()
                Button(L("transcribe.speaker.new")) { edit.document.reassignSegment(at: target, to: nil) }
            }
            if target.isSpeakerOverridden {
                Button(L("transcribe.segment.revertSpeaker")) {
                    edit.document.revertSegmentSpeaker(at: target)
                }
            }
        }
        if target.isTextEdited {
            Button(L("transcribe.segment.revertText")) {
                edit.document.revertSegmentText(at: target)
            }
        }
        Divider()
        Button(L("transcribe.segment.copy")) { ClipboardManager.setString(segment.text) }
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
