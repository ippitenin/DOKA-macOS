import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Секция «Транскрибация»: загрузка аудио/видеофайла и распознавание его в
/// текст с тайм-кодами, субтитрами и (опционально) разделением по спикерам.
/// Самостоятельная утилита, не связанная с пайплайном диктовки.
struct TranscribeAudioSectionView: View {
    @ObservedObject private var controller = FileTranscriptionController.shared
    @ObservedObject private var settings = SettingsStore.shared
    @State private var isDropTargeted = false
    @State private var isImporterPresented = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(title: L("section.transcribeAudio"))

                if !settings.isServiceReady {
                    notConfiguredBanner
                }

                dropZone
                optionsCard
                actionRow

                switch controller.phase {
                case .transcribing:
                    progressCard
                case let .done(result):
                    if let llmOutput = result.llmOutput {
                        analysisCard(llmOutput)
                    }
                    // Словарь для файлов — выходной слой: в фазе всегда сырой
                    // результат, замены только в том, что видно и забирается.
                    resultCard(TranscriptOutput.prepare(result))
                case let .error(message):
                    errorCard(message)
                default:
                    EmptyView()
                }

                RecentTranscriptsView()

                supportedFormatsCard
            }
            .padding(.horizontal, 24)
            .padding(.top, 46)
            .padding(.bottom, 20)
        }
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: Self.importerTypes,
            allowsMultipleSelection: false
        ) { result in
            if case let .success(urls) = result, let url = urls.first {
                controller.accept(url: url)
            }
        }
    }

    // MARK: - Зона загрузки

    private var dropZone: some View {
        // Во время распознавания зона заблокирована: подсветку drop и приём
        // нового файла глушим — иначе он отменил бы текущую задачу.
        let dropActive = isDropTargeted && !controller.isTranscribing
        return VStack(spacing: 12) {
            if let name = controller.activeFileName {
                pickedFileContent(name)
            } else {
                emptyDropContent
            }
        }
        // Фиксированная высота: контент центрируется, пустое и загруженное
        // состояния держат один размер — дропзона не прыгает после выбора файла.
        .frame(maxWidth: .infinity, minHeight: 156)
        .padding(.vertical, 20)
        .padding(.horizontal, DS.Spacing.cardPadding)
        .glassSurface()
        .overlay { dropHighlight(active: dropActive) }
        .overlay(alignment: .topTrailing) { dropRemoveButton }
        .animation(DS.Anim.hover, value: dropActive)
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            // Пока идёт распознавание — новый файл не принимаем.
            guard !controller.isTranscribing, let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in controller.accept(url: url) }
            }
            return true
        }
    }

    /// Пустое состояние зоны: иконка, подсказка, кнопка выбора файла.
    private var emptyDropContent: some View {
        Group {
            Image(systemName: "waveform.badge.plus")
                .font(.system(size: 34))
                .foregroundStyle(DS.accent)
                .dsBreathe()
            Text(L("transcribe.dropHint"))
                .font(.callout)
                .foregroundStyle(.secondary)
            Button(L("transcribe.choose")) { isImporterPresented = true }
                .dsProminentButton()
        }
    }

    /// Подсветка при перетаскивании: яркая оранжевая ОКАЁМКА + лёгкое
    /// нейтральное осветление фона (не оранжевая заливка!).
    private func dropHighlight(active: Bool) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                .fill(Color.primary.opacity(active ? 0.06 : 0))
            RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                .strokeBorder(
                    active ? DS.accent : Color.secondary.opacity(0.35),
                    style: StrokeStyle(lineWidth: active ? 2 : 1.5, dash: [7, 5])
                )
        }
    }

    /// Крестик удаления файла — в правом верхнем углу зоны. Во время
    /// распознавания скрыт: убрать файл на лету нельзя (есть «Отмена»).
    @ViewBuilder
    private var dropRemoveButton: some View {
        if controller.activeFileName != nil && !controller.isTranscribing {
            Button { controller.clear() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .padding(10)
            .help(L("transcribe.remove"))
        }
    }

    /// Загруженный файл — центрированная колонка (иконка / имя / размер), как
    /// пустое состояние; крестик удаления вынесен в правый верхний угол зоны.
    private func pickedFileContent(_ name: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: iconForFile(name))
                .font(.system(size: 34))
                .foregroundStyle(DS.accent)
            Text(name)
                .fontWeight(.medium)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 28)
            if let size = controller.activeFileSize {
                Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Параметры

    private var optionsCard: some View {
        // Сноска появляется только вне встроенного сервиса: у остальных часть
        // параметров остаётся видимой, но недоступной, и это надо объяснить.
        SettingsCard(footer: controller.isBuiltinService ? nil : L("transcribe.builtinOnly")) {
            SettingsRow(title: L("transcribe.diarize"),
                        help: controller.isBuiltinService
                            ? L("transcribe.diarize.help")
                            : L("transcribe.diarize.helpLocal")) {
                SettingsSwitch(isOn: $controller.diarize)
            }
            // Ряд компактных плашек вместо трёх строк формы — карточка и так
            // перегружена; пояснения по всем трём параметрам — в help тумблера.
            if controller.diarize {
                if controller.usesLocalDiarization {
                    diarizerModelRow
                }
                diarizationTiles
                if controller.rolesMode == .custom && controller.isBuiltinService {
                    rolesEditor
                }
            }
            CardDivider()
            SettingsRow(title: L("transcribe.language")) {
                SettingsPopup(
                    titles: TranscriptionLanguage.all.map(\.title),
                    selectionIndex: Binding(
                        get: { TranscriptionLanguage.all.firstIndex { $0.id == controller.language } ?? 0 },
                        set: { controller.language = TranscriptionLanguage.all[$0].id }
                    )
                )
            }
            CardDivider()
            SettingsRow(title: L("transcribe.detail"), help: L("transcribe.detail.help")) {
                SettingsPopup(
                    titles: TimestampDetail.allCases.map(\.title),
                    selectionIndex: Binding(
                        get: { TimestampDetail.allCases.firstIndex(of: controller.timestampDetail) ?? 0 },
                        set: { controller.timestampDetail = TimestampDetail.allCases[$0] }
                    )
                )
            }
            CardDivider()
            // Пользовательская настройка, а не параметр файла: действует на
            // любой показанный результат и переживает перезапуск.
            SettingsRow(title: L("transcribe.applyDictionary"),
                        help: L("transcribe.applyDictionary.help")) {
                SettingsSwitch(isOn: $settings.applyDictionaryToFiles)
            }
            // LLM-анализ — специфика Nexara: у кастомных OpenAI-совместимых
            // API prompt значит другое (контекстная подсказка Whisper), а
            // локальной модели такого размера на Mac нет. Строка остаётся на
            // месте приглушённой — чтобы функция не «пропадала» молча.
            CardDivider()
            SettingsRow(title: L("transcribe.llm"), help: L("transcribe.llm.help")) {
                // Гасим ТОЛЬКО контрол, а не строку целиком: `.disabled` на
                // строке убил бы и «вопросик», в котором как раз написано,
                // почему функция недоступна.
                SettingsPopup(
                    titles: LLMAnalysisPreset.allCases.map(\.title),
                    selectionIndex: Binding(
                        get: { LLMAnalysisPreset.allCases.firstIndex(of: controller.llmPreset) ?? 0 },
                        set: { controller.llmPreset = LLMAnalysisPreset.allCases[$0] }
                    )
                )
                .disabled(!controller.isBuiltinService)
                .opacity(controller.isBuiltinService ? 1 : 0.5)
            }
            if controller.llmPreset == .custom && controller.isBuiltinService {
                llmPromptEditor
            }
        }
        .animation(DS.Anim.section, value: controller.diarize)
        .animation(DS.Anim.section, value: controller.rolesMode)
        .animation(DS.Anim.section, value: controller.llmPreset)
        .animation(DS.Anim.section, value: controller.usesLocalDiarization)
        // Сервис могли сменить на локальный уже при включённой диаризации —
        // модель нужна и в этом случае.
        .onChange(of: settings.providerID) { _, _ in controller.ensureDiarizerModel() }
    }

    /// Поле своего промпта анализа: многострочное, растёт до 5 строк.
    private var llmPromptEditor: some View {
        TextField(L("transcribe.llm.customPlaceholder"),
                  text: $controller.llmCustomPrompt, axis: .vertical)
            .textFieldStyle(.roundedBorder)
            .lineLimit(2...5)
            .padding(.horizontal, DS.Spacing.cardPadding)
            .padding(.bottom, 9)
    }

    /// Ряд плашек параметров диаризации: спикеры / тип записи / роли.
    /// «Спикеры» понимают оба движка (у Nexara — `num_speakers`, у локального
    /// диаризатора — точное число кластеров), «Тип записи» и «Роли» — только
    /// Nexara: они остаются на месте приглушёнными.
    private var diarizationTiles: some View {
        HStack(spacing: 10) {
            OptionTile(
                caption: L("transcribe.numSpeakers"),
                value: controller.numSpeakers.map(String.init) ?? L("transcribe.numSpeakers.auto"),
                options: [L("transcribe.numSpeakers.auto")] + (1...10).map(String.init),
                selectedIndex: controller.numSpeakers ?? 0,
                onSelect: { controller.numSpeakers = $0 == 0 ? nil : $0 }
            )
            OptionTile(
                caption: L("transcribe.diarizeSetting"),
                value: controller.diarizationSetting.title,
                options: DiarizationSetting.allCases.map(\.title),
                selectedIndex: DiarizationSetting.allCases.firstIndex(of: controller.diarizationSetting) ?? 0,
                onSelect: { controller.diarizationSetting = DiarizationSetting.allCases[$0] }
            )
            .disabled(!controller.isBuiltinService)
            OptionTile(
                caption: L("transcribe.roles"),
                value: controller.rolesMode.title,
                options: RolesMode.allCases.map(\.title),
                selectedIndex: RolesMode.allCases.firstIndex(of: controller.rolesMode) ?? 0,
                onSelect: { controller.rolesMode = RolesMode.allCases[$0] }
            )
            .disabled(!controller.isBuiltinService)
        }
        .padding(.horizontal, DS.Spacing.cardPadding)
        .padding(.bottom, 9)
    }

    /// Состояние модели диаризатора: она нужна только вне встроенного сервиса
    /// и качается сама при включении тумблера — строка показывает прогресс,
    /// даёт отменить загрузку и удалить уже скачанную модель.
    private var diarizerModelRow: some View {
        HStack(spacing: 10) {
            Text(L("transcribe.diarize.model"))
                .font(.caption)
                .foregroundStyle(.secondary)
            LocalAssetStatusView(asset: .diarizer)
                .controlSize(.small)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Spacing.cardPadding)
        .padding(.bottom, 9)
    }

    /// Поле своего списка ролей: имена через запятую. Причина невалидности
    /// показывается тут же — та же проверка блокирует кнопку запуска.
    private var rolesEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField(L("transcribe.roles.placeholder"), text: $controller.rolesText)
                .textFieldStyle(.roundedBorder)
            if let message = controller.rolesValidationMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(DS.RecorderTone.error)
            }
        }
        .padding(.horizontal, DS.Spacing.cardPadding)
        .padding(.bottom, 9)
    }

    private var actionRow: some View {
        HStack {
            Spacer()
            Button(L("transcribe.run")) { controller.transcribe() }
                .dsProminentButton()
                .disabled(!canTranscribe)
        }
    }

    private var canTranscribe: Bool {
        guard controller.pickedFileName != nil else { return false }
        if case .transcribing = controller.phase { return false }
        // Диаризация включена, а модель ещё качается — запуск заведомо упал бы.
        if controller.isDiarizerModelMissing { return false }
        return controller.rolesValidationMessage == nil
    }

    // MARK: - Прогресс / ошибка

    private var progressCard: some View {
        SectionCard {
            HStack(spacing: 12) {
                ProgressView().controlSize(.small)
                // Локальная диаризация идёт минутами — показываем её прогресс
                // вместо неподвижного «Распознавание…».
                Text(controller.progressNote ?? L("transcribe.inProgress"))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                Button(L("transcribe.cancel")) { controller.cancelTranscription() }
                    .dsGlassButton()
            }
            .padding(DS.Spacing.cardPadding)
        }
    }

    private func errorCard(_ message: String) -> some View {
        SectionCard {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(DS.RecorderTone.error)
                Text(message)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if controller.pickedFileName != nil {
                    Button(L("transcribe.run")) { controller.transcribe() }
                        .dsGlassButton()
                }
            }
            .padding(DS.Spacing.cardPadding)
        }
    }

    // MARK: - Результат

    /// Карточка результата LLM-анализа — над транскрипцией. Тело рендерится
    /// нативно из Markdown (без символов разметки); «Скопировать» кладёт
    /// обычный текст, «Сохранить как…» — Markdown или обычный текст.
    private func analysisCard(_ llmOutput: String) -> some View {
        SectionCard {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 16) {
                    Text(L("transcribe.llm.result.title"))
                        .font(.headline)
                    Spacer()
                    CopyButton(text: LightMarkdown.plainText(llmOutput),
                               html: LightMarkdown.html(llmOutput))
                    analysisSaveAsMenu(llmOutput)
                }
                .padding(.horizontal, DS.Spacing.cardPadding)
                .padding(.vertical, 10)

                CardDivider()

                CollapsibleReveal {
                    MarkdownView(llmOutput)
                }
            }
        }
    }

    private func resultCard(_ result: TranscriptResult) -> some View {
        SectionCard {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 16) {
                    Text(L("transcribe.result.title"))
                        .font(.headline)
                    Spacer()
                    CopyButton(text: TranscriptFormatter.plainText(result))
                    saveAsMenu(result)
                    hideResultButton
                }
                .padding(.horizontal, DS.Spacing.cardPadding)
                .padding(.vertical, 10)

                CardDivider()

                CollapsibleReveal {
                    segmentsList(result)
                }
            }
        }
    }

    /// Скрыть карточки результата (вместе с «Анализом»): нужно результату,
    /// открытому из «Недавних», — у него нет другого способа закрыться.
    /// Сам результат не теряется, он остаётся в списке.
    private var hideResultButton: some View {
        Button { controller.hideResult() } label: {
            Image(systemName: "xmark.circle")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L("transcribe.result.hide"))
    }

    @ViewBuilder
    private func segmentsList(_ result: TranscriptResult) -> some View {
        if result.segments.isEmpty {
            Text(result.fullText)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            let colorIndices = speakerColorIndices(result.segments)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(result.segments.enumerated()), id: \.offset) { _, seg in
                    HStack(alignment: .top, spacing: 10) {
                        Text(timeLabel(seg.start))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .frame(width: 56, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            if let speaker = seg.speaker {
                                Text(SpeakerName.displayName(for: speaker))
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(speakerColor(speaker, indices: colorIndices))
                            }
                            Text(seg.text)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contextMenu {
                Button(L("common.copy")) {
                    ClipboardManager.setString(TranscriptFormatter.plainText(result))
                }
            }
        }
    }

    private var supportedFormatsCard: some View {
        SettingsCard(header: L("transcribe.supported.title"),
                     footer: L("transcribe.supported.size")) {
            VStack(alignment: .leading, spacing: 6) {
                Label(L("transcribe.supported.audio"), systemImage: "waveform")
                Label(L("transcribe.supported.video"), systemImage: "film")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DS.Spacing.cardPadding)
        }
    }

    private var notConfiguredBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(DS.RecorderTone.error)
            Text(settings.isLocalService
                    ? L("transcribe.local.modelMissing")
                    : L("transcribe.notConfigured"))
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(DS.Spacing.cardPadding)
        .frame(maxWidth: .infinity)
        .glassSurface()
    }

    // MARK: - Сохранить как…

    /// Меню «Сохранить как…» с единым оформлением; пункты форматов задаёт
    /// вызывающий (у результата и у анализа списки разные).
    private func saveMenu<Items: View>(@ViewBuilder items: () -> Items) -> some View {
        Menu {
            items()
        } label: {
            Label(L("transcribe.save"), systemImage: "square.and.arrow.down")
                .font(.caption)
                .foregroundStyle(DS.accent)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L("transcribe.save"))
    }

    private func saveAsMenu(_ result: TranscriptResult) -> some View {
        saveMenu {
            ForEach(availableFormats(for: result)) { format in
                Button(format.title) { saveAs(format, result) }
            }
        }
    }

    private func availableFormats(for result: TranscriptResult) -> [SaveFormat] {
        var formats: [SaveFormat] = [.plain, .timestamps]
        if result.hasSpeakers { formats += [.speakers, .timestampsSpeakers] }
        formats += [.srt, .vtt]
        return formats
    }

    private func text(for format: SaveFormat, _ result: TranscriptResult) -> String {
        switch format {
        case .plain: return TranscriptFormatter.plainText(result)
        case .timestamps: return TranscriptFormatter.textWithTimestamps(result)
        case .srt: return TranscriptFormatter.srt(result)
        case .vtt: return TranscriptFormatter.vtt(result)
        case .speakers: return TranscriptFormatter.bySpeaker(result)
        case .timestampsSpeakers: return TranscriptFormatter.textWithTimestampsAndSpeakers(result)
        }
    }

    /// Системный диалог сохранения. Приложение не в песочнице — пишем по
    /// выбранному пути напрямую. Имя по умолчанию — от исходного файла.
    private func saveAs(_ format: SaveFormat, _ result: TranscriptResult) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(controller.suggestedBaseName).\(format.fileExtension)"
        panel.canCreateDirectories = true
        // Расширение SRT/VTT системе неизвестно как UTType — формат задаёт само
        // имя файла; ограничиваем тип только для txt.
        if format.fileExtension == "txt" {
            panel.allowedContentTypes = [.plainText]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try text(for: format, result).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSLog("DOKA: не удалось сохранить транскрипцию: \(error.localizedDescription)")
        }
    }

    // MARK: - Сохранить анализ как…

    private func analysisSaveAsMenu(_ llmOutput: String) -> some View {
        saveMenu {
            ForEach(AnalysisSaveFormat.allCases) { format in
                Button(format.title) { saveAnalysis(format, llmOutput) }
            }
        }
    }

    /// Сохранение анализа в файл. Markdown — сырой llm_output; обычный текст —
    /// без символов разметки (тот же источник, что и «Скопировать»). Приложение
    /// не в песочнице — пишем по выбранному пути напрямую.
    private func saveAnalysis(_ format: AnalysisSaveFormat, _ llmOutput: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(controller.suggestedBaseName)-analysis.\(format.fileExtension)"
        panel.canCreateDirectories = true
        if format == .plain {
            panel.allowedContentTypes = [.plainText]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = format == .markdown ? llmOutput : LightMarkdown.plainText(llmOutput)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSLog("DOKA: не удалось сохранить анализ: \(error.localizedDescription)")
        }
    }

    private func iconForFile(_ name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        return FileTranscriptionController.videoExtensions.contains(ext) ? "film" : "waveform"
    }

    private func timeLabel(_ seconds: Double) -> String {
        let total = Int((seconds.isFinite && seconds > 0) ? seconds : 0)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }

    /// Индексы цветов бэйджей: `speaker_N` — по номеру (прежнее поведение),
    /// остальные (роли, unknown_N) — по порядку первого появления в
    /// результате. Детерминировано между запусками — hashValue String
    /// рандомизирован на процесс и цвет роли «плавал» бы.
    private func speakerColorIndices(_ segments: [TranscriptSegment]) -> [String: Int] {
        var indices: [String: Int] = [:]
        var nextOrdinal = 0
        for segment in segments {
            guard let speaker = segment.speaker, indices[speaker] == nil else { continue }
            if let index = SpeakerName.index(of: speaker) {
                indices[speaker] = index
            } else {
                indices[speaker] = nextOrdinal
                nextOrdinal += 1
            }
        }
        return indices
    }

    /// Детерминированный цвет бэйджа спикера по предвычисленным индексам.
    private func speakerColor(_ speaker: String, indices: [String: Int]) -> Color {
        let palette: [Color] = [
            DS.accent, DS.Aurora.indigo, DS.coral,
            Color(red: 0.44, green: 0.63, blue: 0.50),
            Color(red: 0.36, green: 0.52, blue: 0.84)
        ]
        let index = indices[speaker] ?? 0
        return palette[index % palette.count]
    }

    private static let importerTypes: [UTType] = {
        var types = FileTranscriptionController.allExtensions.compactMap { UTType(filenameExtension: $0) }
        types.append(.audio)
        types.append(.movie)
        return types
    }()
}

/// Компактная плашка «подпись + текущее значение», клик раскрывает нативное
/// меню выбора. Ряд таких плашек занимает одну строку вместо трёх строк формы.
/// Ловушка: SwiftUI `Menu` на macOS ломает кастомный многострочный лейбл
/// (плашка схлопывалась в текст с шевроном) — поэтому плашка рисуется чистым
/// SwiftUI, а кликом заведует растянутый поверх невидимый `NSPopUpButton`
/// (`isTransparent`: не рисуется, но получает события — как `PopUpButton`
/// в SettingsForm).
private struct OptionTile: View {
    let caption: String
    let value: String
    let options: [String]
    let selectedIndex: Int
    let onSelect: (Int) -> Void

    @State private var isHovering = false
    /// Плашка недоступна, когда параметр принадлежит только встроенному
    /// сервису: остаётся на месте приглушённой, чтобы было видно, что функция
    /// существует, а не исчезла.
    @Environment(\.isEnabled) private var isEnabled

    /// Ховер не должен «оживать» на недоступной плашке.
    private var showsHover: Bool { isHovering && isEnabled }

    var body: some View {
        HStack(spacing: 4) {
            VStack(alignment: .leading, spacing: 3) {
                Text(caption)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .lineLimit(1)
                Text(value)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(showsHover ? DS.accent : .secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Подложка и кромка адаптивные (Color.primary, НЕ .white: белый тинт на
        // белом фоне светлой темы невидим); ховер подсвечивает плашку кнопкой.
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.badge, style: .continuous)
                .fill(Color.primary.opacity(showsHover ? 0.08 : 0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.badge, style: .continuous)
                .strokeBorder(showsHover ? DS.accent.opacity(0.6) : Color.primary.opacity(0.12), lineWidth: 1)
        )
        .overlay(
            TilePopUpOverlay(titles: options, selectedIndex: selectedIndex,
                             isEnabled: isEnabled, onSelect: onSelect)
        )
        .opacity(isEnabled ? 1 : 0.5)
        .onHover { isHovering = $0 }
        .animation(DS.Anim.hover, value: showsHover)
    }
}

/// Невидимый NSPopUpButton на всю плашку: системное меню с галочкой на
/// выбранном пункте, кликается вся площадь. Копия паттерна `PopUpButton`
/// из SettingsForm (тот приватный и рисует стандартную кнопку).
private struct TilePopUpOverlay: NSViewRepresentable {
    let titles: [String]
    let selectedIndex: Int
    let isEnabled: Bool
    let onSelect: (Int) -> Void

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.isBordered = false
        button.isTransparent = true     // не рисует фон, но получает клики
        // Нативную стрелку гасим — свой шеврон рисует плашка (иначе задвоение).
        (button.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        button.target = context.coordinator
        button.action = #selector(Coordinator.didChange(_:))
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        // Прозрачная кнопка лежит ПОВЕРХ плашки и ловит клики сама: без явного
        // isEnabled внешний `.disabled` её не остановит (SwiftUI не пробрасывает
        // окружение внутрь NSViewRepresentable).
        button.isEnabled = isEnabled
        if button.itemTitles != titles {
            button.removeAllItems()
            // Не addItems(withTitles:) — он молча выкидывает дубликаты.
            for title in titles {
                button.menu?.addItem(NSMenuItem(title: title, action: nil, keyEquivalent: ""))
            }
        }
        if button.indexOfSelectedItem != selectedIndex,
           titles.indices.contains(selectedIndex) {
            button.selectItem(at: selectedIndex)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor
    final class Coordinator: NSObject {
        var parent: TilePopUpOverlay

        init(_ parent: TilePopUpOverlay) {
            self.parent = parent
        }

        @objc func didChange(_ sender: NSPopUpButton) {
            parent.onSelect(sender.indexOfSelectedItem)
        }
    }
}

/// Формат сохранения результата в файл.
private enum SaveFormat: String, Identifiable, CaseIterable {
    case plain, timestamps, srt, vtt, speakers, timestampsSpeakers

    var id: String { rawValue }

    var title: String {
        switch self {
        case .plain: return L("transcribe.format.plain")
        case .timestamps: return L("transcribe.format.timestamps")
        case .srt: return L("transcribe.format.srt")
        case .vtt: return L("transcribe.format.vtt")
        case .speakers: return L("transcribe.format.speakers")
        case .timestampsSpeakers: return L("transcribe.format.timestampsSpeakers")
        }
    }

    /// Расширение файла. SRT/VTT — свои; остальные текстовые форматы — .txt.
    var fileExtension: String {
        switch self {
        case .srt: return "srt"
        case .vtt: return "vtt"
        case .plain, .timestamps, .speakers, .timestampsSpeakers: return "txt"
        }
    }
}

/// Формат сохранения LLM-анализа в файл. Markdown — сырой llm_output как есть;
/// обычный текст — без символов разметки. (PDF сознательно отложен.)
private enum AnalysisSaveFormat: String, Identifiable, CaseIterable {
    case markdown, plain

    var id: String { rawValue }

    var title: String {
        switch self {
        case .markdown: return L("transcribe.analysisFormat.markdown")
        case .plain: return L("transcribe.analysisFormat.plain")
        }
    }

    var fileExtension: String {
        switch self {
        case .markdown: return "md"
        case .plain: return "txt"
        }
    }
}
