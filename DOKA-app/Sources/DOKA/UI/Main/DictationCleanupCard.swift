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
    @FocusState private var focusedRule: Int?

    var body: some View {
        SettingsCard {
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
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                sectionTitle(L("cleanup.presets.title"))
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
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    sectionTitle(L("cleanup.rules.title"))
                    Spacer(minLength: 8)
                    Text(L("cleanup.rules.count", settings.cleanupRules.count, DictationCleanup.maxRules))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
                ForEach(Array(settings.cleanupRules.enumerated()), id: \.offset) { index, _ in
                    ruleRow(index)
                }
                if settings.cleanupRules.count < DictationCleanup.maxRules {
                    draftRow
                }
            }
        }
        .padding(.horizontal, DS.Spacing.cardPadding)
        .padding(.vertical, 12)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    /// Сохранённое пожелание: поле во всю ширину, длинное переносится на
    /// следующие строки. Однострочное поле без ограничения ширины растягивало
    /// весь блок шире карточки, и подсказка ввода обрезалась слева.
    private func ruleRow(_ index: Int) -> some View {
        HStack(alignment: .top, spacing: 8) {
            TextField("", text: ruleBinding(index), axis: .vertical)
                .textFieldStyle(.plain)
                .font(.callout)
                .lineLimit(1...4)
                .focused($focusedRule, equals: index)
                .dsFieldBox(isFocused: focusedRule == index, showsBox: true, multiline: true)
            Button {
                removeRule(at: index)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
                    .frame(height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("cleanup.rule.delete"))
            .accessibilityLabel(L("cleanup.rule.delete"))
        }
    }

    /// Поле нового пожелания в рамке и кнопка «Добавить» из дизайн-системы.
    private var draftRow: some View {
        HStack(spacing: 8) {
            TextField(L("cleanup.rule.placeholder"), text: $draft)
                .textFieldStyle(.plain)
                .font(.callout)
                .lineLimit(1)
                .focused($draftFocused)
                .onSubmit(addRule)
                .dsFieldBox(isFocused: draftFocused, showsBox: true)
            Button(action: addRule) {
                Label(L("cleanup.rule.add"), systemImage: "plus")
            }
            .dsGlassButton()
            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    /// Привязка по индексу с проверкой границ: строку могли удалить, пока
    /// её поле ещё дописывало текст (та же ловушка, что у правил словаря).
    private func ruleBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: { settings.cleanupRules.indices.contains(index) ? settings.cleanupRules[index] : "" },
            set: { value in
                guard settings.cleanupRules.indices.contains(index) else { return }
                // Поле многострочное, но пожелание — одна фраза: Enter не рвёт её.
                let flat = value.replacingOccurrences(of: "\n", with: " ")
                settings.cleanupRules[index] = String(flat.prefix(DictationCleanup.maxRuleLength))
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
