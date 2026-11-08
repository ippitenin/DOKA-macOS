import SwiftUI

/// Под-страница «Общих» «Доступ для ИИ-агентов»: главный тумблер локального
/// сервера, подключение любого агента (адрес, токен, готовая настройка под
/// выбранный клиент), API для программ, разрешения и журнал обращений.
/// Устройство сервера — `Agent/CLAUDE.md`.
struct AgentAccessView: View {
    @ObservedObject var access = AgentAccessSettings.shared
    @ObservedObject var server = AgentServerController.shared
    @ObservedObject var log = AgentServerController.shared.log
    let onBack: () -> Void

    @State private var confirmNewToken = false
    @FocusState private var portFocused: Bool
    /// Журнал раскрыт целиком (все хранимые 50), иначе — первые 20.
    @State private var showsAllActivity = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.cardPadding) {
                backButton
                SectionHeader(title: L("agent.title"), subtitle: L("agent.subtitle"))
                    .padding(.bottom, 2)
                serverCard
                if access.isEnabled {
                    connectionCard
                    apiCard
                }
                permissionsCard
                activityCard
            }
            .padding(.horizontal, DS.Spacing.section)
            .padding(.top, 46)
            .padding(.bottom, 20)
            // Клик в пустое место снимает фокус с поля порта (macOS сам этого
            // не делает) — и порт применяется, как по Enter. Приём словаря:
            // тумблеры и кнопки свои клики получают сами.
            .contentShape(Rectangle())
            .onTapGesture { endEditing() }
        }
        .alert(L("agent.token.confirm.title"), isPresented: $confirmNewToken) {
            Button(L("agent.token.confirm.ok"), role: .destructive) { server.regenerateToken() }
            Button(L("common.cancel"), role: .cancel) {}
        } message: {
            Text(L("agent.token.confirm.message"))
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

    // MARK: - Сервер

    private var serverCard: some View {
        SettingsCard(footer: L("agent.enabled.footer")) {
            SettingsRow(title: L("agent.enabled"), help: L("agent.enabled.help")) {
                SettingsSwitch(isOn: $access.isEnabled)
            }
            if access.isEnabled {
                CardDivider()
                HStack(spacing: 8) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)
                    Text(statusText)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, DS.Spacing.cardPadding)
                .padding(.vertical, 9)
                CardDivider()
                SettingsRow(title: L("agent.port"), help: L("agent.port.help")) {
                    // Системное поле, как у ключа и адреса в «Сервисе»: в строках
                    // настроек однострочные поля нативные. Ширина — под пять цифр.
                    TextField("", value: $access.port, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospacedDigit())
                        .multilineTextAlignment(.trailing)
                        .focused($portFocused)
                        .onSubmit { endEditing() }
                        .frame(width: 64)
                }
            }
        }
    }

    private func endEditing() {
        guard portFocused else { return }
        portFocused = false
        NSApp.keyWindow?.makeFirstResponder(nil)
    }

    private var statusText: String {
        switch server.status {
        case .off: return L("agent.status.off")
        case .starting: return L("agent.status.starting")
        case .running(let port): return L("agent.status.running", "127.0.0.1:\(port)")
        case .failed(let message): return L("agent.status.failed", message)
        }
    }

    private var statusColor: Color {
        switch server.status {
        case .running: return .green
        case .failed: return .red
        case .off, .starting: return .secondary
        }
    }

    // MARK: - Подключение агента

    /// Выбранный клиент в списке «Готовая настройка для:» — удобство одного
    /// человека, поэтому `@AppStorage`, а не настройка `AgentAccessSettings`.
    @AppStorage("agentAccessClient") private var clientRaw = AgentClient.claudeCode.rawValue

    private var client: Binding<AgentClient> {
        Binding(get: { AgentClient(rawValue: clientRaw) ?? .claudeCode },
                set: { clientRaw = $0.rawValue })
    }

    private var connectionCard: some View {
        SettingsCard(header: L("agent.connect"), footer: L("agent.connect.footer")) {
            copyRow(title: L("agent.connect.address"), value: server.endpointURL, shown: server.endpointURL)
            CardDivider()
            if let token = server.token {
                // На экране токен замаскирован, целиком — только в буфере обмена.
                let masked = AgentServerController.masked(token)
                copyRow(title: L("agent.connect.token"), value: token, shown: masked, secret: true)
                CardDivider()
                SettingsRow(title: L("agent.connect.setupFor")) {
                    // Постоянная ширина под самый длинный пункт («Другие
                    // (Claude Desktop и пр.)»): 180 по умолчанию его обрезали.
                    SettingsPopup(selection: client, title: \.title, width: 250)
                }
                let selected = client.wrappedValue
                copyRow(title: selected.placeHint,
                        value: selected.snippet(url: server.endpointURL, token: token),
                        shown: selected.snippet(url: server.endpointURL, token: masked),
                        secret: true, lines: 12)
                CardDivider()
            }
            HStack {
                Button(L("agent.token.new")) { confirmNewToken = true }
                    .dsGlassButton()
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DS.Spacing.cardPadding)
            .padding(.vertical, 10)
        }
    }

    // MARK: - API для программ

    /// Обычный API для программ (OpenAI-совместимый) — отдельно от агентов:
    /// его тумблер — разрешение `openAIAPI`, ключ — тот же токен.
    private var apiCard: some View {
        SettingsCard(header: L("agent.api.title"), footer: L("agent.api.footer")) {
            SettingsRow(title: AgentPermission.openAIAPI.title, help: AgentPermission.openAIAPI.help) {
                SettingsSwitch(isOn: Binding(
                    get: { access.isAllowed(.openAIAPI) },
                    set: { access.set(.openAIAPI, allowed: $0) }))
            }
            if access.isAllowed(.openAIAPI), let token = server.token {
                let masked = AgentServerController.masked(token)
                CardDivider()
                copyRow(title: L("agent.connect.apiBase"), value: apiBaseURL, shown: apiBaseURL)
                CardDivider()
                copyRow(title: L("agent.connect.apiKey"), value: token, shown: masked, secret: true)
                CardDivider()
                copyRow(title: L("agent.connect.apiExample"),
                        value: apiExample(token: token), shown: apiExample(token: masked), secret: true)
            }
        }
    }

    /// Адрес OpenAI-совместимого API (`base_url` в SDK OpenAI).
    private var apiBaseURL: String { "http://127.0.0.1:\(access.port)/v1" }

    private func apiExample(token: String) -> String {
        "curl \(apiBaseURL)/audio/transcriptions -H \"Authorization: Bearer \(token)\" -F file=@audio.m4a -F model=whisper-1"
    }

    /// `value` уходит в буфер обмена, `shown` — на экран (с замаскированным
    /// токеном). Выделять текст нельзя: копируется только кнопкой. Значение —
    /// в плоской плашке во всю ширину строки, как поля ввода DOKA: у всех
    /// строк одна ширина, а не случайная длина текста.
    private func copyRow(title: String, value: String, shown: String, secret: Bool = false,
                         lines: Int = 3) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer(minLength: 12)
                CopyButton(text: value, secret: secret)
            }
            Text(shown)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(lines)
                .truncationMode(.middle)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .dsFieldBox(isFocused: false, showsBox: true, multiline: true)
        }
        .padding(.horizontal, DS.Spacing.cardPadding)
        .padding(.vertical, 9)
    }

    // MARK: - Разрешения

    private var permissionsCard: some View {
        SettingsCard(header: L("agent.permissions"), footer: L("agent.permissions.footer")) {
            ForEach(Array(AgentPermission.agentCases.enumerated()), id: \.element) { index, permission in
                if index > 0 { CardDivider() }
                SettingsRow(title: permission.title, help: permission.help) {
                    SettingsSwitch(isOn: Binding(
                        get: { access.isAllowed(permission) },
                        set: { access.set(permission, allowed: $0) }))
                }
            }
        }
    }

    // MARK: - Журнал

    /// Свёрнуто — первые 20, «Показать ещё N» раскрывает остальные хранимые
    /// (до 50). Обычный `VStack`: строк мало, ленивый стек в карточке не нужен.
    /// Подпись честно говорит, что хранится и сколько вытеснено.
    private var activityCard: some View {
        let entries = log.entries
        let hidden = AgentActivityLog.hiddenCount(stored: entries.count)
        let shown = showsAllActivity ? entries : Array(entries.prefix(AgentActivityLog.collapsedCount))
        return SettingsCard(header: L("agent.activity"),
                            footer: entries.isEmpty ? nil
                                : AgentActivityLog.footer(stored: entries.count, total: log.totalCount)) {
            if entries.isEmpty {
                Text(L("agent.activity.empty"))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, DS.Spacing.cardPadding)
                    .padding(.vertical, 10)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(shown) { entry in
                        activityRow(entry)
                    }
                }
                CardDivider()
                HStack(spacing: 12) {
                    Button(L("agent.activity.clear")) {
                        log.clear()
                        showsAllActivity = false
                    }
                    .dsGlassButton()
                    Spacer(minLength: 0)
                    if hidden > 0 {
                        Button(showsAllActivity ? L("agent.activity.collapse")
                               : L("agent.activity.showMore", hidden)) {
                            withAnimation(DS.Anim.section) { showsAllActivity.toggle() }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(DS.accent)
                    }
                }
                .padding(.horizontal, DS.Spacing.cardPadding)
                .padding(.vertical, 10)
            }
        }
    }

    private func activityRow(_ entry: AgentActivityLog.Entry) -> some View {
        HStack(spacing: 10) {
            Text(entry.date, format: .dateTime.hour().minute().second())
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Text(entry.tool)
                .font(.caption.monospaced())
            Spacer(minLength: 8)
            Text(outcomeText(entry.outcome))
                .font(.caption)
                .foregroundStyle(outcomeColor(entry.outcome))
        }
        .padding(.horizontal, DS.Spacing.cardPadding)
        .padding(.vertical, 5)
    }

    private func outcomeText(_ outcome: AgentActivityLog.Outcome) -> String {
        switch outcome {
        case .done: return L("agent.activity.done")
        case .denied: return L("agent.activity.denied")
        case .failed: return L("agent.activity.failed")
        }
    }

    private func outcomeColor(_ outcome: AgentActivityLog.Outcome) -> Color {
        switch outcome {
        case .done: return .secondary
        case .denied: return .orange
        case .failed: return .red
        }
    }
}
