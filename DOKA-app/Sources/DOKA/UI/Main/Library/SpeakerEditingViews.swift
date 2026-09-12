import SwiftUI

// Спикеры записи: полоса чипов над репликами, бэйдж в строке реплики и общий
// поповер спикера (переименовать, объединить, отделить). Все правки идут через
// `TranscriptDocument` — он сохраняет их в тело записи.

/// Полоса «СПИКЕРЫ ● Анна 12 · ● Спикер 2 8» и справа «Сбросить правки».
struct SpeakerStrip: View {
    let roster: [SpeakerInfo]
    let document: TranscriptDocument
    let canEdit: Bool
    let showsReset: Bool
    let onReset: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if !roster.isEmpty {
                Text(L("transcribe.speakers.title"))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .padding(.top, 5)
                ChipFlowLayout(spacing: 6) {
                    ForEach(roster) { info in
                        SpeakerChip(info: info, roster: roster, document: document, canEdit: canEdit)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Spacer(minLength: 0)
            }
            if showsReset {
                Button(L("transcribe.edits.resetAll"), action: onReset)
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(DS.accent)
                    .padding(.top, 4)
            }
        }
    }
}

/// Внешний вид чипа спикера: цветная точка, имя и (если задано) число реплик.
struct SpeakerChipLabel: View {
    let info: SpeakerInfo
    var showsCount = true
    var isHighlighted = false

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(SpeakerPalette.color(at: info.colorIndex))
                .frame(width: 7, height: 7)
            Text(info.label)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .truncationMode(.tail)
            if showsCount {
                Text(verbatim: String(info.segmentCount))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        // Подложка и кромка — как у OptionTile: адаптивный Color.primary.
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.badge, style: .continuous)
                .fill(Color.primary.opacity(isHighlighted ? 0.08 : 0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.badge, style: .continuous)
                .strokeBorder(isHighlighted ? DS.accent.opacity(0.6) : Color.primary.opacity(0.12),
                              lineWidth: 1)
        )
        .contentShape(Rectangle())
    }
}

/// Чип полосы: клик — поповер спикера.
private struct SpeakerChip: View {
    let info: SpeakerInfo
    let roster: [SpeakerInfo]
    let document: TranscriptDocument
    let canEdit: Bool

    @State private var showsPopover = false
    @State private var isHovering = false

    var body: some View {
        if canEdit {
            Button {
                showsPopover = true
            } label: {
                SpeakerChipLabel(info: info, isHighlighted: isHovering || showsPopover)
            }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }
            .help(L("transcribe.speaker.rename"))
            .popover(isPresented: $showsPopover, arrowEdge: .bottom) {
                SpeakerPopover(info: info, roster: roster, document: document) {
                    showsPopover = false
                }
            }
            .animation(DS.Anim.hover, value: isHovering)
        } else {
            SpeakerChipLabel(info: info)
        }
    }
}

/// Имя спикера над репликой. С правкой — кнопка с поповером спикера.
/// Ловушка: SwiftUI `Menu` с кастомным лейблом на macOS ломает вид — поэтому
/// `Button` + `.popover`, а не `Menu`.
struct SpeakerBadge: View {
    let label: String
    let colorIndex: Int
    /// Спикер реплики в ростере; nil — правка недоступна (просто подпись).
    let info: SpeakerInfo?
    let roster: [SpeakerInfo]
    let document: TranscriptDocument?
    /// Подсказка: исходный спикер, если реплику переназначили.
    var help: String?
    /// Поповер открыт/закрыт — запись на это время не следует за плеером.
    var onPopoverChanged: ((Bool) -> Void)?

    @State private var showsPopover = false
    @State private var isHovering = false

    var body: some View {
        if let info, let document {
            Button {
                showsPopover = true
            } label: {
                text
                    .underline(isHovering)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }
            .help(help ?? L("transcribe.speaker.rename"))
            .popover(isPresented: $showsPopover, arrowEdge: .bottom) {
                SpeakerPopover(info: info, roster: roster, document: document) {
                    showsPopover = false
                }
            }
            .onChange(of: showsPopover) { _, shown in onPopoverChanged?(shown) }
            // Строку выгрузили с открытым поповером — закрытие иначе не придёт.
            .onDisappear {
                if showsPopover { onPopoverChanged?(false) }
            }
        } else {
            text
        }
    }

    private var text: some View {
        Text(label)
            .font(.caption.weight(.semibold))
            .foregroundStyle(SpeakerPalette.color(at: colorIndex))
    }
}

/// Поповер спикера: имя (Return или клик мимо — сохранить, Esc — отмена),
/// «Вернуть «Спикер N»», «Объединить с» и «Отделить». Любое действие
/// закрывает поповер: после слияния спикер, для которого он открыт, может
/// перестать существовать.
struct SpeakerPopover: View {
    let info: SpeakerInfo
    let roster: [SpeakerInfo]
    let document: TranscriptDocument
    let dismiss: () -> Void

    @State private var draft: String
    /// Поповер закрыт действием или Esc — набранное имя по закрытию не сохранять.
    @State private var isFinished = false
    @FocusState private var fieldFocused: Bool

    init(info: SpeakerInfo, roster: [SpeakerInfo], document: TranscriptDocument,
         dismiss: @escaping () -> Void) {
        self.info = info
        self.roster = roster
        self.document = document
        self.dismiss = dismiss
        _draft = State(initialValue: info.hasCustomName ? info.label : "")
    }

    private var normalized: String { TranscriptEdits.normalizeName(draft) }
    private var isTooLong: Bool { normalized.count > TranscriptEdits.maxNameLength }
    private var currentName: String { info.hasCustomName ? info.label : "" }
    /// Пустое имя у переименованного спикера — тоже сохранение: возврат к «Спикер N».
    private var canSave: Bool { !isTooLong && normalized != currentName }
    private var others: [SpeakerInfo] { roster.filter { $0.id != info.id } }

    /// Такое имя уже у другого спикера — вместо тихого совпадения предлагаем
    /// явное слияние.
    private var duplicate: SpeakerInfo? {
        guard !normalized.isEmpty else { return nil }
        let key = normalized.lowercased()
        return others.first { $0.label.lowercased() == key }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(info.defaultLabel)
                .font(.headline)

            TextField(L("transcribe.speaker.namePlaceholder"), text: $draft)
                .textFieldStyle(.roundedBorder)
                .focused($fieldFocused)
                .onSubmit(save)
                .onExitCommand {
                    isFinished = true
                    dismiss()
                }

            if isTooLong {
                Text(L("transcribe.speaker.nameTooLong", TranscriptEdits.maxNameLength))
                    .font(.caption)
                    .foregroundStyle(DS.RecorderTone.error)
            } else if let duplicate {
                HStack(spacing: 8) {
                    Text(L("transcribe.speaker.duplicate", duplicate.label))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button(L("transcribe.speaker.mergeAction")) { merge(into: duplicate) }
                        .dsGlassButton()
                        .controlSize(.small)
                }
            }

            HStack(spacing: 8) {
                if info.hasCustomName {
                    Button(L("transcribe.speaker.resetName", info.defaultLabel)) {
                        isFinished = true
                        document.renameSpeaker(info.id, to: "")
                        dismiss()
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(DS.accent)
                }
                Spacer(minLength: 0)
                Button(L("transcribe.edits.save"), action: save)
                    .dsProminentButton()
                    .controlSize(.small)
                    .disabled(!canSave)
            }

            if !others.isEmpty {
                Divider()
                Text(L("transcribe.speaker.mergeInto"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ChipFlowLayout(spacing: 6) {
                    ForEach(others) { other in
                        Button {
                            merge(into: other)
                        } label: {
                            SpeakerChipLabel(info: other, showsCount: false)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if !info.merged.isEmpty {
                Divider()
                ForEach(info.merged) { ref in
                    Button(L("transcribe.speaker.unmerge", ref.label)) {
                        isFinished = true
                        document.unmergeSpeaker(ref.id)
                        dismiss()
                    }
                    .buttonStyle(.plain)
                    .font(.callout)
                    .foregroundStyle(DS.accent)
                }
            }
        }
        .padding(14)
        .frame(width: 280, alignment: .leading)
        // Поле только что вставлено в иерархию — фокус со следующего цикла.
        .onAppear { DispatchQueue.main.async { fieldFocused = true } }
        // Клик мимо поповера — сохранить набранное, как у переименований записи.
        .onDisappear {
            if !isFinished, canSave { document.renameSpeaker(info.id, to: normalized) }
        }
    }

    private func save() {
        guard canSave else { return }
        isFinished = true
        document.renameSpeaker(info.id, to: normalized)
        dismiss()
    }

    private func merge(into other: SpeakerInfo) {
        isFinished = true
        document.mergeSpeaker(info.id, into: other.id)
        dismiss()
    }
}

/// Раскладка чипов с переносом строк: спикеров бывает до десятка, в одну
/// строку карточки они не помещаются.
struct ChipFlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = fittedSize(subviews[index], width: bounds.width)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = fittedSize(subviews[index], width: width)
            let needed = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            if !row.indices.isEmpty, needed > width {
                rows.append(row)
                row = Row()
            }
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }

    /// Размер чипа не шире строки: длинное имя (до 64 символов) обрезается,
    /// а не вылезает за карточку или поповер.
    private func fittedSize(_ subview: LayoutSubview, width: CGFloat) -> CGSize {
        let ideal = subview.sizeThatFits(.unspecified)
        guard width.isFinite, ideal.width > width else { return ideal }
        return subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
    }
}
