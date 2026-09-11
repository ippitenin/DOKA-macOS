import AppKit
import SwiftUI

/// Под-страница «Расширенные» секции «Общие»: иконка в Dock, окно при
/// запуске, папка данных с полноценным переносом и библиотека транскрибаций.
/// Открывается плашкой с шевроном, закрывается кнопкой «назад» (drill-in
/// через @State родителя).
struct AdvancedSettingsView: View {
    @ObservedObject var settings = SettingsStore.shared
    let onBack: () -> Void

    /// Текущий путь папки данных; обновляется после переноса.
    @State private var folderPath = AppDataFolder.currentURL.path
    @State private var isCustomFolder = AppDataFolder.isCustom
    @State private var migrationAlert: MigrationAlert?
    /// Сколько занимает библиотека; nil — ещё считается (фоном).
    @State private var libraryUsage: (total: Int64, audio: Int64)?
    /// Алерт карточки библиотеки — один на обе ветки (стирание аудио и
    /// сокращение срока): два .alert на одной вью конфликтуют.
    @State private var libraryAlert: LibraryAlert?

    private enum MigrationAlert {
        case done(path: String)
        case failed(message: String)
    }

    private enum LibraryAlert {
        case clearAudio
        case shorten(TranscriptRetention)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.cardPadding) {
                backButton
                SectionHeader(title: L("general.advanced"))
                    .padding(.bottom, 2)
                appCard
                dataFolderCard
                transcriptsCard
            }
            .padding(.horizontal, DS.Spacing.section)
            .padding(.top, 46)
            .padding(.bottom, 20)
        }
        // Смена срока — мгновенная чистка библиотеки (onChange, не .alert:
        // с migration-алертом ниже не конфликтует). Сокращение срока до этого
        // подтверждается алертом карточки.
        .onChange(of: settings.transcriptRetention) { _, newValue in
            TranscriptHistoryStore.shared.prune(retention: newValue)
            Task { await refreshUsage() }
        }
        .alert(alertTitle, isPresented: alertPresented) {
            switch migrationAlert {
            case .done:
                Button(L("advanced.migrate.done.restart")) { AppRelaunch.relaunch() }
                Button(L("advanced.migrate.done.later"), role: .cancel) {}
            case .failed, .none:
                Button(L("common.ok"), role: .cancel) {}
            }
        } message: {
            switch migrationAlert {
            case .done(let path):
                Text(L("advanced.migrate.done.message", path))
            case .failed(let message):
                Text(message)
            case .none:
                Text("")
            }
        }
    }

    private var backButton: some View {
        Button(action: onBack) {
            HStack(spacing: 5) {
                Image(systemName: "chevron.left")
                    .font(.footnote.weight(.semibold))
                Text(L("advanced.back"))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(DS.accent)
    }

    private var appCard: some View {
        SettingsCard(header: L("advanced.appCard")) {
            SettingsRow(title: L("advanced.showDock"),
                        help: L("advanced.showDock.hint")) {
                SettingsSwitch(isOn: $settings.showDockIcon)
            }
            CardDivider()
            SettingsRow(title: L("advanced.openAtLaunch"),
                        help: L("advanced.openAtLaunch.hint")) {
                SettingsSwitch(isOn: $settings.openWindowAtLaunch)
            }
        }
    }

    private var dataFolderCard: some View {
        SettingsCard(header: L("advanced.dataFolder"),
                     footer: L("advanced.dataFolder.footer")) {
            VStack(alignment: .leading, spacing: 10) {
                Text(folderPath)
                    .font(.callout.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 10) {
                    Button(L("advanced.revealInFinder")) { revealInFinder() }
                        .dsGlassButton()
                    Button(L("advanced.changeFolder")) { changeFolder() }
                        .dsGlassButton()
                    if isCustomFolder {
                        Button(L("advanced.resetFolder")) { resetFolder() }
                            .dsGlassButton()
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, DS.Spacing.cardPadding)
            .padding(.vertical, 10)
        }
    }

    /// Карточка библиотеки транскрибаций: срок хранения, архив звука, место на
    /// диске. Библиотека лежит в общей «Папке данных» (карточка выше), поэтому
    /// отдельного переноса нет — перенос папки переносит и её.
    private var transcriptsCard: some View {
        SettingsCard(header: L("advanced.transcripts"),
                     footer: L("advanced.transcripts.footer")) {
            SettingsRow(title: L("advanced.transcripts.retention"),
                        help: L("advanced.transcripts.retention.help")) {
                SettingsPopup(
                    titles: TranscriptRetention.allCases.map(\.title),
                    selectionIndex: Binding(
                        get: { TranscriptRetention.allCases.firstIndex(of: settings.transcriptRetention) ?? 0 },
                        set: { requestRetention(TranscriptRetention.allCases[$0]) }
                    )
                )
            }
            CardDivider()
            SettingsRow(title: L("advanced.transcripts.saveAudio"),
                        help: L("advanced.transcripts.saveAudio.help")) {
                SettingsSwitch(isOn: $settings.saveTranscriptAudio)
            }
            CardDivider()
            VStack(alignment: .leading, spacing: 10) {
                Text((folderPath as NSString).appendingPathComponent(TranscriptLibraryFiles.folderName))
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
                    Button(L("advanced.revealInFinder")) { revealTranscriptsInFinder() }
                        .dsGlassButton()
                    Button(L("advanced.transcripts.clearAudio")) { libraryAlert = .clearAudio }
                        .dsGlassButton()
                        .disabled((libraryUsage?.audio ?? 0) == 0)
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, DS.Spacing.cardPadding)
            .padding(.vertical, 10)
        }
        .task { await refreshUsage() }
        // Алерт на карточке, а не на корне: на корне уже migration-алерт.
        .alert(libraryAlertTitle, isPresented: libraryAlertPresented, presenting: libraryAlert) { alert in
            switch alert {
            case .clearAudio:
                Button(L("advanced.transcripts.clearAudio.confirm"), role: .destructive) {
                    TranscriptHistoryStore.shared.removeAllAudio()
                    Task { await refreshUsage() }
                }
            case .shorten(let retention):
                Button(L("advanced.transcripts.shorten.confirm"), role: .destructive) {
                    settings.transcriptRetention = retention
                }
            }
            Button(L("common.cancel"), role: .cancel) {}
        } message: { alert in
            switch alert {
            case .clearAudio: Text(L("advanced.transcripts.clearAudio.message"))
            case .shorten: Text(L("advanced.transcripts.shorten.message"))
            }
        }
    }

    private var usageText: String {
        guard let usage = libraryUsage else { return L("advanced.transcripts.usage.calculating") }
        return L("advanced.transcripts.usage",
                 ByteCountFormatter.string(fromByteCount: usage.total, countStyle: .file),
                 ByteCountFormatter.string(fromByteCount: usage.audio, countStyle: .file))
    }

    /// Сокращение срока удаляет записи безвозвратно (с аудио и анализами) —
    /// спрашиваем, если под новый срок попадёт хоть одна запись.
    private func requestRetention(_ retention: TranscriptRetention) {
        let store = TranscriptHistoryStore.shared
        let expiring = TranscriptHistoryStore.expiredIDs(store.records, retention: retention, now: Date())
        if expiring.isEmpty {
            settings.transcriptRetention = retention
        } else {
            libraryAlert = .shorten(retention)
        }
    }

    private func refreshUsage() async {
        libraryUsage = await TranscriptHistoryStore.shared.librarySize()
    }

    // MARK: - Алерты (у каждой вью — один .alert)

    private var alertTitle: String {
        switch migrationAlert {
        case .done: return L("advanced.migrate.done.title")
        case .failed, .none: return L("advanced.migrate.failed.title")
        }
    }

    private var alertPresented: Binding<Bool> {
        Binding(
            get: { migrationAlert != nil },
            set: { if !$0 { migrationAlert = nil } }
        )
    }

    private var libraryAlertTitle: String {
        switch libraryAlert {
        case .clearAudio, .none: return L("advanced.transcripts.clearAudio.title")
        case .shorten: return L("advanced.transcripts.shorten.title")
        }
    }

    private var libraryAlertPresented: Binding<Bool> {
        Binding(
            get: { libraryAlert != nil },
            set: { if !$0 { libraryAlert = nil } }
        )
    }

    // MARK: - Действия

    private func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([AppDataFolder.currentURL])
    }

    /// Показать папку библиотеки; пока её нет (записей не было) — саму папку данных.
    private func revealTranscriptsInFinder() {
        let url = TranscriptHistoryStore.shared.files.root
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([AppDataFolder.currentURL])
        }
    }

    private func changeFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = L("advanced.changeFolder.prompt")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        migrate { try AppDataFolder.migrate(to: url) }
    }

    private func resetFolder() {
        migrate { try AppDataFolder.migrateToDefault() }
    }

    private func migrate(_ operation: () throws -> URL) {
        let store = TranscriptHistoryStore.shared
        // Идущая транскрибация или архивация/добор допишут файлы уже после
        // копирования — в папку, которую перенос удалит. Переносим в покое.
        guard !FileTranscriptionController.shared.isTranscribing, !store.hasBackgroundWork else {
            migrationAlert = .failed(message: L("advanced.migrate.error.busy"))
            return
        }
        // Плеер может держать открытым m4a внутри переносимой папки.
        RecordingPlayer.shared.stop()
        // Всё поставленное в очередь библиотеки (и стирание корзины) — на диск
        // до копирования.
        store.flush()
        do {
            let target = try operation()
            // До перезапуска библиотека больше ничего не пишет: сторы держат
            // старый путь, а старая папка уже удалена.
            store.freeze()
            folderPath = target.path
            isCustomFolder = AppDataFolder.isCustom
            migrationAlert = .done(path: target.path)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            migrationAlert = .failed(message: message)
        }
    }
}
