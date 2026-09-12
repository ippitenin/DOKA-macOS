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
    /// Запись для шита «Распознать заново».
    @State private var retranscribing: FileTranscriptRecord?
    @State private var isPickingRetryFile = false
    /// Идёт проверка исходника перед «Повторить» (вне главного потока).
    @State private var isPlanningRetry = false
    /// Почему «Повторить» не запустился — у кнопки, а не фазой страницы.
    @State private var retryNote: String?
    /// Строки, где открыт редактор реплики или поповер спикера: пока они есть,
    /// клавиши плеера и Esc «назад» молчат, а лента не следует за плеером.
    @State private var segmentInteractions: Set<SegmentInteractionKey> = []
    /// Курсор в поле «Свой запрос» карточки анализа — клавиши записи молчат,
    /// как и при открытом редакторе реплики.
    @State private var isEditingAnalysisPrompt = false

    private struct SegmentInteractionKey: Hashable {
        let index: Int
        let isEditor: Bool
    }
    @FocusState private var focus: FocusTarget?

    private enum FocusTarget: Hashable { case root, rename }
    private enum RecordAlert { case deleteRecord, deleteAudio, retryBilled(RetryRun), resetEdits }

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
                case .retryBilled(let run):
                    Button(L("library.retranscribe.run")) { runRetry(run) }
                case .resetEdits:
                    Button(L("transcribe.edits.resetAll.confirm"), role: .destructive) {
                        document.resetAllEdits()
                    }
                }
                Button(L("common.cancel"), role: .cancel) {}
            } message: { alert in
                switch alert {
                case .deleteRecord: Text(L("library.delete.message"))
                case .deleteAudio: Text(L("library.deleteAudio.message"))
                case .resetEdits: Text(L("transcribe.edits.resetAll.message"))
                case .retryBilled(let run):
                    // Повтор идёт по сохранённым параметрам — с анализом Nexara,
                    // если он был заказан: оплачивается и он.
                    Text(run.params.effectiveLLMPrompt == nil
                            ? L("library.retry.billed.message")
                            : L("library.retry.billed.messageAnalysis"))
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
            guard !isRenaming, segmentInteractions.isEmpty, !isEditingAnalysisPrompt,
                  onBack != nil else { return .ignored }
            goBack()
            return .handled
        }
        // Вью только что вставлена в окно — фокус со следующего цикла, иначе
        // клавиши не работают до первого клика по записи.
        .onAppear { DispatchQueue.main.async { focus = .root } }
        // Шит и выбор файла — только у детали: ошибочные записи inline не
        // показываются, а второй `.fileImporter` внутри страницы
        // «Транскрибация» (у неё свой) SwiftUI обслуживает ненадёжно.
        .sheet(item: $retranscribing) { record in
            RetranscribeSheet(record: record) { newID in
                retranscribing = nil
                LibraryNavigator.open(newID)
            }
        }
        .fileImporter(isPresented: $isPickingRetryFile,
                      allowedContentTypes: FileTranscriptionController.importerTypes,
                      allowsMultipleSelection: false) { result in
            if case let .success(urls) = result, let url = urls.first {
                retryWithPickedFile(url)
            }
        }
    }

    /// «Назад» к списку: незаконченное переименование сначала сохраняется —
    /// кнопка фокус у поля не забирает, и сохранение по потере фокуса не сработало бы.
    private func goBack() {
        if isRenaming { finishRename(commit: true) }
        onBack?()
    }

    private func playbackKey(_ action: (URL) -> Void) -> KeyPress.Result {
        guard !isRenaming, segmentInteractions.isEmpty, !isEditingAnalysisPrompt,
              let url = audioURL else { return .ignored }
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
            if record.status != .inProgress {
                retranscribeButton(record)
            }
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
            failedCard(record, icon: "exclamationmark.triangle.fill", tint: DS.RecorderTone.error, text: message)
        case .cancelled:
            failedCard(record, icon: "stop.circle", tint: .secondary, text: L("library.cancelled.message"))
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
            if let result = output {
                // Карточка «Анализ» — и список готовых отчётов, и запуск
                // нового; тайм-коды в ответе кликабельны, только если есть
                // что перематывать.
                AnalysisPanelView(document: document,
                                  seekDuration: audioURL == nil ? nil : seekLimit(result),
                                  allowsTemplateEditor: layout == .full,
                                  onPromptFocusChange: { isEditingAnalysisPrompt = $0 })
                transcriptCard(result, proxy: proxy)
            }
        }
    }

    /// Предел для ссылок на тайм-коды: длительность записи. Именно так, а не
    /// `record?.duration ?? result.duration`: у последнего тип `Double??`, и
    /// при записи без длительности `??` не сработал бы — ссылки молча пропали.
    private func seekLimit(_ result: TranscriptResult) -> Double? {
        guard let record = document.record else { return result.duration }
        return record.duration ?? result.duration
    }

    /// Карточка «Транскрибация»: детализация тайм-кодов — здесь, в шапке:
    /// нарезка локальная и имеет смысл только у готового результата. Полоса
    /// спикеров — над свёрнутым списком, чтобы быть видимой всегда.
    private func transcriptCard(_ result: TranscriptResult, proxy: ScrollViewProxy?) -> some View {
        let roster = result.speakerRoster
        let hasEdits = !document.edits.isEmpty
        return SectionCard {
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

                // Без спикеров полоса нужна только ради «Сбросить правки».
                if !roster.isEmpty || hasEdits {
                    SpeakerStrip(roster: roster, document: document, canEdit: document.canEdit,
                                 showsReset: hasEdits && document.canEdit,
                                 onReset: { alert = .resetEdits })
                        .padding(.horizontal, DS.Spacing.cardPadding)
                        .padding(.bottom, 10)
                }

                CardDivider()

                switch layout {
                case .full:
                    segments(result, roster: roster, lazy: true, proxy: proxy)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 10)
                case .inline:
                    CollapsibleReveal {
                        segments(result, roster: roster, lazy: false, proxy: nil)
                    }
                }
            }
        }
    }

    private func segments(_ result: TranscriptResult, roster: [SpeakerInfo], lazy: Bool,
                          proxy: ScrollViewProxy?) -> some View {
        TranscriptSegmentsView(result: result, recordID: recordID,
                               canSeek: audioURL != nil, lazy: lazy,
                               scrollProxy: proxy, follower: follower,
                               editContext: document.canEdit
                                   ? SegmentEditContext(document: document, roster: roster)
                                   : nil,
                               // Редактор правит текст ДО словаря: словарь — линза поверх.
                               sourceTexts: settings.applyDictionaryToFiles
                                   ? document.source(detail: model.detail)?.segments.map(\.text)
                                   : nil,
                               suspendsFollow: !segmentInteractions.isEmpty,
                               onInteraction: { index, event in handleSegmentInteraction(index, event) },
                               onSeek: { seek(to: $0) })
    }

    /// Редактор и поповеры строк. Ключ — строка и вид: редактор строки B
    /// открывается раньше, чем закрывается редактор строки A.
    private func handleSegmentInteraction(_ index: Int, _ event: SegmentInteraction) {
        switch event {
        case .editorOpened:
            segmentInteractions.insert(SegmentInteractionKey(index: index, isEditor: true))
        case .editorClosed(let returnFocus):
            segmentInteractions.remove(SegmentInteractionKey(index: index, isEditor: true))
            // Закрыли явно — клавиши плеера и Esc «назад» снова работают сразу,
            // без клика по записи. Со следующего цикла: поле ещё в иерархии.
            if returnFocus, layout == .full {
                DispatchQueue.main.async { focus = .root }
            }
        case .popoverOpened:
            segmentInteractions.insert(SegmentInteractionKey(index: index, isEditor: false))
        case .popoverClosed:
            segmentInteractions.remove(SegmentInteractionKey(index: index, isEditor: false))
        }
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

    // MARK: - «Повторить» и «Распознать заново»

    /// Ошибка или отмена: сообщение и «Повторить» с подписью, что именно
    /// произойдёт.
    private func failedCard(_ record: FileTranscriptRecord, icon: String, tint: Color,
                            text: String) -> some View {
        SectionCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: icon)
                        .foregroundStyle(tint)
                    Text(text)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                RecordRetryRow(record: record, note: retryNote, isPlanning: isPlanningRetry,
                               onRetry: { retry(record) },
                               onRetranscribe: { retranscribing = record })
            }
            .padding(DS.Spacing.cardPadding)
        }
    }

    /// «Повторить» на месте. Бесплатный повторный опрос — сразу; остальное
    /// решает `RetryPlanner` после проверки исходника ВНЕ главного потока:
    /// доступ к файлу на «Рабочем столе» может упереться в запрос TCC, а
    /// отказ — штатный фолбэк на архив звука.
    private func retry(_ record: FileTranscriptRecord) {
        retryNote = nil
        let store = TranscriptHistoryStore.shared
        // После переноса «Папки данных» до перезапуска библиотека ничего не
        // пишет — без этого бесплатный повтор молча ничего бы не делал.
        guard !store.isFrozen else {
            retryNote = L("transcribe.error.restartRequired")
            return
        }
        if store.canRepoll(record) {
            store.repoll(record.id)
            return
        }
        let params = RecordRetry.params(for: record)
        let serviceExists = RecordRetry.serviceExists(params.providerID)
        let sourcePath = record.sourcePath
        let archive = store.audioURL(for: record.id)
        isPlanningRetry = true
        Task {
            let readable = await Task.detached {
                sourcePath.map { FileManager.default.isReadableFile(atPath: $0) } ?? false
            }.value
            isPlanningRetry = false
            guard let current = store.record(record.id) else { return }
            let context = RetryPlanner.Context(providerID: params.providerID,
                                               serviceExists: serviceExists,
                                               originalReadable: readable,
                                               hasStoredAudio: archive != nil,
                                               now: Date())
            guard let plan = RetryPlanner.plan(for: current, context: context) else { return }
            switch plan {
            case .repoll:
                store.repoll(current.id)
            case .serviceUnavailable:
                retranscribing = current
            case .rerunOriginal(let billed):
                guard let sourcePath else { return }
                propose(RetryRun(url: URL(fileURLWithPath: sourcePath), newSourcePath: nil,
                                 params: params), billed: billed)
            case .rerunStoredAudio(let billed):
                guard let archive else { return }
                propose(RetryRun(url: archive, newSourcePath: nil, params: params), billed: billed)
            case .needsFile:
                retryNote = L("library.retry.needsFile")
                isPickingRetryFile = true
            }
        }
    }

    /// Исходника и архива нет — пользователь выбрал файл сам: он же станет
    /// новым исходником записи.
    private func retryWithPickedFile(_ url: URL) {
        guard let record = document.record else { return }
        if let message = FileTranscriptionController.validationError(for: url) {
            retryNote = message
            return
        }
        retryNote = nil
        let params = RecordRetry.params(for: record)
        propose(RetryRun(url: url, newSourcePath: url.path, params: params),
                billed: RetryPlanner.isBilled(providerID: params.providerID))
    }

    /// Платный повтор — только после подтверждения.
    private func propose(_ run: RetryRun, billed: Bool) {
        if billed {
            alert = .retryBilled(run)
        } else {
            runRetry(run)
        }
    }

    private func runRetry(_ run: RetryRun) {
        guard let record = document.record else { return }
        let outcome = FileTranscriptionController.shared.start(
            source: run.url, displayName: record.fileName, params: run.params,
            target: .reuse(record.id, sourcePath: run.newSourcePath))
        switch outcome {
        case .started: retryNote = nil
        case .busy: retryNote = L("library.retry.busy")
        case .rejected(let message): retryNote = message
        }
    }

    /// «Распознать заново» — шит с выбором сервиса и параметров; результат
    /// уходит в новую запись. Без исходника и архива распознавать нечего.
    private func retranscribeButton(_ record: FileTranscriptRecord) -> some View {
        let hasSource = record.hasArchivedAudio || record.sourcePath != nil
        return Button {
            retranscribing = record
        } label: {
            Label(L("library.retranscribe"), systemImage: "arrow.triangle.2.circlepath")
        }
        .dsGlassButton()
        .disabled(!hasSource)
        .help(hasSource ? L("library.retranscribe.help") : L("library.retranscribe.noSource"))
    }

    // MARK: - Алерт

    private var alertTitle: String {
        switch alert {
        case .deleteAudio: return L("library.deleteAudio.title")
        case .retryBilled: return L("library.retry.billed.title")
        case .resetEdits: return L("transcribe.edits.resetAll.title")
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
                } else if record.jobID != nil {
                    // Добор после перезапуска или повторный опрос — задача стора.
                    Button(L("transcribe.cancel")) {
                        TranscriptHistoryStore.shared.cancelRecovery(record.id)
                    }
                    .dsGlassButton()
                }
            }
            .padding(DS.Spacing.cardPadding)
        }
    }
}

/// Повтор на месте, который осталось подтвердить (тарификация) и запустить.
private struct RetryRun {
    let url: URL
    /// Новый путь исходника (файл выбран заново); nil — прежний.
    let newSourcePath: String?
    let params: FileTranscriptionParams
}

/// Общие правила «Повторить» для записи и её кнопки.
@MainActor
private enum RecordRetry {
    /// Параметры повтора: сохранённые в записи; у записей из журнала v1 (без
    /// `params`) — текущие параметры страницы, а сервис — текущий. Без
    /// анализа ИИ: пресет, оставленный на странице, к старой записи отношения
    /// не имеет, а повтор не должен оплачивать анализ, которого у неё не было.
    static func params(for record: FileTranscriptRecord) -> FileTranscriptionParams {
        record.params ?? FileTranscriptionController.shared.pageParams.withoutLLM()
    }

    /// Жив ли сервис: удалённым может быть только пользовательский пресет.
    static func serviceExists(_ providerID: String) -> Bool {
        guard providerID.hasPrefix("custom:") else { return true }
        return SettingsStore.shared.customService(for: providerID) != nil
    }
}

/// Кнопка «Повторить» с подписью, что именно произойдёт (забрать с сервера
/// бесплатно / распознать заново платно / на этом Mac). Наблюдает контроллер
/// сама: занятость меняется, а вся запись от этого перерисовываться не должна.
/// Диск и Keychain здесь не трогаются — только метаданные записи.
private struct RecordRetryRow: View {
    let record: FileTranscriptRecord
    let note: String?
    let isPlanning: Bool
    let onRetry: () -> Void
    let onRetranscribe: () -> Void

    @ObservedObject private var controller = FileTranscriptionController.shared
    @ObservedObject private var settings = SettingsStore.shared

    var body: some View {
        let params = RecordRetry.params(for: record)
        let repoll = TranscriptHistoryStore.shared.canRepoll(record)
        let serviceMissing = !repoll && !RecordRetry.serviceExists(params.providerID)
        // Повторный опрос идёт мимо контроллера — ему занятость не мешает.
        let busy = controller.isTranscribing && !repoll
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                if serviceMissing {
                    // Без исходника и архива шит упёрся бы в «нечего распознавать».
                    Button(L("library.retranscribe"), action: onRetranscribe)
                        .dsGlassButton()
                        .disabled(!hasSource)
                } else {
                    Button(L("library.retry"), action: onRetry)
                        .dsGlassButton()
                        .disabled(busy || isPlanning)
                }
                if isPlanning {
                    ProgressView().controlSize(.small)
                }
                Text(hint(params: params, repoll: repoll, serviceMissing: serviceMissing, busy: busy))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            if let note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(DS.RecorderTone.error)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var hasSource: Bool { record.hasArchivedAudio || record.sourcePath != nil }

    private func hint(params: FileTranscriptionParams, repoll: Bool,
                      serviceMissing: Bool, busy: Bool) -> String {
        if busy { return L("library.retry.busy") }
        if repoll { return L("library.retry.repollHint") }
        if serviceMissing {
            return hasSource ? L("library.retry.serviceMissing") : L("library.retranscribe.noSource")
        }
        return RetryPlanner.isBilled(providerID: params.providerID)
            ? L("library.retry.billedHint")
            : L("library.retry.localHint")
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
