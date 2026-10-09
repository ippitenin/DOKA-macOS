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
/// со строками, растворение у кромок карточки, прокрутка к полю в фокусе и
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

    /// Зазор между шапкой страницы и карточкой правил.
    static let cardSpacing: CGFloat = 20
    /// Высота растворения строк у кромки карточки, за которой есть ещё строки.
    private static let edgeFade: CGFloat = 16

    /// Правило, которое сейчас тащат.
    @State private var dragging: UUID?
    /// Высота всех строк: короткий список карточка облегает.
    @State private var contentHeight: CGFloat = 0
    /// Есть ли строки за верхней и нижней кромкой видимой области.
    @State private var overflow = EdgeOverflow()
    /// Лента прокручивается: строки, проезжающие под курсором, не
    /// подсвечиваются — анимация наведения на каждой из них удваивала
    /// процессор на прокрутке.
    @State private var isScrolling = false

    private struct EdgeOverflow: Equatable {
        var top = false
        var bottom = false
    }

    private var visibleRules: [ReplacementRule] {
        let query = LibrarySearch.normalize(filter.trimmingCharacters(in: .whitespaces))
        guard !query.isEmpty else { return rules }
        return rules.filter {
            LibrarySearch.normalize($0.from).contains(query) || LibrarySearch.normalize($0.to).contains(query)
        }
    }

    var body: some View {
        let canReorder = filter.trimmingCharacters(in: .whitespaces).isEmpty
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    // ЛЕНИВО, как лента «Истории»: обычный VStack держал все 352
                    // строки системного словаря (≈ 2800 NSView), и фон окна
                    // (`MeshBackground`, 20 кадров/с) раскладывал их на каждом кадре.
                    LazyVStack(spacing: 0) {
                        // По значению, а не `ForEach($rules)`: привязки по ИНДЕКСУ
                        // роняли приложение при удалении — поле, которое ещё
                        // редактировалось, по окончании правки читало текст по уже
                        // несуществующему индексу (выход за границы массива).
                        ForEach(Array(visibleRules.enumerated()), id: \.element.id) { index, rule in
                            if index > 0 { CardDivider() }
                            RuleRow(
                                id: rule.id,
                                fromText: rule.from,
                                toText: rule.to,
                                isEnabled: rule.enabled,
                                matchesInsideWords: rule.matchInsideWords,
                                formsApplicable: Self.formsApplicable(rule),
                                canReorder: canReorder,
                                isScrolling: isScrolling,
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
                }
                .scrollContentBackground(.hidden)
                // Как у «Истории»: overlay-скроллер ездил бы поверх строк.
                .scrollIndicators(.never)
                .onScrollGeometryChange(for: CGFloat.self) { $0.contentSize.height } action: { _, height in
                    contentHeight = height
                }
                .onScrollPhaseChange { _, phase in
                    isScrolling = phase.isScrolling
                }
                .mask { edgeMask }
                .onChange(of: focused.wrappedValue) { _, field in
                    guard let id = field?.ruleID else { return }
                    withAnimation(DS.Anim.section) { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
            // Карточка — размером с ВИДИМУЮ область, строки ездят внутри неё.
            // Материал на весь `LazyVStack` (352 строки ≈ 15 000 pt) давал рывок
            // ~80 мс на прокрутке и +65 мс к открытию страницы (замер 9.10.2026).
            // Материал, а не Liquid Glass: высокая стеклянная карточка отражает
            // у кромок сайдбар и соседние контролы (см. «Общие»).
            .frame(maxHeight: contentHeight > 0 ? contentHeight : nil)
            .glassSurface(forceMaterial: true)
            Spacer(minLength: 0)
        }
        .padding(.bottom, 20)
    }

    /// Строки растворяются у той кромки карточки, за которой есть ещё строки;
    /// в покое (лента в самом верху) первая строка не тронута.
    private var edgeMask: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                .frame(height: overflow.top ? Self.edgeFade : 0)
            Color.black
            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: overflow.bottom ? Self.edgeFade : 0)
        }
        .animation(DS.Anim.hover, value: overflow)
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
    /// Тексты правила для показа в покое — без поиска по массиву правил,
    /// которым читают привязки.
    let fromText: String
    let toText: String
    let isEnabled: Bool
    let matchesInsideWords: Bool
    let formsApplicable: Bool
    let canReorder: Bool
    let isScrolling: Bool
    let from: Binding<String>
    let to: Binding<String>
    let enabled: Binding<Bool>
    let insideWords: Binding<Bool>
    let wordForms: Binding<Bool>
    var focused: FocusState<RuleField?>.Binding
    let onDragStart: () -> NSItemProvider
    let onDelete: () -> Void

    @State private var hovering = false
    /// Поля ввода и меню «⋯» уже созданы. До того строка рисует их чистым
    /// SwiftUI-текстом: каждое поле — настоящий `NSTextField`, у меню — свой
    /// NSView, и при прокрутке под неподвижным курсором строки создавали бы
    /// их одна за другой (на ленте системного словаря −⅓ процессора без них).
    /// Созданные живут со строкой: меню исчезло бы прямо под открытым списком.
    @State private var controlsMounted = false
    /// Поле, по которому кликнули до появления полей: фокус — в него.
    @State private var pendingFocus: RuleField?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Задержка курсора на строке, после которой создаются поля и меню:
    /// строки, проезжающие под курсором при прокрутке, её не набирают.
    private static let hoverIntent: Duration = .milliseconds(150)

    /// Строка «активна»: под курсором (и лента стоит) или в ней идёт
    /// правка — тогда проявляются ручка, подложки полей и «⋯».
    private var isActive: Bool {
        (hovering && !isScrolling) || focused.wrappedValue?.ruleID == id
    }

    /// Курсор задержался на строке, а не проезжает по ней с лентой.
    private var isHovered: Bool { hovering && !isScrolling }

    /// Поля и меню нужны: курсор задержался, в строке фокус или правило
    /// только что добавлено (пустой шаблон — курсор ставится сразу).
    private var showsControls: Bool {
        controlsMounted || focused.wrappedValue?.ruleID == id || fromText.isEmpty
    }

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 0) {
                dragHandle
                enabledToggle
            }
            Group {
                field(L("dictionary.from"), text: from, shown: fromText, key: .from(id))
                Image(systemName: "arrow.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                HStack(spacing: 8) {
                    field(L("dictionary.to"), text: to, shown: toText, key: .to(id))
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
            // До появления меню — пустое место той же ширины, чтобы поля не прыгали.
            if showsControls {
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
        .task(id: isHovered) {
            guard isHovered, !controlsMounted else { return }
            try? await Task.sleep(for: Self.hoverIntent)
            if isHovered, !Task.isCancelled { controlsMounted = true }
        }
        .animation(reduceMotion ? nil : DS.Anim.hover, value: isActive)
        .animation(reduceMotion ? nil : DS.Anim.control, value: isEnabled)
    }

    /// Поле правила: настоящее поле ввода, когда строка готова к правке,
    /// иначе — текст той же метрики (глиф ложится в тот же пиксель).
    @ViewBuilder
    private func field(_ placeholder: String, text: Binding<String>, shown: String,
                       key: RuleField) -> some View {
        if showsControls {
            RuleTextField(placeholder: placeholder, text: text,
                          isFocused: focused.wrappedValue == key, showsBox: isActive)
                .focused(focused, equals: key)
                .onAppear {
                    guard pendingFocus == key else { return }
                    // Следующим циклом: поле должно успеть попасть в окно.
                    DispatchQueue.main.async {
                        focused.wrappedValue = key
                        pendingFocus = nil
                    }
                }
        } else {
            RuleTextLabel(placeholder: placeholder, text: shown, showsBox: isActive)
                .onTapGesture {
                    pendingFocus = key
                    controlsMounted = true
                }
        }
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
            .ruleFieldBox(isFocused: isFocused, showsBox: showsBox)
    }
}

/// Поле правила до первой правки: тот же текст и та же подложка, что у
/// `RuleTextField`, но без `NSTextField` под ним.
private struct RuleTextLabel: View {
    let placeholder: String
    let text: String
    let showsBox: Bool

    var body: some View {
        Text(text.isEmpty ? placeholder : text)
            .foregroundStyle(text.isEmpty ? AnyShapeStyle(Color(nsColor: .placeholderTextColor))
                                          : AnyShapeStyle(.primary))
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .ruleFieldBox(isFocused: false, showsBox: showsBox)
            .contentShape(Rectangle())
            .accessibilityAddTraits(.isButton)
    }
}

private extension View {
    /// Метрика и подложка поля правила — общие у поля ввода и его текста.
    func ruleFieldBox(isFocused: Bool, showsBox: Bool) -> some View {
        padding(.horizontal, 8)
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
