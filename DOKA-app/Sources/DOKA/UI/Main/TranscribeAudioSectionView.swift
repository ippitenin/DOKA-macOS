import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Секция «Транскрибация»: загрузка аудио/видеофайла и распознавание его в
/// текст с тайм-кодами, субтитрами и (опционально) разделением по спикерам.
/// Самостоятельная утилита, не связанная с пайплайном диктовки. Результат —
/// запись библиотеки, показанная тем же компонентом, что и деталь библиотеки.
struct TranscribeAudioSectionView: View {
    @ObservedObject private var controller = FileTranscriptionController.shared
    @ObservedObject private var settings = SettingsStore.shared
    @State private var isDropTargeted = false
    @State private var isImporterPresented = false
    /// Есть ли ключ у сетевого сервиса — мемо: `isServiceReady` читает Keychain
    /// синхронно, а тело этой страницы перерисовывается постоянно (прогресс,
    /// документ); при висящем диалоге доступа к ключу это заморозило бы UI.
    /// Обновляется по событию (появление, смена сервиса), как в онбординге.
    @State private var hasKey = true

    /// Готовность сервиса без Keychain в теле: локальному ключ не нужен.
    private var serviceReady: Bool {
        settings.isLocalService
            ? settings.isServiceReady
            : hasKey && settings.providerConfig != nil
    }

    /// Чтение ключа ВНЕ главного потока: диалог подтверждения доступа к
    /// Keychain (после пересборки) иначе заморозил бы приложение.
    private func refreshKeyReadiness() async {
        guard !settings.isLocalService else { return }
        let account = settings.currentKeychainAccount
        hasKey = await Task.detached { KeychainHelper.getAPIKey(account: account) != nil }.value
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(title: L("section.transcribeAudio"))
                    .task(id: settings.providerID) { await refreshKeyReadiness() }

                if !serviceReady {
                    notConfiguredBanner
                }

                dropZone
                optionsCard
                actionRow

                switch controller.phase {
                case .transcribing:
                    progressCard
                case .done:
                    // Результат живёт в записи библиотеки: тот же компонент и
                    // тот же документ, что у детали библиотеки.
                    if let document = controller.shownDocument {
                        TranscriptRecordView(document: document, layout: .inline)
                    }
                case let .error(message):
                    errorCard(message)
                default:
                    EmptyView()
                }

                LibraryRecentStrip()

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
            // Детализация тайм-кодов — в шапке карточки «Транскрибация» у
            // готового результата: нарезка локальная, до запуска она не нужна.
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

    // MARK: - Справка

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

    private func iconForFile(_ name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        return FileTranscriptionController.videoExtensions.contains(ext) ? "film" : "waveform"
    }

    private static let importerTypes: [UTType] = {
        var types = FileTranscriptionController.allExtensions.compactMap { UTType(filenameExtension: $0) }
        types.append(.audio)
        types.append(.movie)
        return types
    }()
}
