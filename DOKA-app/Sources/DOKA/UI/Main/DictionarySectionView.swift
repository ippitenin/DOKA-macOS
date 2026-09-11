import SwiftUI

/// Секция «Словарь»: правила замен в распознанном тексте.
struct DictionarySectionView: View {
    @ObservedObject var settings = SettingsStore.shared
    @State private var selection: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(
                title: L("section.dictionary"),
                subtitle: L("dictionary.subtitle")
            )

            SectionCard {
                if settings.replacements.isEmpty {
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
                } else {
                    List(selection: $selection) {
                        ForEach($settings.replacements) { $rule in
                            HStack(spacing: 8) {
                                Toggle("", isOn: $rule.enabled)
                                    .labelsHidden()
                                TextField(L("dictionary.from"), text: $rule.from)
                                Image(systemName: "arrow.right")
                                    .foregroundStyle(.secondary)
                                TextField(L("dictionary.to"), text: $rule.to)
                                // По умолчанию правило — на целое слово; кнопка
                                // включает прежний поиск подстроки («ё» → «е»).
                                Toggle(isOn: $rule.matchInsideWords) {
                                    Image(systemName: "character.textbox")
                                }
                                .toggleStyle(.button)
                                .accessibilityLabel(L("dictionary.insideWords"))
                                .help(L("dictionary.insideWords.help"))
                            }
                            .tag(rule.id)
                            .listRowBackground(Color.clear)
                        }
                    }
                    .listStyle(.inset)
                    .scrollContentBackground(.hidden)
                    .alternatingRowBackgrounds(.disabled)
                }
            }

            HStack(spacing: 2) {
                Button {
                    settings.replacements.append(ReplacementRule(from: "", to: ""))
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Divider().frame(height: 14)

                Button {
                    if let selected = selection {
                        settings.replacements.removeAll { $0.id == selected }
                        selection = nil
                    }
                } label: {
                    Image(systemName: "minus")
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(selection == nil)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .glassCapsule()
        }
        .padding(.horizontal, 24)
        .padding(.top, 46)
        .padding(.bottom, 20)
    }
}
