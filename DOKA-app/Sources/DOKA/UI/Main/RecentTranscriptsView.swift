import SwiftUI

/// Список последних записей библиотеки на странице «Транскрибация».
/// Выполняющиеся задачи видны как «В процессе» (как в дашборде Nexara),
/// готовые открываются обратно в карточки «Транскрибация»/«Анализ» со всеми
/// возможностями (детализация, экспорт). Полная библиотека с поиском — в
/// своей секции (следующая фаза); здесь — только хвост списка.
struct RecentTranscriptsView: View {
    @ObservedObject private var store = TranscriptHistoryStore.shared
    @ObservedObject private var controller = FileTranscriptionController.shared
    @ObservedObject private var settings = SettingsStore.shared
    /// Запись, ожидающая подтверждения удаления.
    @State private var pendingDelete: FileTranscriptRecord?

    /// Без лимита в библиотеке список на странице рос бы бесконечно, а он
    /// не ленивый: показываем хвост.
    private static let visibleLimit = 50

    /// Подсказка о сроке хранения — живая: следует текущей настройке
    /// `transcriptRetention` (сменили срок в «Расширенных» — текст обновился).
    private var retentionHelp: String {
        switch settings.transcriptRetention {
        case .forever:
            return L("transcribe.recent.help.forever")
        default:
            return L("transcribe.recent.help.hours", settings.transcriptRetention.title)
        }
    }

    var body: some View {
        if !store.records.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 5) {
                    Text(L("transcribe.recent.title"))
                        .font(.headline)
                    HelpBubble(text: retentionHelp)
                }
                .padding(.top, 6)
                ForEach(store.records.prefix(Self.visibleLimit)) { record in
                    RecentTranscriptCard(
                        record: record,
                        // Открытие во время активной транскрибации молча убило
                        // бы задачу — блокируем, как дропзону.
                        openDisabled: controller.isTranscribing,
                        onOpen: { controller.open(record.id) },
                        onDelete: { pendingDelete = record }
                    )
                }
            }
            // Alert живёт на этой вью: на корне страницы «Транскрибация»
            // алертов нет, конвенция «один .alert на вью» соблюдена.
            .alert(L("transcribe.recent.delete.title"),
                   isPresented: Binding(
                       get: { pendingDelete != nil },
                       set: { if !$0 { pendingDelete = nil } }
                   ),
                   presenting: pendingDelete) { record in
                Button(L("transcribe.recent.delete.confirm"), role: .destructive) {
                    // Удаление выполняющейся записи: сначала остановить задачу,
                    // иначе она дописала бы результат в уже удалённую запись.
                    if controller.runningRecordID == record.id {
                        controller.cancelTranscription()
                    }
                    RecordingPlayer.shared.stopIfCurrent(record.id)
                    store.delete(record.id)
                }
                Button(L("common.cancel"), role: .cancel) {}
            } message: { record in
                Text(record.displayTitle)
            }
        }
    }
}

/// Карточка одной записи: заголовок, дата/сервис, статус и действия.
private struct RecentTranscriptCard: View {
    let record: FileTranscriptRecord
    let openDisabled: Bool
    let onOpen: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: fileIcon)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(record.displayTitle)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            statusView

            if case .done = record.status {
                Button(L("transcribe.recent.open"), action: onOpen)
                    .dsGlassButton()
                    .disabled(openDisabled)
            }
            iconButton("trash", help: L("transcribe.recent.delete"), tint: .red, action: onDelete)
        }
        .padding(DS.Spacing.cardPadding)
        // forceMaterial: Liquid Glass у пачки карточек в скролле рисует общий
        // серый бэкдроп на весь viewport с резкими углами — материал такого
        // слоя не создаёт (та же ловушка, что у карточек истории).
        .glassSurface(radius: DS.Radius.card, forceMaterial: true)
    }

    private var fileIcon: String {
        let ext = (record.fileName as NSString).pathExtension.lowercased()
        return FileTranscriptionController.videoExtensions.contains(ext) ? "film" : "waveform"
    }

    /// «Дата · сервис [· длительность]».
    private var subtitle: String {
        var parts = [record.date.formatted(date: .abbreviated, time: .shortened), providerLabel]
        if case .done = record.status, let duration = record.duration, duration > 0 {
            parts.append(clockMMSS(duration))
        }
        return parts.joined(separator: " · ")
    }

    /// Название сервиса: builtin — локализованное, кастомный пресет — как есть
    /// (тот же маппинг, что в инспекторе истории).
    private var providerLabel: String {
        TranscriptionProvider(rawValue: record.provider)?.title ?? record.provider
    }

    @ViewBuilder
    private var statusView: some View {
        switch record.status {
        case .inProgress:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(L("transcribe.recent.status.inProgress"))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        case .done:
            Text(L("transcribe.recent.status.done"))
                .font(.caption)
                .foregroundStyle(.green)
        case .error(let message):
            // Полный текст ошибки — в тултипе по наведению.
            Text(L("transcribe.recent.status.error"))
                .font(.caption)
                .foregroundStyle(DS.RecorderTone.error)
                .help(message)
        case .cancelled:
            Text(L("transcribe.recent.status.cancelled"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func iconButton(_ symbol: String, help: String,
                            tint: Color = .secondary, action: @escaping () -> Void) -> some View {
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
