import SwiftUI

/// Секция «Словарь»: правила замен в распознанном тексте.
///
/// Намеренно тихий список: одна карточка, в строке всего три элемента —
/// кружок вкл/выкл, «что → на что» обычным текстом и «⋯» с остальными
/// действиями, которая проявляется при наведении. Прошлый вариант (по
/// карточке на правило, тумблер, поля в рамках, чип и корзина разных
/// размеров) пользователь счёл перегруженным.
struct DictionarySectionView: View {
    @ObservedObject var settings = SettingsStore.shared
    /// Поле в фокусе: курсор в только что добавленное правило и снятие
    /// фокуса перед удалением.
    @FocusState private var focused: RuleField?

    /// Высота зоны растворения строк у верхней кромки ленты (как у «Истории»).
    private static let topFade: CGFloat = 20

    var body: some View {
        // Отступ под шапкой равен высоте верхнего фейда ленты: лента заходит
        // вверх ровно в этот зазор и не перекрывает кнопку «Добавить правило».
        VStack(alignment: .leading, spacing: Self.topFade) {
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

            if settings.replacements.isEmpty {
                emptyState
            } else {
                rulesList
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

    // MARK: - Список

    private var rulesList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    // По значению, а не `ForEach($settings.replacements)`: привязки
                    // по ИНДЕКСУ роняли приложение при удалении — поле, которое ещё
                    // редактировалось, по окончании правки читало текст по уже
                    // несуществующему индексу (выход за границы массива).
                    ForEach(Array(settings.replacements.enumerated()), id: \.element.id) { index, rule in
                        if index > 0 { CardDivider() }
                        RuleRow(
                            id: rule.id,
                            isEnabled: rule.enabled,
                            matchesInsideWords: rule.matchInsideWords,
                            from: binding(rule.id, \.from, default: ""),
                            to: binding(rule.id, \.to, default: ""),
                            enabled: binding(rule.id, \.enabled, default: false),
                            insideWords: binding(rule.id, \.matchInsideWords, default: false),
                            focused: $focused,
                            onDelete: { delete(rule.id) }
                        )
                        .id(rule.id)
                    }
                }
                .padding(.vertical, 6)
                // Материал, а не Liquid Glass: высокая стеклянная карточка
                // отражает у кромок сайдбар и соседние контролы (см. «Общие»).
                .glassSurface(forceMaterial: true)
                .padding(.top, Self.topFade)
                .padding(.bottom, 20)
            }
            .scrollContentBackground(.hidden)
            // Как у «Истории»: overlay-скроллер ездил бы поверх строк.
            .scrollIndicators(.never)
            .mask {
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                        .frame(height: Self.topFade)
                    Color.black
                }
            }
            // Верх ленты заходит в зазор под шапкой своей маской: в покое
            // карточка стоит на прежнем месте.
            .padding(.top, -Self.topFade)
            .onChange(of: focused) { _, field in
                guard let id = field?.ruleID else { return }
                withAnimation(DS.Anim.section) { proxy.scrollTo(id, anchor: .bottom) }
            }
        }
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

    /// Привязка к полю правила ПО ID: удалённое правило читается значением по
    /// умолчанию, запись в него игнорируется — никаких индексов, которые могут
    /// устареть, пока поле ещё живо.
    private func binding<Value>(_ id: UUID, _ keyPath: WritableKeyPath<ReplacementRule, Value>,
                                default fallback: Value) -> Binding<Value> {
        Binding(
            get: { settings.replacements.first { $0.id == id }?[keyPath: keyPath] ?? fallback },
            set: { value in
                guard let index = settings.replacements.firstIndex(where: { $0.id == id }) else { return }
                settings.replacements[index][keyPath: keyPath] = value
            })
    }
}

/// Поле правила — ключ общего `@FocusState` страницы.
private enum RuleField: Hashable {
    case from(UUID)
    case to(UUID)

    var ruleID: UUID {
        switch self {
        case .from(let id), .to(let id): return id
        }
    }
}

// MARK: - Строка правила

private struct RuleRow: View {
    let id: UUID
    let isEnabled: Bool
    let matchesInsideWords: Bool
    let from: Binding<String>
    let to: Binding<String>
    let enabled: Binding<Bool>
    let insideWords: Binding<Bool>
    var focused: FocusState<RuleField?>.Binding
    let onDelete: () -> Void

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Строка «активна»: под курсором или в ней идёт правка — тогда
    /// проявляются подложки полей и «⋯».
    private var isActive: Bool {
        hovering || focused.wrappedValue?.ruleID == id
    }

    var body: some View {
        HStack(spacing: 10) {
            enabledToggle
            Group {
                RuleTextField(placeholder: L("dictionary.from"), text: from,
                              isFocused: focused.wrappedValue == .from(id), showsBox: isActive)
                    .focused(focused, equals: .from(id))
                Image(systemName: "arrow.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                HStack(spacing: 8) {
                    RuleTextField(placeholder: L("dictionary.to"), text: to,
                                  isFocused: focused.wrappedValue == .to(id), showsBox: isActive)
                        .focused(focused, equals: .to(id))
                    // Режим «внутри слов» виден и в покое, но тихо — без чипа.
                    if matchesInsideWords {
                        Text(L("dictionary.insideWords.badge"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize()
                            .help(L("dictionary.insideWords.help"))
                    }
                }
            }
            // Выключенное правило приглушено, но остаётся редактируемым.
            .opacity(isEnabled ? 1 : 0.45)
            actionsMenu
                .opacity(isActive ? 1 : 0)
        }
        .frame(height: 36)
        .padding(.horizontal, DS.Spacing.cardPadding - 4)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : DS.Anim.hover, value: isActive)
        .animation(reduceMotion ? nil : DS.Anim.control, value: isEnabled)
    }

    /// Кружок-галочка — тот же язык, что выбор записей в «Истории», вместо
    /// крупного системного тумблера.
    private var enabledToggle: some View {
        Button {
            enabled.wrappedValue.toggle()
        } label: {
            Image(systemName: isEnabled ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 17))
                .foregroundStyle(isEnabled ? AnyShapeStyle(DS.accent) : AnyShapeStyle(.tertiary))
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .accessibilityLabel(L("dictionary.enabled"))
        .accessibilityAddTraits(isEnabled ? .isSelected : [])
    }

    /// Всё редкое — в одном меню: режим «внутри слов» и удаление.
    private var actionsMenu: some View {
        Menu {
            Toggle(L("dictionary.insideWords"), isOn: insideWords)
            Divider()
            Button(L("dictionary.delete"), role: .destructive, action: onDelete)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        // `.button` + `.plain`: лейбл рисуется как есть, без рамки меню.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .focusEffectDisabled()
        .help(L("dictionary.more"))
        .accessibilityLabel(L("dictionary.more"))
    }
}

/// Поле правила: в покое — обычный текст без рамки; под курсором строки —
/// мягкая подложка; в правке — ещё и кромка акцента.
private struct RuleTextField: View {
    let placeholder: String
    let text: Binding<String>
    let isFocused: Bool
    let showsBox: Bool

    var body: some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .frame(height: 28)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.badge, style: .continuous)
                    .fill(Color.primary.opacity(showsBox || isFocused ? 0.05 : 0))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.badge, style: .continuous)
                    .strokeBorder(isFocused ? DS.accent.opacity(0.6) : .clear, lineWidth: 1)
            )
    }
}
