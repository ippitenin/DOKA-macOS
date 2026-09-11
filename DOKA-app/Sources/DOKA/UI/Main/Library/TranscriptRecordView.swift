import AppKit
import SwiftUI

/// Запись библиотеки — один компонент в двух раскладках, чтобы деталь
/// библиотеки и результат на странице «Транскрибация» не расходились:
/// - `.full` — деталь библиотеки: свой скролл, лента сегментов следует за
///   воспроизведением, плавающий плеер, клавиши (пробел, ←/→, Esc);
/// - `.inline` — результат только что распознанного файла: без своего скролла,
///   сегменты в `CollapsibleReveal`, плеер строкой в карточке.
/// Свой алерт вью держит сама — работает в обеих раскладках.
struct TranscriptRecordView: View {
    enum Layout { case full, inline }

    @ObservedObject private var document: TranscriptDocument
    private let layout: Layout
    private let onBack: (() -> Void)?

    @ObservedObject private var model = LibraryModel.shared
    /// Словарь для файлов меняет вывод — вью должна перерисоваться.
    @ObservedObject private var settings = SettingsStore.shared
    /// `@State`, а не `@StateObject`: запись НЕ должна наблюдать индекс
    /// активного сегмента — его наблюдает только список сегментов.
    @State private var follower = SegmentFollower()
    @State private var alert: RecordAlert?
    @State private var isRenaming = false
    @State private var draftTitle = ""
    @FocusState private var focus: FocusTarget?

    private enum FocusTarget: Hashable { case root, rename }
    private enum RecordAlert { case deleteRecord, deleteAudio }

    init(document: TranscriptDocument, layout: Layout, onBack: (() -> Void)? = nil) {
        _document = ObservedObject(wrappedValue: document)
        self.layout = layout
        self.onBack = onBack
    }

    private var recordID: UUID { document.recordID }

    /// Вывод под текущую детализацию (мемоизирован документом).
    private var output: TranscriptResult? { document.output(detail: model.detail) }

    /// Архив звука: метаданные записи — без обращения к диску, сам файл
    /// проверяется, только если он должен быть.
    private var audioURL: URL? {
        guard document.record?.hasArchivedAudio == true else { return nil }
        return TranscriptHistoryStore.shared.audioURL(for: recordID)
    }

    var body: some View {
        content
            // Кликабельные тайм-коды в Markdown анализа: `[12:34](doka-seek:754)`.
            .environment(\.openURL, OpenURLAction { url in handleOpenURL(url) })
            .onDisappear {
                // Уход в другую секцию посреди переименования — сохранить набранное.
                if isRenaming { finishRename(commit: true) }
                RecordingPlayer.shared.stopIfCurrent(recordID)
            }
            .onChange(of: focus) { oldValue, newValue in
                // Клик мимо поля переименования — сохранить, как в Finder.
                if oldValue == .rename, newValue != .rename, isRenaming {
                    finishRename(commit: true)
                }
            }
            .alert(alertTitle, isPresented: alertPresented, presenting: alert) { alert in
                switch alert {
                case .deleteRecord:
                    Button(L("library.delete.confirm"), role: .destructive) {
                        model.delete([recordID])
                    }
                case .deleteAudio:
                    Button(L("library.deleteAudio.confirm"), role: .destructive) {
                        TranscriptHistoryStore.shared.removeAudio(recordID)
                    }
                }
                Button(L("common.cancel"), role: .cancel) {}
            } message: { alert in
                switch alert {
                case .deleteRecord: Text(L("library.delete.message"))
                case .deleteAudio: Text(L("library.deleteAudio.message"))
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch layout {
        case .full: fullLayout
        case .inline: inlineLayout
        }
    }

    // MARK: - Раскладка «деталь библиотеки»

    private var fullLayout: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    backButton
                    if let record = document.record {
                        fullHeader(record)
                        fullActions(record)
                        statusBody(record, proxy: proxy)
                    } else {
                        noticeCard(icon: "questionmark.folder", tint: .secondary,
                                   text: L("transcribe.recordMissing"))
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 46)
                .padding(.bottom, audioURL == nil ? 20 : 84)
            }
            .modifier(ManualScrollStopsFollow { model.followPlayback = false })
            .overlay(alignment: .bottom) { floatingPlayer }
        }
        // Клавиши — на фокусируемом корне. Пока фокус в поле ввода
        // (переименование), клавишу съедает поле и сюда она не доходит.
        // Скрытая кнопка с `.keyboardShortcut(" ")` здесь не годится: key
        // equivalent перехватил бы пробел и в полях ввода.
        .focusable()
        .focusEffectDisabled()
        .focused($focus, equals: .root)
        .onKeyPress(.space) { playbackKey { TranscriptPlayback.toggle(url: $0, recordID: recordID) } }
        .onKeyPress(.leftArrow) { playbackKey { TranscriptPlayback.skip(url: $0, recordID: recordID, by: -5) } }
        .onKeyPress(.rightArrow) { playbackKey { TranscriptPlayback.skip(url: $0, recordID: recordID, by: 5) } }
        .onKeyPress(.escape) {
            guard !isRenaming, onBack != nil else { return .ignored }
            goBack()
            return .handled
        }
        // Вью только что вставлена в окно — фокус со следующего цикла, иначе
        // клавиши не работают до первого клика по записи.
        .onAppear { DispatchQueue.main.async { focus = .root } }
    }

    /// «Назад» к списку: незаконченное переименование сначала сохраняется —
    /// кнопка фокус у поля не забирает, и сохранение по потере фокуса не сработало бы.
    private func goBack() {
        if isRenaming { finishRename(commit: true) }
        onBack?()
    }

    private func playbackKey(_ action: (URL) -> Void) -> KeyPress.Result {
        guard !isRenaming, let url = audioURL else { return .ignored }
        action(url)
        return .handled
    }

    private var backButton: some View {
        Button {
            goBack()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "chevron.left")
                    .font(.footnote.weight(.semibold))
                Text(L("library.back"))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(DS.accent)
        .keyboardShortcut("[", modifiers: .command)
    }

    private func fullHeader(_ record: FileTranscriptRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            title(record, font: .title2.bold())
            HStack(spacing: 8) {
                Text(subtitle(record))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                LibraryStatusChip(record: record)
            }
        }
    }

    private func fullActions(_ record: FileTranscriptRecord) -> some View {
        HStack(spacing: 16) {
            if record.isDone, let result = output {
                CopyButton(text: TranscriptFormatter.plainText(result))
                transcriptSaveMenu(result, record: record)
            }
            Spacer()
            moreMenu(record)
        }
    }

    @ViewBuilder
    private var floatingPlayer: some View {
        if let url = audioURL {
            TranscriptPlayerBar(url: url, recordID: recordID,
                                fallbackDuration: document.record?.duration ?? 0)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .glassSurface(shadow: true)
                .padding(.horizontal, 24)
                .padding(.bottom, 14)
        }
    }

    // MARK: - Раскладка «результат на странице Транскрибация»

    @ViewBuilder
    private var inlineLayout: some View {
        if let record = document.record {
            VStack(alignment: .leading, spacing: 14) {
                inlineHeader(record)
                doneBody(proxy: nil)
            }
        }
    }

    private func inlineHeader(_ record: FileTranscriptRecord) -> some View {
        HStack(spacing: 14) {
            Image(systemName: record.fileIcon)
                .foregroundStyle(DS.accent)
            title(record, font: .headline)
            Spacer(minLength: 8)
            if let result = output {
                CopyButton(text: TranscriptFormatter.plainText(result))
                transcriptSaveMenu(result, record: record)
            }
            Button {
                LibraryNavigator.open(recordID)
            } label: {
                Label(L("library.openInLibrary"), systemImage: "books.vertical")
                    .font(.caption)
                    .foregroundStyle(DS.accent)
            }
            .buttonStyle(.plain)
            .help(L("library.openInLibrary"))
            // Скрыть результат: запись остаётся в библиотеке.
            Button {
                FileTranscriptionController.shared.hideResult()
            } label: {
                Image(systemName: "xmark.circle")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("library.hideResult"))
        }
        .padding(.top, 4)
    }

    // MARK: - Тело по статусу

    @ViewBuilder
    private func statusBody(_ record: FileTranscriptRecord, proxy: ScrollViewProxy) -> some View {
        switch record.status {
        case .inProgress:
            RecordProgressCard(record: record)
        case .error(let message):
            noticeCard(icon: "exclamationmark.triangle.fill", tint: DS.RecorderTone.error, text: message)
        case .cancelled:
            noticeCard(icon: "stop.circle", tint: .secondary, text: L("library.cancelled.message"))
        case .done:
            doneBody(proxy: proxy)
        }
    }

    @ViewBuilder
    private func doneBody(proxy: ScrollViewProxy?) -> some View {
        switch document.loadState {
        case .loading:
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
        case .missing:
            noticeCard(icon: "questionmark.folder", tint: .secondary, text: L("transcribe.recordMissing"))
        case .ready:
            if let result = output, let record = document.record {
                ForEach(document.body?.analyses ?? []) { analysis in
                    analysisCard(analysis, record: record)
                }
                transcriptCard(result, proxy: proxy)
            }
        }
    }

    /// Карточка анализа ИИ: Markdown рендерится нативно; «Скопировать» кладёт
    /// и обычный текст, и HTML — таблицы вставляются таблицами.
    private func analysisCard(_ analysis: StoredAnalysis, record: FileTranscriptRecord) -> some View {
        SectionCard {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 16) {
                    Text(analysis.title.isEmpty ? L("transcribe.llm.result.title") : analysis.title)
                        .font(.headline)
                    Spacer()
                    CopyButton(text: LightMarkdown.plainText(analysis.markdown),
                               html: LightMarkdown.html(analysis.markdown))
                    SaveAsMenu {
                        ForEach(AnalysisSaveFormat.allCases) { format in
                            Button(format.title) {
                                TextFileSaver.save(
                                    format.text(for: analysis.markdown),
                                    suggestedName: "\(record.exportBaseName)-analysis.\(format.fileExtension)")
                            }
                        }
                    }
                }
                .padding(.horizontal, DS.Spacing.cardPadding)
                .padding(.vertical, 10)

                CardDivider()

                CollapsibleReveal {
                    MarkdownView(analysis.markdown)
                }
            }
        }
    }

    /// Карточка «Транскрибация»: детализация тайм-кодов — здесь, в шапке:
    /// нарезка локальная и имеет смысл только у готового результата.
    private func transcriptCard(_ result: TranscriptResult, proxy: ScrollViewProxy?) -> some View {
        SectionCard {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Text(L("transcribe.result.title"))
                        .font(.headline)
                    Spacer(minLength: 8)
                    Text(L("transcribe.detail"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    SettingsPopup(
                        titles: TimestampDetail.allCases.map(\.title),
                        selectionIndex: Binding(
                            get: { TimestampDetail.allCases.firstIndex(of: model.detail) ?? 0 },
                            set: { model.detail = TimestampDetail.allCases[$0] }
                        ),
                        width: 150
                    )
                    HelpBubble(text: L("transcribe.detail.help"))
                }
                .padding(.horizontal, DS.Spacing.cardPadding)
                .padding(.vertical, 10)

                if layout == .inline, let url = audioURL {
                    TranscriptPlayerBar(url: url, recordID: recordID,
                                        fallbackDuration: result.duration ?? 0, showsFollow: false)
                        .padding(.horizontal, DS.Spacing.cardPadding)
                        .padding(.bottom, 8)
                }

                CardDivider()

                switch layout {
                case .full:
                    segments(result, lazy: true, proxy: proxy)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 10)
                case .inline:
                    CollapsibleReveal {
                        segments(result, lazy: false, proxy: nil)
                    }
                }
            }
        }
    }

    private func segments(_ result: TranscriptResult, lazy: Bool, proxy: ScrollViewProxy?) -> some View {
        TranscriptSegmentsView(result: result, recordID: recordID,
                               canSeek: audioURL != nil, lazy: lazy,
                               scrollProxy: proxy, follower: follower,
                               onSeek: { seek(to: $0) })
    }

    private func noticeCard(icon: String, tint: Color, text: String) -> some View {
        SectionCard {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon)
                    .foregroundStyle(tint)
                Text(text)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(DS.Spacing.cardPadding)
        }
    }

    // MARK: - Заголовок и переименование

    @ViewBuilder
    private func title(_ record: FileTranscriptRecord, font: Font) -> some View {
        if isRenaming {
            TextField(L("library.rename.placeholder"), text: $draftTitle)
                .textFieldStyle(.plain)
                .font(font)
                .focused($focus, equals: .rename)
                .onSubmit { finishRename(commit: true) }
                .onExitCommand { finishRename(commit: false) }
                .onAppear {
                    // Поле только что вставлено в иерархию — фокус со следующего цикла.
                    DispatchQueue.main.async { focus = .rename }
                }
        } else {
            Text(record.displayTitle)
                .font(font)
                .lineLimit(layout == .full ? 2 : 1)
                .truncationMode(.middle)
                .onTapGesture { startRename(record) }
                .help(L("library.rename"))
        }
    }

    private func startRename(_ record: FileTranscriptRecord) {
        draftTitle = record.displayTitle
        isRenaming = true
    }

    private func finishRename(commit: Bool) {
        guard isRenaming else { return }
        isRenaming = false
        if commit, let record = document.record {
            model.rename(record, to: draftTitle)
        }
        if layout == .full { focus = .root }
    }

    /// «Дата · сервис · длительность · язык · исходный файл (если заголовок свой)».
    private func subtitle(_ record: FileTranscriptRecord) -> String {
        var parts = [record.metaLine]
        if let code = record.language,
           let language = TranscriptionLanguage.all.first(where: { $0.id == code }), code != "auto" {
            parts.append(language.title)
        }
        if record.title != nil {
            parts.append(record.fileName)
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Меню и действия

    private func transcriptSaveMenu(_ result: TranscriptResult, record: FileTranscriptRecord) -> some View {
        SaveAsMenu {
            ForEach(SaveFormat.available(for: result)) { format in
                Button(format.title) {
                    TextFileSaver.save(format.text(for: result),
                                       suggestedName: "\(record.exportBaseName).\(format.fileExtension)")
                }
            }
        }
    }

    private func moreMenu(_ record: FileTranscriptRecord) -> some View {
        Menu {
            Button(L("library.rename")) { startRename(record) }
            if audioURL != nil {
                Button(L("library.showAudioInFinder")) { revealAudio() }
                Button(L("library.deleteAudio")) { alert = .deleteAudio }
            }
            Divider()
            Button(L("library.delete"), role: .destructive) { alert = .deleteRecord }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L("library.more"))
    }

    private func revealAudio() {
        guard let url = audioURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Клик по тайм-коду: воспроизведение с начала сегмента, автоследование
    /// снова включено; фокус — обратно на корень, чтобы работал пробел.
    private func seek(to time: Double) {
        guard let url = audioURL else { return }
        RecordingPlayer.shared.play(url: url, recordID: recordID, from: time)
        model.followPlayback = true
        if layout == .full { focus = .root }
    }

    private func handleOpenURL(_ url: URL) -> OpenURLAction.Result {
        guard url.scheme == "doka-seek" else { return .systemAction }
        if let seconds = Double(url.absoluteString.dropFirst("doka-seek:".count)) {
            seek(to: seconds)
        }
        return .handled
    }

    // MARK: - Алерт

    private var alertTitle: String {
        switch alert {
        case .deleteAudio: return L("library.deleteAudio.title")
        case .deleteRecord, .none: return L("library.delete.title")
        }
    }

    private var alertPresented: Binding<Bool> {
        Binding(get: { alert != nil },
                set: { if !$0 { alert = nil } })
    }
}

/// Карточка выполняющейся записи: подпись прогресса и «Отменить» у задачи,
/// которая идёт сейчас. Наблюдает контроллер сама — подпись меняется часто.
private struct RecordProgressCard: View {
    let record: FileTranscriptRecord

    @ObservedObject private var controller = FileTranscriptionController.shared

    var body: some View {
        SectionCard {
            HStack(spacing: 12) {
                ProgressView().controlSize(.small)
                Text(LibraryProgressText.text(for: record, controller: controller))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                if controller.runningRecordID == record.id {
                    Button(L("transcribe.cancel")) { controller.cancelTranscription() }
                        .dsGlassButton()
                }
            }
            .padding(DS.Spacing.cardPadding)
        }
    }
}

/// Ручная прокрутка ленты выключает автоследование (macOS 15+: фаза скролла;
/// на 14 для этого есть тумблер «Следовать» в плеере).
private struct ManualScrollStopsFollow: ViewModifier {
    let onManualScroll: () -> Void

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.onScrollPhaseChange { _, newPhase in
                if newPhase == .interacting { onManualScroll() }
            }
        } else {
            content
        }
    }
}
