import SwiftUI

/// Полоса «Недавние» на странице «Транскрибация»: три последние записи и
/// переход во всю библиотеку. Удаление, поиск и экспорт живут в самой
/// библиотеке — здесь только быстрый путь к свежим записям.
struct LibraryRecentStrip: View {
    @ObservedObject private var store = TranscriptHistoryStore.shared

    private static let visibleCount = 3

    private var recent: [FileTranscriptRecord] {
        Array(store.records.sorted { $0.date > $1.date }.prefix(Self.visibleCount))
    }

    var body: some View {
        if !store.records.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(L("library.recent.title"))
                        .font(.headline)
                    Spacer()
                    Button {
                        LibraryNavigator.showList()
                    } label: {
                        HStack(spacing: 3) {
                            Text(L("library.recent.all"))
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .font(.callout)
                    .foregroundStyle(DS.accent)
                }
                .padding(.top, 6)

                ForEach(recent) { record in
                    RecentStripRow(record: record)
                }
            }
        }
    }
}

/// Компактная строка записи: клик открывает её в библиотеке.
private struct RecentStripRow: View {
    let record: FileTranscriptRecord

    @State private var isHovering = false

    var body: some View {
        Button {
            LibraryNavigator.open(record.id)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: record.fileIcon)
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(record.displayTitle)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(record.metaLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                LibraryStatusChip(record: record)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isHovering ? DS.accent : .secondary)
            }
            .padding(.horizontal, DS.Spacing.cardPadding)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // forceMaterial — та же ловушка серой плиты, что у карточек истории.
        .glassSurface(radius: DS.Radius.card, forceMaterial: true)
        .onHover { isHovering = $0 }
        .help(L("library.open"))
    }
}
