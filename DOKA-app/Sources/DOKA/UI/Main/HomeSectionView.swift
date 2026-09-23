import SwiftUI
import KeyboardShortcuts

/// Секция «Главная»: шаги первоначальной настройки, а когда всё готово —
/// приветственный экран с подсказкой хоткея и последней транскрипцией.
struct HomeSectionView: View {
    @ObservedObject var permissions = PermissionsManager.shared
    @ObservedObject var history = HistoryStore.shared
    /// Третий шаг зависит от выбранного сервиса.
    @ObservedObject var settings = SettingsStore.shared
    /// Наблюдается ради перерисовки по ходу скачивания: готовность спрашивается
    /// у `settings.isServiceReady`, но публикует её именно `LocalModelStore`.
    /// Без этой подписки шаг не позеленеет сам после загрузки модели.
    @ObservedObject var models = LocalModelStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var apiKey: String = ""
    @State private var keyStatus: KeyStatus = .missing
    /// Сервис, на который возвращает плитка «Облачный сервис»: у пользователя
    /// мог быть выбран пресет «своего сервиса», и уход на локальную модель с
    /// возвратом обратно не должен молча подменять его встроенным.
    @State private var lastCloudProviderID: String?

    private enum KeyStatus: Equatable {
        case missing, checking, saved, invalid(String)
    }

    /// Готовность сервиса. Локальный — через канонический `isServiceReady`
    /// (смотрит в `LocalModelStore`, Keychain не трогает). Сетевой — через
    /// мемо `keyStatus`: для него `isServiceReady` читает Keychain СИНХРОННО,
    /// а тело вью перерисовывается на каждый процент скачивания.
    private var serviceReady: Bool {
        settings.isLocalService ? settings.isServiceReady : keyStatus == .saved
    }

    private var allReady: Bool { permissions.allGranted && serviceReady }

    var body: some View {
        Group {
            if allReady {
                readyView
            } else {
                setupView
            }
        }
        .onAppear {
            permissions.startPolling()
            permissions.registerAccessibility()
            syncServiceState()
        }
        .onDisappear { permissions.stopPolling() }
        .onChange(of: settings.providerID) { _, _ in syncServiceState() }
        .onChange(of: allReady) { _, ready in
            if ready {
                SettingsStore.shared.onboardingCompleted = true
                permissions.stopPolling()
            } else {
                permissions.startPolling()
            }
        }
    }

    // MARK: - Всё готово

    private var readyView: some View {
        ZStack {
            FloatingWordsView()
            readyContent
        }
    }

    private var readyContent: some View {
        VStack(spacing: 0) {
            Spacer()

            // Фирменный логотип — готовый цветной вектор из бандла.
            DokaBrandLogo(size: 132)
                .padding(.bottom, 18)

            Text(L("home.ready.title"))
                .font(.title.bold())
                .padding(.bottom, 6)
            Text(L("home.ready.subtitle"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.bottom, 22)

            preparingHint

            hotkeyHint
                .padding(.bottom, 30)

            if let last = history.lastText {
                SectionCard {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(L("home.lastTranscription"))
                                .font(.caption.bold())
                                .foregroundStyle(.secondary)
                            Spacer()
                            CopyButton(text: last)
                        }
                        Text(last)
                            .font(.callout)
                            .lineLimit(3)
                            .textSelection(.enabled)
                    }
                    .padding(14)
                }
                .frame(maxWidth: 440)
            }

            Spacer()
        }
        .padding(.horizontal, 24)
    }

    /// Скачанная модель считается готовой уже во время прогрева, поэтому экран
    /// готовности показывается, пока CoreML ещё компилирует её под чип (это
    /// минуты). Без этой строки первая диктовка выглядела бы зависшей.
    @ViewBuilder
    private var preparingHint: some View {
        if let model = settings.selectedLocalModel,
           models.state(for: .speech(model)) == .preparing {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(L("service.local.preparing"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 22)
        }
    }

    /// Подсказка хоткея: бейджи фактического сочетания,
    /// а если оно не задано — ссылка в раздел «Клавиши».
    @ViewBuilder
    private var hotkeyHint: some View {
        if let shortcut = KeyboardShortcuts.getShortcut(for: .toggleRecording) {
            HStack(spacing: 8) {
                let keys = Self.splitKeys(shortcut.description)
                ForEach(Array(keys.enumerated()), id: \.offset) { index, key in
                    if index > 0 {
                        Text("+").font(.title2).foregroundStyle(.secondary)
                    }
                    KeyCapBadge(symbol: key)
                }
            }
        } else {
            Button(L("home.noShortcut")) {
                WindowManager.shared.showMain(section: .hotkeys)
            }
            .buttonStyle(.link)
        }
    }

    /// Разбивает строку сочетания («⌃⌥F5») на клавиши: ведущие модификаторы —
    /// по одному бейджу, остаток (клавиша, возможно многосимвольная) — целиком.
    private static func splitKeys(_ description: String) -> [String] {
        let modifierSymbols: Set<Character> = ["⌃", "⌥", "⇧", "⌘"]
        var keys: [String] = []
        var rest = Substring(description)
        while let first = rest.first, modifierSymbols.contains(first) {
            keys.append(String(first))
            rest = rest.dropFirst()
        }
        if !rest.isEmpty {
            keys.append(String(rest))
        }
        return keys
    }

    // MARK: - Шаги настройки

    private var setupView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(
                    title: L("home.welcome.title"),
                    subtitle: L("home.welcome.subtitle")
                )

                SectionCard {
                    StepRow(
                        done: permissions.micAuthorized,
                        title: L("home.step.mic.title"),
                        subtitle: L("home.step.mic.subtitle")
                    ) {
                        // Системный промпт macOS показывает только один раз.
                        // После отказа остаётся лишь путь через Системные настройки.
                        if permissions.micDenied {
                            Button(L("home.openSettings")) {
                                permissions.openMicrophoneSettings()
                            }
                            .dsProminentButton()
                        } else {
                            Button(L("home.allow")) {
                                Task { _ = await permissions.requestMicrophone() }
                            }
                            .dsProminentButton()
                        }
                    }

                    Divider().padding(.horizontal, 14)

                    StepRow(
                        done: permissions.axTrusted,
                        title: L("home.step.ax.title"),
                        subtitle: L("home.step.ax.subtitle")
                    ) {
                        Button(L("home.openSettings")) {
                            permissions.openAccessibilitySettings()
                        }
                        .dsProminentButton()
                    }

                    Divider().padding(.horizontal, 14)

                    serviceStep
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 46)
            .padding(.bottom, 20)
        }
    }

    // MARK: - Шаг «Сервис распознавания»

    /// Выбор способа распознавания: облачный сервис по ключу либо одна из
    /// локальных моделей, работающих без сети. Геометрия — как у `StepRow`,
    /// но с сеткой плиток вместо строки действий.
    private var serviceStep: some View {
        HStack(alignment: .top, spacing: 12) {
            StatusIcon(done: serviceReady)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 5) {
                    Text(L("home.step.service.title")).font(.headline)
                    HelpBubble(text: L("home.step.service.help"))
                }

                // HStack, а не LazyVGrid: грид считает высоту ряда по самой
                // высокой ячейке, но обратно её ячейкам не предлагает, и
                // плитка с короткой подписью осталась бы ниже соседей. Стек
                // свою высоту детям предлагает — вместе с maxHeight: .infinity
                // на плитке это даёт подложки одного габарита.
                HStack(alignment: .top, spacing: 10) {
                    ForEach(ServiceChoice.allCases) { choice in
                        ServiceChoiceTile(choice: choice, isSelected: choice == currentChoice) {
                            select(choice)
                        }
                    }
                }
                .frame(maxWidth: .infinity)

                choiceDetail
            }
            // Именно frame, а не Spacer как в StepRow: у ряда плиток нет
            // сильной идеальной ширины, и рядом со Spacer он бы схлопнулся.
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .animation(reduceMotion ? nil : DS.Anim.section, value: currentChoice)
    }

    @ViewBuilder
    private var choiceDetail: some View {
        switch currentChoice {
        case .cloud:
            cloudKeyFields
        case .local(let model):
            localModelDetail(model)
        }
    }

    /// Кнопка «Сохранить» и отправка по Enter активны, пока есть непустой ключ
    /// и не идёт проверка — одно условие на три места.
    private var canSaveKey: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && keyStatus != .checking
    }

    /// Ввод ключа облачного сервиса. Геометрия — как у строки поиска в
    /// «Истории»: обе половины ряда получают ОДИНАКОВЫЙ явный frame(height: 30)
    /// и стекло `glassCapsule`. Системные `.roundedBorder` и
    /// `dsProminentButton()` фиксированной высоты не имеют и с 30-точечной
    /// капсулой не совпадают, поэтому обе половины собраны вручную.
    @ViewBuilder
    private var cloudKeyFields: some View {
        if serviceReady {
            Text(L("home.keySaved"))
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    SecureField(L("home.step.key.placeholder"), text: $apiKey)
                        .textFieldStyle(.plain)
                        .onChange(of: apiKey) { _, _ in
                            if keyStatus != .checking { keyStatus = .missing }
                        }
                        .onSubmit { if canSaveKey { checkAndSave() } }
                        .padding(.horizontal, 12)
                        .frame(height: 30)
                        .glassCapsule()
                        // Ширина ограничивается СНАРУЖИ капсулы: изнутри дала
                        // бы пилюлю 320 плюс паддинги.
                        .frame(maxWidth: 320)

                    Button {
                        checkAndSave()
                    } label: {
                        Text(L("home.save"))
                            .font(.callout.weight(.medium))
                            .foregroundStyle(canSaveKey ? AnyShapeStyle(DS.accent)
                                                        : AnyShapeStyle(.tertiary))
                            .padding(.horizontal, 14)
                            .frame(height: 30)
                            .contentShape(Capsule(style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .glassCapsule(interactive: true)
                    .disabled(!canSaveKey)

                    Spacer(minLength: 0)
                }
                switch keyStatus {
                case .checking:
                    Label(L("home.checkingKey"), systemImage: "hourglass")
                        .font(.caption).foregroundStyle(.secondary)
                case .invalid(let message):
                    Label(message, systemImage: "xmark.circle.fill")
                        .font(.caption).foregroundStyle(.red)
                default:
                    EmptyView()
                }
            }
        }
    }

    /// Скачивание локальной модели — тот же ряд состояний, что и в разделе
    /// «Сервис»: `LocalAssetStatusView` остаётся единственным источником этого
    /// поведения (кнопка, прогресс, отмена, удаление). Название
    /// модели идёт параметром `name` и встаёт В строку статуса на место слова
    /// «Не скачана»/«Скачана»: отдельной подписи над строкой больше нет, как и
    /// напоминания про офлайн — оно переехало в подсказку шага.
    private func localModelDetail(_ model: LocalModel) -> some View {
        LocalAssetStatusView(asset: .speech(model), name: model.plainTitle)
    }

    /// Пресет «своего сервиса» подсвечивает облачный вариант: ему тоже нужен ключ.
    private var currentChoice: ServiceChoice {
        if let local = settings.selectedLocalModel { return .local(local) }
        return .cloud
    }

    private func select(_ choice: ServiceChoice) {
        switch choice {
        case .cloud:
            // Клик по УЖЕ выбранному облачному варианту не трогает providerID:
            // иначе выбранный пользователем пресет «custom:<uuid>» молча
            // сменился бы на встроенный сервис.
            guard settings.isLocalService else { return }
            settings.providerID = lastCloudProviderID ?? TranscriptionProvider.builtin.rawValue
        case .local(let model):
            guard settings.providerID != model.providerID else { return }
            settings.providerID = model.providerID
        }
        // Дальше сработает onChange(of: settings.providerID) → syncServiceState().
    }

    /// Приводит состояние шага к активному сервису. Keychain читается ТОЛЬКО
    /// здесь (по событию: показ секции или смена варианта) и только для
    /// сетевого сервиса — у локального ключа нет вовсе.
    private func syncServiceState() {
        apiKey = ""
        guard !settings.isLocalService else {
            keyStatus = .missing        // для локального сервиса не используется
            return
        }
        // Протухнуть не может: удалить пресет можно лишь в разделе «Сервис», а
        // переход между секциями пересоздаёт вью (`.id(state.section)`) вместе
        // с этим @State.
        lastCloudProviderID = settings.providerID
        keyStatus = settings.isServiceReady ? .saved : .missing
    }

    private func checkAndSave() {
        let settings = SettingsStore.shared
        guard let config = settings.providerConfig else {
            keyStatus = .invalid(TranscriptionClient.ClientError.notConfigured.localizedDescription)
            return
        }
        let account = settings.currentKeychainAccount
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        keyStatus = .checking
        Task {
            let result = await TranscriptionClient().validateKey(key, config: config)
            switch result {
            case .success:
                keyStatus = KeychainHelper.setAPIKey(key, account: account)
                    ? .saved
                    : .invalid(L("error.keychainSaveFailed"))
            case .failure(let error):
                if case .noFunds = error, KeychainHelper.setAPIKey(key, account: account) {
                    keyStatus = .saved
                } else {
                    keyStatus = .invalid(error.localizedDescription)
                }
            }
        }
    }
}

// MARK: - Выбор сервиса

/// Вариант третьего шага онбординга. Пресеты «своего сервиса» сюда НЕ
/// попадают: для онбординга это тот же облачный сервис с ключом, а список
/// пресетов и их создание живут в разделе «Сервис».
private enum ServiceChoice: Equatable, Identifiable {
    case cloud
    case local(LocalModel)

    /// Ассоциированное значение не даёт синтезировать `CaseIterable` —
    /// список собирается вручную, как `ServiceMenuItem` в «Сервисе».
    static let allCases: [ServiceChoice] = [.cloud] + LocalModel.allCases.map(ServiceChoice.local)

    var id: String {
        switch self {
        case .cloud: return "cloud"
        case .local(let model): return model.providerID
        }
    }

    var symbol: String {
        switch self {
        case .cloud: return "cloud"
        case .local: return "laptopcomputer"
        }
    }

    var title: String {
        switch self {
        case .cloud: return L("home.service.cloud.title")
        case .local(let model): return model.shortTitle
        }
    }

    var caption: String {
        switch self {
        case .cloud:
            return L("home.service.cloud.caption")
        case .local(let model):
            let size = ByteCountFormatter.string(fromByteCount: model.approxDownloadBytes,
                                                 countStyle: .file)
            return L("home.service.local.caption", size)
        }
    }
}

/// Плашка варианта сервиса. Подсветка — как у карточек стиля панели
/// (`StylePreviewCard`): обводка акцентом, лёгкий масштаб, уважение Reduce
/// Motion. Подложка на `Color.primary`, а НЕ на `.white`: белый тинт в светлой
/// теме невидим — та же ловушка, что у плашек `OptionTile`.
private struct ServiceChoiceTile: View {
    let choice: ServiceChoice
    let isSelected: Bool
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: choice.symbol)
                    .font(.title3)
                    .foregroundStyle(isSelected ? AnyShapeStyle(DS.accent) : AnyShapeStyle(.secondary))
                Text(choice.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(choice.caption)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, 10)
            .padding(.vertical, 12)
            // Паддинги ДО frame, иначе фон не покроет ячейку целиком. Контент
            // по центру, плитка тянется на высоту ряда: подписи разной длины
            // (одна строка у облака, две у локальных) больше не дают ни разной
            // высоты подложек, ни пустого низа. minHeight — на случай широкого
            // окна, где все подписи схлопываются в строку.
            .frame(maxWidth: .infinity, minHeight: 72, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.badge, style: .continuous)
                    .fill(Color.primary.opacity(isHovering ? 0.08 : 0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.badge, style: .continuous)
                    .strokeBorder(isSelected ? DS.accent : Color.primary.opacity(0.12),
                                  lineWidth: isSelected ? 2 : 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .scaleEffect(isSelected && !reduceMotion ? 1.02 : 1.0)
        .animation(reduceMotion ? nil : DS.Anim.hover, value: isSelected)
        .animation(DS.Anim.hover, value: isHovering)
    }
}
