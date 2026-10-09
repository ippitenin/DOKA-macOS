import SwiftUI

/// Страница системного словаря (вход — карточка в «Словаре»): поиск по
/// правилам, правка, выключение, удаление, перетаскивание и «Вернуть
/// исходный словарь». Правится рабочая копия пользователя
/// (`SettingsStore.systemReplacements`), встроенный список не меняется.
struct SystemDictionaryView: View {
    @ObservedObject var settings = SettingsStore.shared
    let onBack: () -> Void

    @FocusState private var focused: RuleField?
    @State private var search = ""
    @State private var confirmReset = false

    var body: some View {
        VStack(alignment: .leading, spacing: ReplacementRulesList.topFade) {
            VStack(alignment: .leading, spacing: 12) {
                backButton
                header
                searchRow
            }
            if noMatches {
                notFound
            } else {
                ReplacementRulesList(rules: $settings.systemReplacements, filter: search,
                                     focused: $focused, onDelete: delete)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 46)
        .contentShape(Rectangle())
        .onTapGesture { endEditing() }
        .alert(L("systemDictionary.reset.title"), isPresented: $confirmReset) {
            Button(L("systemDictionary.reset.confirm"), role: .destructive) {
                endEditing()
                withAnimation(DS.Anim.section) { settings.resetSystemDictionary() }
            }
            Button(L("common.cancel"), role: .cancel) {}
        } message: {
            Text(L("systemDictionary.reset.message"))
        }
    }

    private var backButton: some View {
        Button(action: onBack) {
            HStack(spacing: 5) {
                Image(systemName: "chevron.left")
                    .font(.footnote.weight(.semibold))
                Text(L("systemDictionary.back"))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(DS.accent)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(L("systemDictionary.title"))
                .font(.title.bold())
            HelpBubble(text: L("systemDictionary.subtitle"))
            Spacer(minLength: 12)
            Menu {
                Button(L("systemDictionary.reset"), role: .destructive) { confirmReset = true }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 17))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(L("dictionary.more"))
            .accessibilityLabel(L("dictionary.more"))
            Button {
                addRule()
            } label: {
                Label(L("dictionary.add"), systemImage: "plus")
            }
            .dsProminentButton()
        }
    }

    /// Поиск как в «Истории»: капсула с лупой.
    private var searchRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(L("systemDictionary.search"), text: $search)
                .textFieldStyle(.plain)
            if !search.isEmpty {
                Button {
                    search = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("systemDictionary.search.clear"))
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .glassCapsule()
    }

    private var noMatches: Bool {
        let query = LibrarySearch.normalize(search.trimmingCharacters(in: .whitespaces))
        guard !query.isEmpty else { return settings.systemReplacements.isEmpty }
        return !settings.systemReplacements.contains {
            LibrarySearch.normalize($0.from).contains(query) || LibrarySearch.normalize($0.to).contains(query)
        }
    }

    private var notFound: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
                .dsBreathe()
            Text(L("systemDictionary.notFound"))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    // MARK: - Действия

    /// Новое правило — в начало списка (он длинный, в конце его не видно);
    /// поиск сбрасывается, иначе пустая строка в выборку не попала бы.
    private func addRule() {
        search = ""
        let rule = ReplacementRule(from: "", to: "")
        settings.systemReplacements.insert(rule, at: 0)
        DispatchQueue.main.async { focused = .from(rule.id) }
    }

    private func endEditing() {
        guard focused != nil else { return }
        focused = nil
        NSApp.keyWindow?.makeFirstResponder(nil)
    }

    /// Как у личного словаря: сначала снять фокус, удалить — следующим циклом.
    private func delete(_ id: UUID) {
        focused = nil
        NSApp.keyWindow?.makeFirstResponder(nil)
        DispatchQueue.main.async {
            withAnimation(DS.Anim.section) { settings.removeSystemRule(id: id) }
        }
    }
}
