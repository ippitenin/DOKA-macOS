import SwiftUI

/// Редактор шаблонов анализа: слева список (встроенные только для чтения,
/// свои — правятся), справа разделы. Модальный `.sheet`, а не окно: нужен
/// фокус клавиатуры в полях ввода — тот же прецедент, что у теста скорости
/// печати.
struct AnalysisTemplatesSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var settings = SettingsStore.shared

    /// Черновик правится «на месте», в стор уезжает по «Сохранить».
    @State private var selectedID: String?
    @State private var draft: AnalysisTemplate?
    @State private var deleting: AnalysisTemplate?

    private var builtins: [AnalysisTemplate] { BuiltinAnalysisTemplate.all }

    /// Свои шаблоны плюс несохранённый черновик: новый шаблон и копия живут
    /// только в черновике и попадают в настройки по «Сохранить». Иначе
    /// «Новый шаблон» → «Отмена» навсегда оставлял бы в списке пустышку.
    private var mine: [AnalysisTemplate] {
        var items = settings.analysisTemplates
        if let draft, !draft.isBuiltin, !items.contains(where: { $0.id == draft.id }) {
            items.append(draft)
        }
        return items
    }

    private var selected: AnalysisTemplate? {
        draft ?? (builtins + mine).first { $0.id == selectedID }
    }

    var body: some View {
        ZStack {
            AppBackground()
            VStack(spacing: 0) {
                header
                HStack(alignment: .top, spacing: 16) {
                    list
                    editor
                }
                .padding(.horizontal, 24)
                // Вместе с нижним отступом шапки (4) — ровно `topFade`: лента
                // редактора заходит в этот зазор своей верхней маской.
                .padding(.top, Self.topFade - 4)
                footer
            }
        }
        // Ниже окна (640): шит встаёт по центру с воздухом, лента редактора
        // и список прокручиваются сами.
        .frame(minWidth: 780, idealWidth: 840, minHeight: 460, idealHeight: 520)
        .onAppear {
            if selectedID == nil { selectedID = mine.first?.id ?? builtins.first?.id }
        }
        .alert(L("analysis.templates.deleteTitle"), isPresented: deletePresented, presenting: deleting) { item in
            Button(L("analysis.templates.delete"), role: .destructive) { delete(item) }
            Button(L("common.cancel"), role: .cancel) {}
        } message: { _ in
            Text(L("analysis.templates.deleteConfirm"))
        }
    }

    /// Высота зон растворения карточек у верхней и нижней кромок редактора.
    private static let topFade: CGFloat = 20
    private static let bottomFade: CGFloat = 36

    private var deletePresented: Binding<Bool> {
        Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
    }

    // MARK: - Шапка

    /// Как у «Распознать заново»: крупный заголовок, пояснение и крестик.
    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L("analysis.templates.title"))
                    .font(.title2.bold())
                Text(L("analysis.templates.subtitle"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help(L("common.close"))
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 4)
    }

    // MARK: - Список

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    group(L("analysis.templates.builtin"), builtins, locked: true)
                    if !mine.isEmpty {
                        group(L("analysis.templates.mine"), mine, locked: false)
                    }
                }
                .padding(8)
            }
            .scrollIndicators(.never)
            Button {
                addTemplate()
            } label: {
                Label(L("analysis.templates.new"), systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .dsGlassButton()
            .focusEffectDisabled()
            .padding(10)
        }
        .frame(width: 230)
        .frame(maxHeight: .infinity)
        .glassSurface()
    }

    private func group(_ title: String, _ items: [AnalysisTemplate], locked: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 11)
                .padding(.top, 4)
                .padding(.bottom, 2)
            ForEach(items) { template in
                TemplateRow(template: template, locked: locked,
                            isSelected: selected?.id == template.id) {
                    select(template)
                }
            }
        }
    }

    // MARK: - Редактор

    @ViewBuilder
    private var editor: some View {
        if let template = selected {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if template.isBuiltin {
                        readonlyNotice
                    }
                    SettingsCard(header: L("analysis.templates.basics")) {
                        VStack(alignment: .leading, spacing: 12) {
                            field(L("analysis.templates.name"), text: binding(\.name),
                                  locked: template.isBuiltin)
                            field(L("analysis.templates.description"), text: binding(\.description),
                                  locked: template.isBuiltin)
                        }
                        .padding(DS.Spacing.cardPadding)
                    }
                    ForEach(Array(template.sections.enumerated()), id: \.element.id) { index, section in
                        sectionCard(section, at: index, count: template.sections.count,
                                    locked: template.isBuiltin)
                    }
                    if !template.isBuiltin {
                        Button {
                            mutate { $0.sections.append(AnalysisSection(title: "", instruction: "")) }
                        } label: {
                            Label(L("analysis.templates.addSection"), systemImage: "plus")
                        }
                        .dsGlassButton()
                        .disabled(template.sections.count >= AnalysisTemplate.maxSections)
                    }
                }
                // Отступы равны высоте фейдов: в покое первая карточка и в конце
                // прокрутки последняя выходят из-под маски целиком.
                .padding(.top, Self.topFade)
                .padding(.bottom, Self.bottomFade)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.never)
            // Карточки у обеих кромок растворяются, а не срезаются — тот же
            // приём, что у ленты «Истории» (`HistorySectionView.topFade`).
            .mask {
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: Self.topFade)
                    Color.black
                    LinearGradient(colors: [.black, .clear],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: Self.bottomFade)
                }
            }
            // Лента заходит вверх в зазор под шапкой (маска — ДО отступа, чтобы
            // лечь на полную рамку): в покое первая карточка — вровень со списком.
            .padding(.top, -Self.topFade)
        } else {
            Text(L("analysis.templates.empty"))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Встроенный шаблон: вместо россыпи серых заблокированных полей —
    /// одна плашка «только просмотр» с подсказкой, как его изменить.
    private var readonlyNotice: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.fill")
                .foregroundStyle(DS.accent)
            Text(L("analysis.templates.builtinReadonly"))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Spacing.cardPadding)
        .padding(.vertical, 12)
        // Лёгкий тон, а не полный акцент: Liquid Glass с непрозрачным тоном
        // заливал плашку сплошным кораллом, и замок цвета акцента пропадал.
        .glassSurface(tint: DS.accent.opacity(0.25))
    }

    /// Поле ввода; у встроенного шаблона — просто текст.
    @ViewBuilder
    private func field(_ title: String, text: Binding<String>, locked: Bool,
                       prompt: String = "", multiline: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if !title.isEmpty {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if locked {
                Text(text.wrappedValue.isEmpty ? "—" : text.wrappedValue)
                    .foregroundStyle(text.wrappedValue.isEmpty ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if multiline {
                TextField(prompt, text: text, axis: .vertical)
                    .lineLimit(2...6)
                    .dsFieldBox()
            } else {
                TextField(prompt, text: text)
                    .dsFieldBox()
            }
        }
    }

    private func sectionCard(_ section: AnalysisSection, at index: Int, count: Int,
                             locked: Bool) -> some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 6) {
                    Text(L("analysis.templates.sectionN", index + 1))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    if !locked {
                        iconButton("chevron.up", disabled: index == 0) { move(index, by: -1) }
                        iconButton("chevron.down", disabled: index == count - 1) { move(index, by: 1) }
                        iconButton("trash", disabled: false) {
                            mutate { $0.sections.remove(at: index) }
                        }
                    }
                }
                if locked {
                    Text(section.title)
                        .font(.body.weight(.semibold))
                    Text(section.instruction)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        chip(section.format.title)
                        if section.format == .table, !section.columns.isEmpty {
                            chip(section.columns.joined(separator: " · "))
                        }
                        if section.cite { chip(L("analysis.templates.cite")) }
                    }
                } else {
                    field("", text: sectionBinding(index, \.title), locked: false,
                          prompt: L("analysis.templates.sectionTitle"))
                    field("", text: sectionBinding(index, \.instruction), locked: false,
                          prompt: L("analysis.templates.sectionInstruction"), multiline: true)
                    HStack(spacing: 10) {
                        Text(L("analysis.templates.sectionFormat"))
                            .foregroundStyle(.secondary)
                        SettingsPopup(titles: AnalysisSectionFormat.allCases.map(\.title),
                                      selectionIndex: Binding(
                                        get: { AnalysisSectionFormat.allCases.firstIndex(of: section.format) ?? 0 },
                                        set: { value in
                                            mutate { $0.sections[index].format = AnalysisSectionFormat.allCases[value] }
                                        }),
                                      width: 140)
                        Spacer(minLength: 12)
                        Text(L("analysis.templates.cite"))
                        SettingsSwitch(isOn: sectionBinding(index, \.cite))
                    }
                    if section.format == .table {
                        field("", text: Binding(
                            get: { section.columns.joined(separator: ", ") },
                            set: { value in
                                mutate {
                                    $0.sections[index].columns = value
                                        .components(separatedBy: ",")
                                        .map { $0.trimmingCharacters(in: .whitespaces) }
                                        .filter { !$0.isEmpty }
                                }
                            }), locked: false, prompt: L("analysis.templates.columns"))
                    }
                }
            }
            .padding(DS.Spacing.cardPadding)
        }
    }

    private func iconButton(_ symbol: String, disabled: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.callout)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .focusEffectDisabled()
        .disabled(disabled)
        .opacity(disabled ? 0.35 : 1)
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(DS.accent)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule(style: .continuous).fill(DS.accent.opacity(0.14)))
    }

    // MARK: - Низ

    private var footer: some View {
        HStack(spacing: 10) {
            if let template = selected {
                Button(L("analysis.templates.duplicate")) {
                    let copy = template.duplicated()
                    draft = copy
                    selectedID = copy.id
                }
                .dsGlassButton()
                if !template.isBuiltin {
                    Button(L("analysis.templates.delete"), role: .destructive) { deleting = template }
                        .dsGlassButton()
                }
            }
            if let error = draft?.validationError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(DS.RecorderTone.error)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Button(L("common.cancel")) { dismiss() }
                .dsGlassButton()
                .keyboardShortcut(.cancelAction)
            Button(L("common.save")) { save() }
                .dsProminentButton()
                .disabled(draft == nil || draft?.validationError != nil)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    // MARK: - Правка черновика

    private func select(_ template: AnalysisTemplate) {
        // Незаконченная правка не переносится на другой шаблон.
        draft = nil
        selectedID = template.id
    }

    private func addTemplate() {
        let new = AnalysisTemplate(name: L("analysis.templates.newName"),
                                   sections: [AnalysisSection(title: L("analysis.templates.sectionTitle"),
                                                              instruction: "")])
        draft = new
        selectedID = new.id
    }

    private func delete(_ template: AnalysisTemplate) {
        settings.analysisTemplates.removeAll { $0.id == template.id }
        if settings.analysisTemplateID == template.id {
            settings.analysisTemplateID = BuiltinAnalysisTemplate.summary.templateID
        }
        draft = nil
        selectedID = mine.first?.id ?? builtins.first?.id
    }

    private func save() {
        guard let draft, draft.validationError == nil else { return }
        if let index = settings.analysisTemplates.firstIndex(where: { $0.id == draft.id }) {
            settings.analysisTemplates[index] = draft
        } else {
            settings.analysisTemplates.append(draft)
        }
        self.draft = nil
        selectedID = draft.id
    }

    private func move(_ index: Int, by offset: Int) {
        mutate { template in
            let target = index + offset
            guard template.sections.indices.contains(index),
                  template.sections.indices.contains(target) else { return }
            template.sections.swapAt(index, target)
        }
    }

    /// Любая правка сначала поднимает шаблон в черновик: встроенный при этом
    /// не трогаем — у него все поля заблокированы.
    private func mutate(_ change: (inout AnalysisTemplate) -> Void) {
        guard var current = selected, !current.isBuiltin else { return }
        change(&current)
        draft = current
    }

    private func binding(_ keyPath: WritableKeyPath<AnalysisTemplate, String>) -> Binding<String> {
        Binding(get: { selected?[keyPath: keyPath] ?? "" },
                set: { value in mutate { $0[keyPath: keyPath] = value } })
    }

    private func sectionBinding<Value>(_ index: Int,
                                       _ keyPath: WritableKeyPath<AnalysisSection, Value>) -> Binding<Value> {
        Binding(
            get: {
                guard let sections = selected?.sections, sections.indices.contains(index) else {
                    // Раздел успели удалить — отдаём значение по умолчанию,
                    // вью всё равно перерисуется без этой строки.
                    return AnalysisSection(title: "", instruction: "")[keyPath: keyPath]
                }
                return sections[index][keyPath: keyPath]
            },
            set: { value in
                mutate {
                    guard $0.sections.indices.contains(index) else { return }
                    $0.sections[index][keyPath: keyPath] = value
                }
            })
    }
}

/// Строка списка шаблонов — в стиле пунктов сайдбара: капсула, выбранная —
/// коралловая пилюля с белым текстом, наведение — лёгкая подложка.
/// `.focusEffectDisabled()` обязателен: иначе при полном доступе с клавиатуры
/// первая строка открывалась с синим системным кольцом фокуса.
private struct TemplateRow: View {
    let template: AnalysisTemplate
    let locked: Bool
    let isSelected: Bool
    let action: () -> Void

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(template.name)
                    .lineLimit(1)
                    .foregroundStyle(isSelected ? Color.white : .primary)
                Spacer(minLength: 4)
                if locked {
                    Image(systemName: "lock")
                        .font(.caption2)
                        .foregroundStyle(isSelected ? AnyShapeStyle(Color.white.opacity(0.8))
                                                    : AnyShapeStyle(.tertiary))
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .background {
            if isSelected {
                Capsule(style: .continuous)
                    .fill(LinearGradient(colors: [DS.accent, DS.accent.opacity(0.82)],
                                         startPoint: .top, endPoint: .bottom))
                    .shadow(color: DS.accent.opacity(0.35), radius: 6, y: 2)
            } else if hovering {
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(0.07))
            }
        }
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : DS.Anim.hover, value: hovering)
    }
}
