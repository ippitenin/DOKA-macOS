import SwiftUI

/// «Распознать заново»: запись другим сервисом или с другими параметрами.
/// Результат уходит в НОВУЮ запись (исходная остаётся) с заголовком и звуком
/// исходной; правки не переносятся. Анализа ИИ здесь нет: повторный запрос с
/// `prompt` снова тарифицировал бы его у Nexara, а анализ — отдельное действие.
struct RetranscribeSheet: View {
    let record: FileTranscriptRecord
    /// Новая запись пошла в работу — открыть её.
    let onStarted: (UUID) -> Void

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var models = LocalModelStore.shared
    @ObservedObject private var controller = FileTranscriptionController.shared
    @State private var params: FileTranscriptionParams
    /// Есть ли ключ у сетевого сервиса — мемо детач-чтения Keychain: вызов
    /// `isServiceReady` из тела читал бы Keychain синхронно на каждой
    /// перерисовке (при висящем диалоге доступа — замороженный UI).
    @State private var hasKey = true
    @State private var note: String?
    @State private var isStarting = false

    init(record: FileTranscriptRecord, onStarted: @escaping (UUID) -> Void) {
        self.record = record
        self.onStarted = onStarted
        // Параметры — как у исходной записи (у записей из журнала v1 —
        // страницы), сервис — текущий: заново распознают обычно другим.
        var draft = (record.params ?? FileTranscriptionController.shared.pageParams).withoutLLM()
        draft.providerID = SettingsStore.shared.providerID
        _params = State(initialValue: draft)
    }

    var body: some View {
        ZStack {
            AppBackground()
            VStack(spacing: 0) {
                header
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        serviceCard
                        diarizationCard
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                }
                footer
            }
        }
        .frame(minWidth: 520, minHeight: 520)
        .task(id: params.providerID) { await refreshKey() }
        .onAppear { ensureDiarizerModel() }
        .onChange(of: params.providerID) { _, _ in ensureDiarizerModel() }
        .onChange(of: params.diarize) { _, _ in ensureDiarizerModel() }
        .animation(DS.Anim.section, value: params.diarize)
        .animation(DS.Anim.section, value: params.rolesMode)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L("library.retranscribe.title"))
                    .font(.title2.bold())
                Text(record.displayTitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(L("common.close"))
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 4)
    }

    // MARK: - Сервис и язык

    /// Пункты списка сервисов: встроенный → локальные → пресеты (как в
    /// «Сервисе», без «Новый сервис…»). Выбор — по id, не по позиции.
    private var providerIDs: [String] {
        [TranscriptionProvider.builtin.rawValue]
            + LocalModel.allCases.map(\.providerID)
            + settings.customServices.map { "custom:\($0.id.uuidString)" }
    }

    private func title(for providerID: String) -> String {
        if let model = LocalModel.from(providerID: providerID) { return model.title }
        return settings.customService(for: providerID)?.name ?? L("provider.builtin")
    }

    private var localModel: LocalModel? { LocalModel.from(providerID: params.providerID) }

    private var serviceCard: some View {
        SettingsCard {
            SettingsRow(title: L("service.provider")) {
                SettingsPopup(
                    titles: providerIDs.map(title(for:)),
                    selectionIndex: Binding(
                        get: { providerIDs.firstIndex(of: params.providerID) ?? 0 },
                        set: { index in
                            let ids = providerIDs
                            guard ids.indices.contains(index) else { return }
                            params.providerID = ids[index]
                        }
                    ),
                    // Названия сервисов длинные — ширина по содержимому.
                    width: nil
                )
            }
            readinessRows
            CardDivider()
            SettingsRow(title: L("transcribe.language")) {
                SettingsPopup(
                    titles: TranscriptionLanguage.all.map(\.title),
                    selectionIndex: Binding(
                        get: { TranscriptionLanguage.all.firstIndex { $0.id == params.language } ?? 0 },
                        set: { params.language = TranscriptionLanguage.all[$0].id }
                    )
                )
            }
        }
    }

    /// Готовность выбранного сервиса: локальная модель скачивается прямо здесь,
    /// сетевому нужен ключ из раздела «Сервис».
    @ViewBuilder
    private var readinessRows: some View {
        if let model = localModel {
            CardDivider()
            SettingsRow(title: L("service.local.status")) {
                LocalAssetStatusView(asset: .speech(model))
            }
            if !LocalModel.isAppleSiliconMac {
                CardDivider()
                warning(model.requiresAppleSilicon
                            ? L("service.local.intelUnsupported")
                            : L("service.local.intelSlow"))
            }
        } else if !remoteReady {
            CardDivider()
            warning(L("library.retranscribe.needsKey"))
        }
    }

    private func warning(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, DS.Spacing.cardPadding)
            .padding(.vertical, 9)
    }

    // MARK: - Разделение по спикерам

    private var diarizationCard: some View {
        // Сноска — только вне встроенного сервиса: у остальных часть плашек
        // видна, но недоступна, и это надо объяснить.
        SettingsCard(footer: params.isBuiltin ? nil : L("transcribe.builtinOnly")) {
            SettingsRow(title: L("transcribe.diarize"),
                        help: params.isBuiltin
                            ? L("transcribe.diarize.help")
                            : L("transcribe.diarize.helpLocal")) {
                SettingsSwitch(isOn: $params.diarize)
            }
            if params.diarize {
                if params.usesLocalDiarization {
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
                diarizationTiles
                if params.rolesModeValue == .custom && params.isBuiltin {
                    rolesEditor
                }
            }
        }
    }

    /// Те же плашки, что на странице «Транскрибация»: «Тип записи» и «Роли» —
    /// только у встроенного сервиса, вне его остаются приглушёнными
    /// (`OptionTile` сам передаёт `isEnabled` внутрь NSPopUpButton).
    private var diarizationTiles: some View {
        HStack(spacing: 10) {
            OptionTile(
                caption: L("transcribe.numSpeakers"),
                value: params.numSpeakers.map(String.init) ?? L("transcribe.numSpeakers.auto"),
                options: [L("transcribe.numSpeakers.auto")] + (1...10).map(String.init),
                selectedIndex: params.numSpeakers ?? 0,
                onSelect: { params.numSpeakers = $0 == 0 ? nil : $0 }
            )
            OptionTile(
                caption: L("transcribe.diarizeSetting"),
                value: params.diarizationSettingValue.title,
                options: DiarizationSetting.allCases.map(\.title),
                selectedIndex: DiarizationSetting.allCases.firstIndex(of: params.diarizationSettingValue) ?? 0,
                onSelect: { params.diarizationSetting = DiarizationSetting.allCases[$0].rawValue }
            )
            .disabled(!params.isBuiltin)
            OptionTile(
                caption: L("transcribe.roles"),
                value: params.rolesModeValue.title,
                options: RolesMode.allCases.map(\.title),
                selectedIndex: RolesMode.allCases.firstIndex(of: params.rolesModeValue) ?? 0,
                onSelect: { params.rolesMode = RolesMode.allCases[$0].rawValue }
            )
            .disabled(!params.isBuiltin)
        }
        .padding(.horizontal, DS.Spacing.cardPadding)
        .padding(.bottom, 9)
    }

    private var rolesEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField(L("transcribe.roles.placeholder"), text: $params.rolesText)
                .textFieldStyle(.roundedBorder)
            if let message = params.rolesValidationMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(DS.RecorderTone.error)
            }
        }
        .padding(.horizontal, DS.Spacing.cardPadding)
        .padding(.bottom, 9)
    }

    // MARK: - Запуск

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(footnote)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let reason = note ?? busyReason {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(DS.RecorderTone.error)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Spacer()
                if isStarting {
                    ProgressView().controlSize(.small)
                }
                Button(L("common.cancel")) { dismiss() }
                    .dsGlassButton()
                    .keyboardShortcut(.cancelAction)
                Button(L("library.retranscribe.run")) { run() }
                    .dsProminentButton()
                    .disabled(!canRun)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    /// «Будет создана новая запись» — и предупреждение о тарификации, если
    /// сервис сетевой (отдельного алерта нет: этот экран и есть подтверждение).
    private var footnote: String {
        var lines = [L("library.retranscribe.newRecord")]
        if RetryPlanner.isBilled(providerID: params.providerID) {
            lines.append(L("library.retranscribe.billed"))
        }
        return lines.joined(separator: "\n")
    }

    private var busyReason: String? {
        controller.isTranscribing ? L("library.retry.busy") : nil
    }

    private var remoteReady: Bool {
        hasKey && settings.providerConfig(for: params.providerID) != nil
    }

    private var serviceReady: Bool {
        if let model = localModel { return models.isDownloaded(model) }
        return remoteReady
    }

    private var canRun: Bool {
        guard serviceReady, !controller.isTranscribing, !isStarting else { return false }
        if params.usesLocalDiarization && !models.isDownloaded(.diarizer) { return false }
        return params.rolesValidationMessage == nil
    }

    /// Чтение ключа ВНЕ главного потока: диалог подтверждения доступа к
    /// Keychain (после пересборки) иначе заморозил бы приложение.
    private func refreshKey() async {
        guard localModel == nil else { return }
        let account = settings.keychainAccount(for: params.providerID)
        hasKey = await Task.detached { KeychainHelper.getAPIKey(account: account) != nil }.value
    }

    /// Локальная диаризация — модель качается сама, как на странице.
    private func ensureDiarizerModel() {
        if params.usesLocalDiarization {
            FileTranscriptionController.requestDiarizerModel()
        }
    }

    /// Источник — оригинал, если он читается (архив — сжатая копия), иначе
    /// архив звука записи. Исходник проверяется вне главного потока: доступ
    /// к «Рабочему столу» может упереться в запрос TCC.
    private func run() {
        note = nil
        isStarting = true
        let sourcePath = record.sourcePath
        let archive = TranscriptHistoryStore.shared.audioURL(for: record.id)
        Task {
            let readable = await Task.detached {
                sourcePath.map { FileManager.default.isReadableFile(atPath: $0) } ?? false
            }.value
            isStarting = false
            let source: URL
            if readable, let sourcePath {
                source = URL(fileURLWithPath: sourcePath)
            } else if let archive {
                source = archive
            } else {
                note = L("library.retranscribe.noSource")
                return
            }
            let outcome = controller.start(
                source: source, displayName: record.fileName, params: params,
                target: .new(parentID: record.id, title: record.title, sourcePath: sourcePath))
            switch outcome {
            case .started(let id): onStarted(id)
            case .busy: note = L("library.retry.busy")
            case .rejected(let message): note = message
            }
        }
    }
}
