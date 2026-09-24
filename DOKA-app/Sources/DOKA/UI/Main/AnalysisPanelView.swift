import SwiftUI

/// Карточка «Анализ» записи: список готовых анализов, ряд запуска нового и
/// живой прогресс. Заменяет прежнюю карточку, которая умела показать только
/// анализ Nexara из запроса распознавания.
///
/// Состояние анализа — в синглтоне `AnalysisController`: секции главного окна
/// пересоздаются (`.id(section)`), и `@State` анализ бы не пережил.
struct AnalysisPanelView: View {
    @ObservedObject var document: TranscriptDocument
    /// Длительность записи — по ней тайм-коды ответа становятся ссылками.
    let seekDuration: Double?
    /// Пункт «Шаблоны…» открывает модальный шит. На странице «Транскрибация»
    /// он выключен: там уже висит свой `.fileImporter`, а вложенные модальные
    /// окна SwiftUI на macOS обслуживает ненадёжно (см. CLAUDE.md). Шаблоны
    /// правятся из раздела «Сервис».
    var allowsTemplateEditor = true
    /// Пока курсор в поле «Свой запрос», клавиши записи (пробел, Esc) должны
    /// молчать: иначе Esc уводит в список и теряет набранный промпт.
    var onPromptFocusChange: ((Bool) -> Void)?

    @ObservedObject private var controller = AnalysisController.shared
    @ObservedObject private var models = LocalModelStore.shared
    @ObservedObject private var settings = SettingsStore.shared

    /// Какой анализ показан, когда их несколько. nil — самый свежий.
    @State private var shownID: UUID?
    @State private var isCustom = false
    @State private var customPrompt = ""
    @State private var deleting: StoredAnalysis?
    @State private var showsTemplates = false
    @FocusState private var isPromptFocused: Bool

    private var recordID: UUID { document.recordID }
    private var analyses: [StoredAnalysis] { document.analyses }

    private var shown: StoredAnalysis? {
        analyses.first { $0.id == shownID } ?? analyses.last
    }

    private var run: AnalysisController.Run? {
        if case .running(let run) = controller.phase, run.recordID == recordID { return run }
        return nil
    }

    private var failure: String? {
        if case .failed(let id, let message) = controller.phase, id == recordID { return message }
        return nil
    }

    var body: some View {
        SectionCard {
            VStack(alignment: .leading, spacing: 0) {
                header
                CardDivider()
                if let run {
                    progress(run)
                } else {
                    if let failure { failureRow(failure) }
                    if let shown {
                        metadata(shown)
                        CollapsibleReveal {
                            MarkdownView(shown.markdown, seekDuration: seekDuration)
                        }
                        CardDivider()
                    }
                    newAnalysisRow
                }
            }
        }
        // Свой алерт — на панели, а не на записи: у той уже есть свой,
        // а два `.alert` на одной вью конфликтуют.
        .alert(L("analysis.deleteConfirmTitle"), isPresented: deletePresented, presenting: deleting) { item in
            Button(L("analysis.delete"), role: .destructive) {
                document.deleteAnalysis(item.id)
                shownID = nil
            }
            Button(L("common.cancel"), role: .cancel) {}
        } message: { _ in
            Text(L("analysis.deleteConfirmText"))
        }
        .sheet(isPresented: $showsTemplates) {
            AnalysisTemplatesSheet()
        }
        // Панель уходит с экрана — клавиши записи снова свободны.
        .onDisappear { onPromptFocusChange?(false) }
    }

    private var deletePresented: Binding<Bool> {
        Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
    }

    // MARK: - Шапка

    private var header: some View {
        HStack(spacing: 12) {
            Text(L("analysis.title"))
                .font(.headline)
            if analyses.count > 1 {
                SettingsPopup(
                    titles: analyses.map(listTitle),
                    selectionIndex: Binding(
                        get: { analyses.firstIndex(where: { $0.id == shown?.id }) ?? analyses.count - 1 },
                        set: { shownID = analyses.indices.contains($0) ? analyses[$0].id : nil }
                    ),
                    width: nil)
            }
            Spacer(minLength: 8)
            if let shown, run == nil {
                CopyButton(text: LightMarkdown.plainText(shown.markdown),
                           html: LightMarkdown.html(shown.markdown))
                SaveAsMenu {
                    ForEach(AnalysisSaveFormat.allCases) { format in
                        Button(format.title) {
                            TextFileSaver.save(
                                format.text(for: shown.markdown),
                                suggestedName: "\(exportBaseName)-analysis.\(format.fileExtension)")
                        }
                    }
                }
                moreMenu(shown)
            }
        }
        .padding(.horizontal, DS.Spacing.cardPadding)
        .padding(.vertical, 10)
    }

    private var exportBaseName: String {
        document.record?.exportBaseName ?? "transcript"
    }

    private func listTitle(_ analysis: StoredAnalysis) -> String {
        let name = analysis.title.isEmpty ? L("transcribe.llm.result.title") : analysis.title
        guard analysis.createdAt != .distantPast else { return name }
        return "\(name) · \(analysis.createdAt.formatted(date: .abbreviated, time: .shortened))"
    }

    private func moreMenu(_ analysis: StoredAnalysis) -> some View {
        Menu {
            if canRepeat(analysis) {
                Button(L("analysis.regenerate")) { repeatAnalysis(analysis) }
            }
            Button(L("analysis.delete"), role: .destructive) { deleting = analysis }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(!document.canEdit)
        .help(L("library.more"))
    }

    // MARK: - Метаданные готового анализа

    private func metadata(_ analysis: StoredAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(sourceLabel(analysis))
                if analysis.createdAt != .distantPast {
                    Text("·")
                    Text(analysis.createdAt.formatted(date: .abbreviated, time: .shortened))
                }
                if analysis.truncated {
                    Text("·")
                    Text(L("analysis.truncated"))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            // Расшифровку правили после анализа — отчёт описывает уже не то,
            // что в записи.
            if document.isStale(analysis) {
                HStack(spacing: 8) {
                    Label(L("analysis.stale"), systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    if canRepeat(analysis) {
                        Button(L("analysis.regenerate")) { repeatAnalysis(analysis) }
                            .buttonStyle(.plain)
                            .font(.caption)
                            .foregroundStyle(DS.accent)
                    }
                }
            }
        }
        .padding(.horizontal, DS.Spacing.cardPadding)
        .padding(.top, 8)
    }

    private func sourceLabel(_ analysis: StoredAnalysis) -> String {
        switch analysis.source {
        case .nexara: return L("analysis.source.nexara")
        case .local(let modelID):
            let name = modelID == LLMModelSpec.current.id
                ? LLMModelSpec.current.displayName : modelID
            return L("analysis.source.local", name)
        }
    }

    // MARK: - Прогресс

    private func progress(_ run: AnalysisController.Run) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                ProgressView(value: fraction(run.stage))
                    .frame(maxWidth: 220)
                Text(stageText(run.stage))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button(L("common.cancel")) { controller.cancel() }
                    .dsGlassButton()
            }
            if !run.partial.isEmpty {
                MarkdownView(run.partial)
                    .frame(maxHeight: 320, alignment: .top)
                    .clipped()
            }
        }
        .padding(DS.Spacing.cardPadding)
    }

    /// Неопределённых стадий нет: даже «сведение» показывает движение, иначе
    /// шкала замирает на минуты.
    private func fraction(_ stage: AnalysisController.Stage) -> Double {
        switch stage {
        case .loadingModel: return 0.02
        case .reading(let value): return 0.05 + value * 0.35
        case .part(let index, let total, let value):
            let step = 0.8 / Double(max(total, 1))
            return 0.05 + step * (Double(index - 1) + value * 0.9)
        case .combining: return 0.88
        case .writing: return 0.95
        }
    }

    private func stageText(_ stage: AnalysisController.Stage) -> String {
        switch stage {
        case .loadingModel: return L("analysis.progress.loading")
        case .reading(let value): return L("analysis.progress.reading", Int(value * 100))
        case .part(let index, let total, let value):
            return L("analysis.progress.part", index, total, Int(value * 100))
        case .combining: return L("analysis.progress.combining")
        case .writing: return L("analysis.progress.writing")
        }
    }

    private func failureRow(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button {
                controller.dismiss(recordID: recordID)
            } label: {
                Image(systemName: "xmark.circle")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            // Системное синее кольцо фокуса выбивается из дизайна: при полном
            // доступе с клавиатуры фокус вставал на крестик (в шитах — сразу при открытии).
            .focusEffectDisabled()
        }
        .padding(.horizontal, DS.Spacing.cardPadding)
        .padding(.top, 10)
    }

    // MARK: - Новый анализ

    private var availability: AnalysisController.Availability {
        controller.availability(for: document.record)
    }

    @ViewBuilder
    private var newAnalysisRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Модели нет (или она ещё качается) — ряд скачивания прямо здесь,
            // без похода в «Сервис».
            if !models.isDownloaded(.llm) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("analysis.model.needed"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    LocalAssetStatusView(asset: .llm, name: LLMModelSpec.current.displayName)
                }
            } else {
                controlsRow
            }
            if isCustom {
                TextField(L("analysis.customPlaceholder"), text: $customPrompt, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...5)
                    .focused($isPromptFocused)
                    .onChange(of: isPromptFocused) { _, focused in
                        onPromptFocusChange?(focused)
                    }
            }
        }
        .padding(DS.Spacing.cardPadding)
    }

    private var controlsRow: some View {
        HStack(spacing: 10) {
            SettingsPopup(titles: templateTitles,
                          selectionIndex: Binding(get: { templateIndex },
                                                  set: { selectTemplate(at: $0) }),
                          width: nil)
            Text(L("analysis.language"))
                .font(.caption)
                .foregroundStyle(.secondary)
            SettingsPopup(titles: languageTitles,
                          selectionIndex: Binding(get: { languageIndex },
                                                  set: { selectLanguage(at: $0) }),
                          width: nil)
            Spacer(minLength: 8)
            Button(L("analysis.run")) { runAnalysis() }
                .dsProminentButton()
                .disabled(!canRun)
                .help(disabledHint ?? L("analysis.run"))
        }
    }

    // MARK: - Шаблоны и язык

    private var templates: [AnalysisTemplate] { settings.allAnalysisTemplates }

    /// Порядок пунктов: встроенные → свои → «Свой запрос» → «Шаблоны…».
    private var templateTitles: [String] {
        var titles = templates.map(\.name) + [L("analysis.customPrompt")]
        if allowsTemplateEditor { titles.append(L("analysis.manageTemplates")) }
        return titles
    }

    private var templateIndex: Int {
        if isCustom { return templates.count }
        return templates.firstIndex { $0.id == settings.analysisTemplateID } ?? 0
    }

    private func selectTemplate(at index: Int) {
        if index == templates.count {
            isCustom = true
        } else if index == templates.count + 1, allowsTemplateEditor {
            showsTemplates = true
        } else if templates.indices.contains(index) {
            isCustom = false
            settings.analysisTemplateID = templates[index].id
        }
    }

    /// Первый пункт — «Как в записи», дальше языки распознавания без «Авто».
    private var languageOptions: [TranscriptionLanguage] {
        TranscriptionLanguage.all.filter { $0.id != "auto" }
    }

    private var languageTitles: [String] {
        [L("analysis.language.record")] + languageOptions.map(\.title)
    }

    private var languageIndex: Int {
        guard !settings.analysisLanguage.isEmpty,
              let index = languageOptions.firstIndex(where: { $0.id == settings.analysisLanguage })
        else { return 0 }
        return index + 1
    }

    private func selectLanguage(at index: Int) {
        // NSPopUpButton умеет отдать -1 («ничего не выбрано») — без проверки
        // это выход за границы массива.
        guard index > 0 else {
            if index == 0 { settings.analysisLanguage = "" }
            return
        }
        guard languageOptions.indices.contains(index - 1) else { return }
        settings.analysisLanguage = languageOptions[index - 1].id
    }

    // MARK: - Запуск

    private var canRun: Bool {
        guard availability.isRunnable else { return false }
        if isCustom { return !customPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return true
    }

    /// Почему кнопка неактивна — подсказкой у самой кнопки.
    private var disabledHint: String? {
        switch availability {
        case .ok: return nil
        case .modelMissing: return L("analysis.model.needed")
        case .busyTranscribing: return L("analysis.busy.transcribing")
        case .busyOtherRecord: return L("analysis.busy.other")
        case .emptyTranscript: return L("analysis.error.empty")
        case .notReady: return L("transcribe.recordMissing")
        case .frozen: return L("transcribe.error.restartRequired")
        }
    }

    private func runAnalysis() {
        let kind: AnalysisController.Request.Kind = isCustom
            ? .custom(customPrompt.trimmingCharacters(in: .whitespacesAndNewlines))
            : .template(settings.selectedAnalysisTemplate)
        controller.dismiss(recordID: recordID)
        controller.start(recordID: recordID,
                         request: .init(kind: kind,
                                        responseLanguage: settings.analysisLanguage.isEmpty
                                            ? nil : settings.analysisLanguage))
    }

    /// «Повторить» доступно только у локального анализа: у Nexara анализ
    /// приходит вместе с распознаванием, повторить его отдельно нельзя.
    private func canRepeat(_ analysis: StoredAnalysis) -> Bool {
        guard !analysis.isNexara else { return false }
        return availability.isRunnable
    }

    /// Тем же шаблоном и языком — рядом появляется новый анализ, прежний
    /// остаётся (сравнить «до» и «после» правок).
    private func repeatAnalysis(_ analysis: StoredAnalysis) {
        let kind: AnalysisController.Request.Kind
        if let templateID = analysis.templateID,
           let template = templates.first(where: { $0.id == templateID }) {
            kind = .template(template)
        } else if isCustom, !customPrompt.isEmpty {
            kind = .custom(customPrompt)
        } else {
            kind = .template(settings.selectedAnalysisTemplate)
        }
        controller.dismiss(recordID: recordID)
        controller.start(recordID: recordID,
                         request: .init(kind: kind, responseLanguage: analysis.responseLanguage))
    }
}
