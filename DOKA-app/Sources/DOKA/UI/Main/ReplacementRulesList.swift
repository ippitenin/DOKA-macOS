import SwiftUI
import UniformTypeIdentifiers

/// Поле правила — ключ общего `@FocusState` страницы словаря.
enum RuleField: Hashable {
    case from(UUID)
    case to(UUID)

    var ruleID: UUID {
        switch self {
        case .from(let id), .to(let id): return id
        }
    }
}

/// Лента правил словаря — общая у личного и системного словарей: карточка
/// со строками, растворение у верхней кромки, прокрутка к полю в фокусе и
/// перетаскивание за ручку слева.
///
/// Порядок строк — только для показа: движок применяет длинные шаблоны
/// первыми независимо от него (`ReplacementEngine.apply`).
struct ReplacementRulesList: View {
    @Binding var rules: [ReplacementRule]
    /// Строка поиска: пустая — все правила и перетаскивание; иначе только
    /// совпавшие и без перетаскивания (порядок в выборке неоднозначен).
    var filter: String = ""
    var focused: FocusState<RuleField?>.Binding
    let onDelete: (UUID) -> Void

    /// Высота зоны растворения строк у верхней кромки ленты (как у «Истории»).
    static let topFade: CGFloat = 20

    /// Правило, которое сейчас тащат.
    @State private var dragging: UUID?

    private var visibleRules: [ReplacementRule] {
        let query = LibrarySearch.normalize(filter.trimmingCharacters(in: .whitespaces))
        guard !query.isEmpty else { return rules }
        return rules.filter {
            LibrarySearch.normalize($0.from).contains(query) || LibrarySearch.normalize($0.to).contains(query)
        }
    }

    var body: some View {
        let canReorder = filter.trimmingCharacters(in: .whitespaces).isEmpty
        ScrollViewReader { proxy in
            ScrollView {
                // ЛЕНИВО, как лента «Истории»: фон главного окна (`MeshBackground`,
                // 20 кадров/с) раскладывает окно на каждом кадре, и обычный VStack
                // держал все строки системного словаря — 352 × (два поля, меню,
                // кнопка) ≈ 2800 NSView, построение 755 мс, кадр 7 мс, DOKA ела
                // 40 % процессора на открытой странице.
                LazyVStack(spacing: 0) {
                    // По значению, а не `ForEach($rules)`: привязки по ИНДЕКСУ
                    // роняли приложение при удалении — поле, которое ещё
                    // редактировалось, по окончании правки читало текст по уже
                    // несуществующему индексу (выход за границы массива).
                    ForEach(Array(visibleRules.enumerated()), id: \.element.id) { index, rule in
                        if index > 0 { CardDivider() }
                        RuleRow(
                            id: rule.id,
                            isEnabled: rule.enabled,
                            matchesInsideWords: rule.matchInsideWords,
                            formsApplicable: Self.formsApplicable(rule),
                            canReorder: canReorder,
                            from: binding(rule.id, \.from, default: ""),
                            to: binding(rule.id, \.to, default: ""),
                            enabled: binding(rule.id, \.enabled, default: false),
                            insideWords: binding(rule.id, \.matchInsideWords, default: false),
                            wordForms: binding(rule.id, \.matchWordForms, default: true),
                            focused: focused,
                            onDragStart: {
                                dragging = rule.id
                                return NSItemProvider(object: rule.id.uuidString as NSString)
                            },
                            onDelete: { onDelete(rule.id) }
                        )
                        .id(rule.id)
                        .onDrop(of: [.text], delegate: RuleDropDelegate(target: rule.id, rules: $rules,
                                                                       dragging: $dragging))
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
            .onChange(of: focused.wrappedValue) { _, field in
                guard let id = field?.ruleID else { return }
                withAnimation(DS.Anim.section) { proxy.scrollTo(id, anchor: .bottom) }
            }
        }
    }

    /// Ловит ли правило формы, если флаг включён: для тумблера «Все формы
    /// слова» — у кириллической замены или короткого шаблона он ни на что не
    /// влияет и показывается неактивным.
    private static func formsApplicable(_ rule: ReplacementRule) -> Bool {
        var probe = rule
        probe.matchWordForms = true
        probe.matchInsideWords = false
        return ReplacementEngine.formsStem(of: probe) != nil
    }

    /// Привязка к полю правила ПО ID: удалённое правило читается значением по
    /// умолчанию, запись в него игнорируется — никаких индексов, которые могут
    /// устареть, пока поле ещё живо.
    private func binding<Value>(_ id: UUID, _ keyPath: WritableKeyPath<ReplacementRule, Value>,
                                default fallback: Value) -> Binding<Value> {
        Binding(
            get: { rules.first { $0.id == id }?[keyPath: keyPath] ?? fallback },
            set: { value in
                guard let index = rules.firstIndex(where: { $0.id == id }) else { return }
                rules[index][keyPath: keyPath] = value
            })
    }
}

/// Перетаскивание: строка встаёт на место той, над которой оказалась, сразу
/// при наведении — сам бросок только завершает жест.
private struct RuleDropDelegate: DropDelegate {
    let target: UUID
    let rules: Binding<[ReplacementRule]>
    @Binding var dragging: UUID?

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target,
              let from = rules.wrappedValue.firstIndex(where: { $0.id == dragging }),
              let to = rules.wrappedValue.firstIndex(where: { $0.id == target }) else { return }
        withAnimation(DS.Anim.section) {
            rules.wrappedValue.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

// MARK: - Строка правила

/// Намеренно тихая строка: ручка (при наведении), кружок вкл/выкл, «что → на
/// что» обычным текстом и «⋯» с остальными действиями, которая проявляется
/// при наведении. Прошлый вариант (по карточке на правило, тумблер, поля в
/// рамках, чип и корзина разных размеров) пользователь счёл перегруженным.
private struct RuleRow: View {
    let id: UUID
    let isEnabled: Bool
    let matchesInsideWords: Bool
    let formsApplicable: Bool
    let canReorder: Bool
    let from: Binding<String>
    let to: Binding<String>
    let enabled: Binding<Bool>
    let insideWords: Binding<Bool>
    let wordForms: Binding<Bool>
    var focused: FocusState<RuleField?>.Binding
    let onDragStart: () -> NSItemProvider
    let onDelete: () -> Void

    @State private var hovering = false
    /// Меню уже создано (строка хоть раз была активной).
    @State private var menuMounted = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Строка «активна»: под курсором или в ней идёт правка — тогда
    /// проявляются ручка, подложки полей и «⋯».
    private var isActive: Bool {
        hovering || focused.wrappedValue?.ruleID == id
    }

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 0) {
                dragHandle
                enabledToggle
            }
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
            // Меню создаётся при первой активности строки и дальше живёт с ней:
            // у каждой строки своё NSMenu, а нужны они единицам. Не убирать по
            // уходу курсора — меню исчезло бы прямо под открытым списком.
            // До того — пустое место той же ширины, чтобы поля не прыгали.
            if menuMounted {
                actionsMenu
                    .opacity(isActive ? 1 : 0)
            } else {
                Color.clear.frame(width: 28, height: 28)
            }
        }
        .frame(height: 36)
        // Ручка живёт в левом поле строки: кружок сдвинут на её ширину.
        .padding(.leading, 2)
        .padding(.trailing, DS.Spacing.cardPadding - 4)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onChange(of: isActive, initial: true) { _, active in
            if active { menuMounted = true }
        }
        .animation(reduceMotion ? nil : DS.Anim.hover, value: isActive)
        .animation(reduceMotion ? nil : DS.Anim.control, value: isEnabled)
    }

    /// Ручка перетаскивания: видна при наведении; в выборке поиска её нет.
    private var dragHandle: some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.tertiary)
            .frame(width: 16, height: 26)
            .contentShape(Rectangle())
            .opacity(canReorder && isActive ? 1 : 0)
            .allowsHitTesting(canReorder)
            .onDrag(onDragStart)
            .help(L("dictionary.reorder"))
            .accessibilityHidden(true)
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

    /// Всё редкое — в одном меню: формы слова, режим «внутри слов» и удаление.
    private var actionsMenu: some View {
        Menu {
            Toggle(L("dictionary.wordForms"), isOn: wordForms)
                .disabled(!formsApplicable || insideWords.wrappedValue)
                .help(L("dictionary.wordForms.help"))
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
