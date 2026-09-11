import AppKit
import SwiftUI

/// Строка ленты библиотеки: выбор, иконка, заголовок (переименование прямо
/// в строке), метаданные, сниппет найденного, статус и действия.
struct LibraryRow: View {
    let item: LibraryItem
    let query: String
    let isSelected: Bool
    let isRenaming: Bool
    /// Черновик переименования живёт в `LibraryModel` (переживает прокрутку).
    @Binding var renameDraft: String
    let onToggleSelect: () -> Void
    let onOpen: () -> Void
    let onStartRename: () -> Void
    /// Enter и потеря фокуса — сохранить (владелец игнорирует повтор).
    let onCommitRename: () -> Void
    /// Esc — отмена.
    let onCancelRename: () -> Void
    let onDelete: () -> Void

    @State private var isHovering = false
    @FocusState private var renameFocused: Bool

    private var record: FileTranscriptRecord { item.record }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Селектор виден всегда — запись можно отметить сразу, без наведения.
            Button(action: onToggleSelect) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(isSelected ? DS.accent : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(L("library.select"))

            Image(systemName: record.fileIcon)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .frame(width: 20)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                title
                meta
                if let snippet = item.snippet {
                    Text(LibraryHighlight.attributed(snippet, query: query))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { if !isRenaming { onOpen() } }

            LibraryStatusChip(record: record)

            // Действия по ховеру; место под них держится всегда — строка не
            // прыгает под курсором.
            HStack(spacing: 2) {
                iconButton("pencil", help: L("library.rename"), action: onStartRename)
                iconButton("trash", help: L("library.delete"), tint: .red, action: onDelete)
            }
            .opacity(isHovering && !isRenaming ? 1 : 0)
        }
        .padding(DS.Spacing.cardPadding)
        // forceMaterial: Liquid Glass у пачки карточек в скролле рисует общий
        // серый бэкдроп на весь viewport с резкими углами (ловушка истории).
        .glassSurface(radius: DS.Radius.card, forceMaterial: true)
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                    .strokeBorder(DS.accent, lineWidth: 1.5)
            }
        }
        .onHover { isHovering = $0 }
        .contextMenu {
            Button(L("library.open"), action: onOpen)
            Button(L("library.rename"), action: onStartRename)
            if record.hasArchivedAudio {
                Button(L("library.showAudioInFinder")) { revealAudio() }
            }
            Divider()
            Button(L("library.delete"), role: .destructive, action: onDelete)
        }
    }

    @ViewBuilder
    private var title: some View {
        if isRenaming {
            TextField(L("library.rename.placeholder"), text: $renameDraft)
                .textFieldStyle(.plain)
                .fontWeight(.medium)
                .focused($renameFocused)
                .onSubmit(onCommitRename)
                .onExitCommand(perform: onCancelRename)
                .onAppear {
                    // Поле только что вставлено в иерархию — фокус со следующего цикла.
                    DispatchQueue.main.async { renameFocused = true }
                }
                // Клик мимо поля — сохранить (как в Finder). После Esc запись
                // уже не переименовывается — повторный вызов владелец игнорирует.
                .onChange(of: renameFocused) { _, focused in
                    if !focused { onCommitRename() }
                }
        } else {
            Text(LibraryHighlight.attributed(record.displayTitle, query: query))
                .fontWeight(.medium)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    /// «Дата · сервис · длительность» и значки: аудио, спикеры, анализы.
    private var meta: some View {
        HStack(spacing: 8) {
            Text(record.metaLine)
                .lineLimit(1)
            if record.hasArchivedAudio {
                Image(systemName: "waveform")
                    .help(L("library.hasAudio"))
            }
            if let summary = record.summary, summary.speakerCount > 0 {
                counter("person.2", summary.speakerCount)
                    .help(L("library.speakers", summary.speakerCount))
            }
            if let summary = record.summary, summary.analysisCount > 0 {
                counter("sparkles", summary.analysisCount)
                    .help(L("library.analyses", summary.analysisCount))
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func counter(_ symbol: String, _ value: Int) -> some View {
        HStack(spacing: 2) {
            Image(systemName: symbol)
            Text("\(value)").monospacedDigit()
        }
    }

    private func revealAudio() {
        guard let url = TranscriptHistoryStore.shared.audioURL(for: record.id) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func iconButton(_ symbol: String, help: String, tint: Color = .secondary,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(tint)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Чип статуса незавершённой записи; у готовой чипа нет. Отдельная вью:
/// подпись выполняющейся задачи («Разделение по спикерам… 40 %») меняется
/// часто, и наблюдать контроллер должен только чип, а не вся лента.
struct LibraryStatusChip: View {
    let record: FileTranscriptRecord

    @ObservedObject private var controller = FileTranscriptionController.shared

    var body: some View {
        switch record.status {
        case .inProgress:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(LibraryProgressText.text(for: record, controller: controller))
                    .lineLimit(1)
                    .monospacedDigit()
            }
            .modifier(ChipStyle(tint: .secondary))
        case .error(let message):
            // Полный текст ошибки — в тултипе.
            Text(L("library.status.error"))
                .modifier(ChipStyle(tint: DS.RecorderTone.error))
                .help(message)
        case .cancelled:
            Text(L("library.status.cancelled"))
                .modifier(ChipStyle(tint: .secondary))
        case .done:
            EmptyView()
        }
    }
}

/// Подпись незавершённой записи: у идущей сейчас задачи — её прогресс, у
/// задачи Nexara, которую добирают после перезапуска, — «Добираю результат».
@MainActor
enum LibraryProgressText {
    static func text(for record: FileTranscriptRecord, controller: FileTranscriptionController) -> String {
        if controller.runningRecordID == record.id {
            return controller.progressNote ?? L("library.status.inProgress")
        }
        return record.jobID != nil ? L("library.status.recovering") : L("library.status.inProgress")
    }
}

private struct ChipStyle: ViewModifier {
    let tint: Color

    func body(content: Content) -> some View {
        content
            .font(.caption)
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.primary.opacity(0.06)))
    }
}

/// Подсветка слов запроса в заголовке и сниппете.
enum LibraryHighlight {
    static func attributed(_ text: String, query: String) -> AttributedString {
        var attributed = AttributedString(text)
        let tokens = LibrarySearch.tokens(query)
        guard !tokens.isEmpty else { return attributed }
        // `normalize` сохраняет число символов — смещения у нормализованной
        // копии и у оригинала общие (на этом держится и сниппет).
        let normalized = LibrarySearch.normalize(text)
        let count = attributed.characters.count
        for token in tokens {
            var searchStart = normalized.startIndex
            while searchStart < normalized.endIndex,
                  let range = normalized.range(of: token, options: .literal,
                                               range: searchStart..<normalized.endIndex) {
                let lower = normalized.distance(from: normalized.startIndex, to: range.lowerBound)
                let length = normalized.distance(from: range.lowerBound, to: range.upperBound)
                guard length > 0, lower + length <= count else { break }
                let start = attributed.characters.index(attributed.startIndex, offsetBy: lower)
                let end = attributed.characters.index(start, offsetBy: length)
                attributed[start..<end].backgroundColor = DS.accent.opacity(0.25)
                searchStart = range.upperBound
            }
        }
        return attributed
    }
}
