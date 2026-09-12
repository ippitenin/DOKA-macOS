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
        VStack(spacing: 0) {
            HStack {
                Text(L("analysis.templates.title"))
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 10)
            HStack(spacing: 0) {
                list
                Divider()
                editor
            }
            Divider()
            footer
        }
        .frame(minWidth: 760, idealWidth: 820, minHeight: 520, idealHeight: 560)
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

    private var deletePresented: Binding<Bool> {
        Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
    }

    // MARK: - Список

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    group(L("analysis.templates.builtin"), builtins, locked: true)
                    if !mine.isEmpty {
                        group(L("analysis.templates.mine"), mine, locked: false)
                    }
                }
                .padding(.vertical, 8)
            }
            Divider()
            Button {
                addTemplate()
            } label: {
                Label(L("analysis.templates.new"), systemImage: "plus")
                    .font(.callout)
            }
            .buttonStyle(.plain)
            .foregroundStyle(DS.accent)
            .padding(10)
        }
        .frame(width: 240)
    }

    private func group(_ title: String, _ items: [AnalysisTemplate], locked: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.top, 8)
            ForEach(items) { template in
                row(template, locked: locked)
            }
        }
    }

    private func row(_ template: AnalysisTemplate, locked: Bool) -> some View {
        let isSelected = selected?.id == template.id
        return Button {
            select(template)
        } label: {
            HStack(spacing: 6) {
                Text(template.name)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if locked {
                    Image(systemName: "lock")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.badge, style: .continuous)
                    .fill(isSelected ? DS.accent.opacity(0.16) : .clear)
                    .padding(.horizontal, 8)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Редактор

    @ViewBuilder
    private var editor: some View {
        if let template = selected {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if template.isBuiltin {
                        Label(L("analysis.templates.builtinReadonly"), systemImage: "lock")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    field(L("analysis.templates.name"), text: binding(\.name), disabled: template.isBuiltin)
                    field(L("analysis.templates.description"), text: binding(\.description),
                          disabled: template.isBuiltin)

                    Text(L("analysis.templates.sections"))
                        .font(.headline)
                    ForEach(Array(template.sections.enumerated()), id: \.element.id) { index, section in
                        sectionEditor(section, at: index, locked: template.isBuiltin)
                    }
                    if !template.isBuiltin {
                        Button {
                            mutate { $0.sections.append(AnalysisSection(title: "", instruction: "")) }
                        } label: {
                            Label(L("analysis.templates.addSection"), systemImage: "plus")
                                .font(.callout)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(DS.accent)
                        .disabled(template.sections.count >= AnalysisTemplate.maxSections)
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            Text(L("analysis.templates.empty"))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func field(_ title: String, text: Binding<String>, disabled: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("", text: text)
                .textFieldStyle(.roundedBorder)
                .disabled(disabled)
        }
    }

    private func sectionEditor(_ section: AnalysisSection, at index: Int, locked: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField(L("analysis.templates.sectionTitle"),
                          text: sectionBinding(index, \.title))
                    .textFieldStyle(.roundedBorder)
                    .disabled(locked)
                if !locked {
                    Button { move(index, by: -1) } label: { Image(systemName: "chevron.up") }
                        .buttonStyle(.plain)
                        .disabled(index == 0)
                    Button { move(index, by: 1) } label: { Image(systemName: "chevron.down") }
                        .buttonStyle(.plain)
                        .disabled(index == (selected?.sections.count ?? 0) - 1)
                    Button { mutate { $0.sections.remove(at: index) } } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            TextField(L("analysis.templates.sectionInstruction"),
                      text: sectionBinding(index, \.instruction), axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .disabled(locked)
            HStack(spacing: 10) {
                Text(L("analysis.templates.sectionFormat"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                SettingsPopup(titles: AnalysisSectionFormat.allCases.map(\.title),
                              selectionIndex: Binding(
                                get: { AnalysisSectionFormat.allCases.firstIndex(of: section.format) ?? 0 },
                                set: { value in
                                    mutate { $0.sections[index].format = AnalysisSectionFormat.allCases[value] }
                                }),
                              width: 130)
                    .disabled(locked)
                Toggle(L("analysis.templates.cite"), isOn: sectionBinding(index, \.cite))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .disabled(locked)
                Spacer(minLength: 0)
            }
            if section.format == .table {
                TextField(L("analysis.templates.columns"),
                          text: Binding(
                            get: { section.columns.joined(separator: ", ") },
                            set: { value in
                                mutate {
                                    $0.sections[index].columns = value
                                        .components(separatedBy: ",")
                                        .map { $0.trimmingCharacters(in: .whitespaces) }
                                        .filter { !$0.isEmpty }
                                }
                            }))
                    .textFieldStyle(.roundedBorder)
                    .disabled(locked)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.badge, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
    }

    // MARK: - Низ

    private var footer: some View {
        HStack(spacing: 12) {
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
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Button(L("common.cancel")) { dismiss() }
                .dsGlassButton()
            Button(L("common.save")) { save() }
                .dsProminentButton()
                .disabled(draft == nil || draft?.validationError != nil)
                .keyboardShortcut(.defaultAction)
        }
        .padding(14)
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
