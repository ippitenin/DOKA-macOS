import SwiftUI

/// Карточка «ИИ-обработка» над правилами «Словаря»: тумблер, готовые
/// пожелания чипами и свои пожелания словами (по образцу Type 3.0).
/// Порядок в диктовке: сначала правка модели, потом правила словаря —
/// они главнее.
struct DictationCleanupCard: View {
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var models = LocalModelStore.shared
    @State private var draft = ""
    @FocusState private var draftFocused: Bool

    var body: some View {
        SettingsCard(forceMaterial: true) {
            SettingsRow(title: L("cleanup.toggle"), help: L("cleanup.toggle.help")) {
                SettingsSwitch(isOn: $settings.dictationCleanup)
            }
            if settings.dictationCleanup {
                if !models.isDownloaded(.llm) {
                    CardDivider()
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L("cleanup.modelNeeded"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        LocalAssetStatusView(asset: .llm, name: LLMModelSpec.current.displayName)
                    }
                    .padding(.horizontal, DS.Spacing.cardPadding)
                    .padding(.vertical, 10)
                } else if LLMModelSpec.isLowMemoryMac && settings.isLocalService {
                    CardDivider()
                    Text(L("cleanup.lowMemory"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, DS.Spacing.cardPadding)
                        .padding(.vertical, 9)
                }
                CardDivider()
                wishes
            }
        }
    }

    // MARK: - Пожелания

    private var wishes: some View {
        VStack(alignment: .leading, spacing: 10) {
            ChipFlowLayout(spacing: 6) {
                ForEach(DictationCleanup.Wish.allCases, id: \.self) { wish in
                    WishChip(title: wish.title, isOn: settings.cleanupWishes.contains(wish)) {
                        if settings.cleanupWishes.contains(wish) {
                            settings.cleanupWishes.remove(wish)
                        } else {
                            settings.cleanupWishes.insert(wish)
                        }
                    }
                }
            }
            ForEach(Array(settings.cleanupRules.enumerated()), id: \.offset) { index, _ in
                HStack(spacing: 8) {
                    TextField("", text: ruleBinding(index))
                        .textFieldStyle(.plain)
                        .font(.callout)
                    Button {
                        removeRule(at: index)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help(L("cleanup.rule.delete"))
                }
            }
            if settings.cleanupRules.count < DictationCleanup.maxRules {
                HStack(spacing: 8) {
                    TextField(L("cleanup.rule.placeholder"), text: $draft)
                        .textFieldStyle(.plain)
                        .font(.callout)
                        .focused($draftFocused)
                        .onSubmit(addRule)
                    Button(L("cleanup.rule.add"), action: addRule)
                        .buttonStyle(.plain)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(DS.accent)
                        .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .padding(.horizontal, DS.Spacing.cardPadding)
        .padding(.vertical, 10)
    }

    /// Привязка по индексу с проверкой границ: строку могли удалить, пока
    /// её поле ещё дописывало текст (та же ловушка, что у правил словаря).
    private func ruleBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: { settings.cleanupRules.indices.contains(index) ? settings.cleanupRules[index] : "" },
            set: { value in
                guard settings.cleanupRules.indices.contains(index) else { return }
                settings.cleanupRules[index] = String(value.prefix(DictationCleanup.maxRuleLength))
            }
        )
    }

    private func addRule() {
        let rule = String(draft.trimmingCharacters(in: .whitespacesAndNewlines).prefix(DictationCleanup.maxRuleLength))
        guard !rule.isEmpty, settings.cleanupRules.count < DictationCleanup.maxRules else { return }
        settings.cleanupRules.append(rule)
        draft = ""
        draftFocused = true
    }

    private func removeRule(at index: Int) {
        // Сначала снять фокус, удалить — следующим циклом (см. `ruleBinding`).
        NSApp.keyWindow?.makeFirstResponder(nil)
        DispatchQueue.main.async {
            guard settings.cleanupRules.indices.contains(index) else { return }
            settings.cleanupRules.remove(at: index)
        }
    }
}

/// Чип пожелания: включённый — с галочкой и акцентной кромкой.
private struct WishChip: View {
    let title: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if isOn {
                    Image(systemName: "checkmark")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(DS.accent)
                }
                Text(title)
                    .font(.caption.weight(.medium))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(isOn ? DS.accent.opacity(0.12) : Color.primary.opacity(0.05))
            )
            .overlay(
                Capsule().strokeBorder(isOn ? DS.accent.opacity(0.6) : Color.primary.opacity(0.12), lineWidth: 1)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}
