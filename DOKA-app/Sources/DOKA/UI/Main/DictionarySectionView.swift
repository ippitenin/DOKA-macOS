import SwiftUI

/// Секция «Словарь»: правила замен в распознанном тексте.
///
/// Сверху — карточки «ИИ-обработка» и «Системный словарь» (общие названия
/// сервисов и брендов, вход внутрь — мгновенной сменой экрана, как
/// «Расширенные» в «Общих»), ниже — личные правила пользователя. Строки
/// правил — общий `ReplacementRulesList`.
struct DictionarySectionView: View {
    @ObservedObject var settings = SettingsStore.shared
    /// Поле в фокусе: курсор в только что добавленное правило и снятие
    /// фокуса перед удалением.
    @FocusState private var focused: RuleField?
    /// Открыта ли страница системного словаря.
    @State private var showSystem = false

    var body: some View {
        if showSystem {
            SystemDictionaryView { showSystem = false }
        } else {
            personalPage
        }
    }

    private var personalPage: some View {
        // Отступ под шапкой равен высоте верхнего фейда ленты: лента заходит
        // вверх ровно в этот зазор и не перекрывает кнопку «Добавить правило».
        VStack(alignment: .leading, spacing: ReplacementRulesList.topFade) {
            // Шапка как у «Библиотеки»: заголовок, пояснение — в «вопросике»,
            // главное действие — напротив заголовка. Подпись в две строки под
            // заголовком упиралась в кнопку, и та «висела в воздухе».
            HStack(spacing: 8) {
                Text(L("section.dictionary"))
                    .font(.title.bold())
                HelpBubble(text: L("dictionary.subtitle"))
                Spacer(minLength: 12)
                Button {
                    addRule()
                } label: {
                    Label(L("dictionary.add"), systemImage: "plus")
                }
                .dsProminentButton()
            }

            DictationCleanupCard()
            SystemDictionaryCard { showSystem = true }

            if settings.replacements.isEmpty {
                emptyState
            } else {
                ReplacementRulesList(rules: $settings.replacements, focused: $focused, onDelete: delete)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 46)
        // Клик в пустое место (под карточкой, по шапке, в зазорах строк)
        // заканчивает правку: поле теряет фокус, набранное сохраняется.
        // Поля и кнопки клики получают сами — жест на предке их не перехватывает.
        .contentShape(Rectangle())
        .onTapGesture { endEditing() }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "character.book.closed")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
                .dsBreathe()
            Text(L("dictionary.empty"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    // MARK: - Действия

    private func addRule() {
        let rule = ReplacementRule(from: "", to: "")
        settings.replacements.append(rule)
        // Следующий цикл: строка должна успеть появиться.
        DispatchQueue.main.async { focused = .from(rule.id) }
    }

    private func endEditing() {
        guard focused != nil else { return }
        focused = nil
        NSApp.keyWindow?.makeFirstResponder(nil)
    }

    /// Сначала закончить редактирование (набранный текст сохранится в живое
    /// правило), удалить — следующим циклом: иначе поле удалённой строки
    /// дописывало бы текст в правило, которого уже нет.
    private func delete(_ id: UUID) {
        focused = nil
        NSApp.keyWindow?.makeFirstResponder(nil)
        DispatchQueue.main.async {
            withAnimation(DS.Anim.section) {
                settings.replacements.removeAll { $0.id == id }
            }
        }
    }
}

/// Карточка «Системный словарь» под «ИИ-обработкой»: тумблер и вход внутрь.
private struct SystemDictionaryCard: View {
    @ObservedObject private var settings = SettingsStore.shared
    let onOpen: () -> Void

    var body: some View {
        SettingsCard(forceMaterial: true) {
            SettingsRow(title: L("systemDictionary.title"), help: L("systemDictionary.toggle.help")) {
                SettingsSwitch(isOn: $settings.systemDictionaryEnabled)
            }
            CardDivider()
            SettingsRow(title: summary) {
                Button(L("systemDictionary.open"), action: onOpen)
                    .dsGlassButton()
                    .controlSize(.small)
            }
        }
    }

    /// «Правил: 359 · выключено: 3» — без согласования числа с существительным.
    private var summary: String {
        let rules = settings.systemReplacements
        let off = rules.filter { !$0.enabled }.count
        return off == 0
            ? L("systemDictionary.summary", rules.count)
            : L("systemDictionary.summaryWithOff", rules.count, off)
    }
}
