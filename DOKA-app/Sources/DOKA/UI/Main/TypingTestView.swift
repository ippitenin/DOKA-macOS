import SwiftUI

/// Модальный тест скорости печати (лист над главным окном). Показывается фраза,
/// пользователь печатает, измеряется скорость в словах/мин — та же единица, что
/// «скорость речи» на дашборде. Результат сохраняется в `SettingsStore` и
/// разблокирует геро-метрики дашборда (множитель и сэкономленное время).
struct TypingTestView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var settings = SettingsStore.shared
    @FocusState private var inputFocused: Bool

    private let phrases = TypingPhrases.forCurrentLocale()
    @State private var phraseIndex = 0
    @State private var typed = ""
    @State private var startedAt: Date? = nil
    @State private var resultWPM: Double? = nil

    private var phrase: String { phrases[min(phraseIndex, phrases.count - 1)] }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            phraseCard
        }
        .padding(24)
        .frame(width: 580, height: 440)
        .background(AppBackground().ignoresSafeArea())
        .onAppear { inputFocused = true }
        .task {
            // Подстраховка: при первом появлении листа фокус иногда не берётся сразу.
            try? await Task.sleep(for: .milliseconds(60))
            inputFocused = true
        }
        .onChange(of: typed) { handleTyping() }
        .onChange(of: phraseIndex) { resetTest() }
    }

    // MARK: - Заголовок с крестиком

    private var header: some View {
        HStack {
            Text(L("dashboard.test.title")).font(.title2.bold())
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 22))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            // Системное синее кольцо фокуса выбивается из дизайна: при полном
            // доступе с клавиатуры фокус вставал на крестик (в шитах — сразу при открытии).
            .focusEffectDisabled()
            .keyboardShortcut(.cancelAction)
            .help(L("common.done"))
        }
    }

    // MARK: - Карточка: фраза + нижняя панель (результат + пагинация)

    private var phraseCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(attributedPhrase)
                .font(.system(size: 18, weight: .medium, design: .monospaced))
                .lineSpacing(7)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            bottomBar
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassSurface()
        .overlay {
            // Невидимое поле — ловит клавиатуру; отключаем автокоррекцию.
            TextField("", text: $typed)
                .textFieldStyle(.plain)
                .autocorrectionDisabled(true)
                .focused($inputFocused)
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .disabled(resultWPM != nil)
        }
        .contentShape(Rectangle())
        .onTapGesture { inputFocused = true }
    }

    /// Посимвольная подсветка: совпало — основной цвет, ошибка — красный,
    /// текущая позиция — акцентная подложка, впереди — приглушённый.
    private var attributedPhrase: AttributedString {
        let phraseChars = Array(phrase)
        let typedChars = Array(typed)
        var result = AttributedString()
        for (i, ch) in phraseChars.enumerated() {
            var piece = AttributedString(String(ch))
            if i < typedChars.count {
                if typedChars[i] == ch {
                    piece.foregroundColor = .primary
                } else {
                    piece.foregroundColor = .red
                    piece.backgroundColor = .red.opacity(0.18)
                }
            } else if i == typedChars.count && resultWPM == nil {
                piece.foregroundColor = .primary
                piece.backgroundColor = DS.accent.opacity(0.30)
            } else {
                piece.foregroundColor = .secondary
            }
            result.append(piece)
        }
        return result
    }

    // MARK: - Нижняя панель

    private var bottomBar: some View {
        HStack(spacing: 12) {
            resultLabel
                .font(.footnote)
                .lineLimit(1)
            Spacer(minLength: 8)
            pagination
        }
        .padding(.top, 12)
    }

    @ViewBuilder
    private var resultLabel: some View {
        if let resultWPM {
            Label(L("dashboard.test.result", Int(resultWPM.rounded())), systemImage: "checkmark.circle.fill")
                .foregroundStyle(DS.accent)
        } else if settings.typingSpeedWPM > 0 {
            Text(L("dashboard.test.lastResult", Int(settings.typingSpeedWPM.rounded())))
                .foregroundStyle(.secondary)
        } else {
            Text(L("dashboard.test.prompt"))
                .foregroundStyle(.secondary)
        }
    }

    /// Пагинация: ‹ N из M › + перемешать (как в референсе).
    private var pagination: some View {
        HStack(spacing: 8) {
            pagerButton("chevron.left") { step(-1) }
            Text(L("dashboard.test.counter", phraseIndex + 1, phrases.count))
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 56)
            pagerButton("chevron.right") { step(1) }
            pagerButton("shuffle") { shufflePhrase() }
                .help(L("dashboard.test.shuffle"))
                .padding(.leading, 4)
        }
    }

    private func pagerButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Логика теста

    private func handleTyping() {
        if startedAt == nil, !typed.isEmpty {
            startedAt = Date()   // таймер стартует с первого символа
        }
        guard resultWPM == nil, let startedAt, typed.count >= phrase.count else { return }
        let elapsed = Date().timeIntervalSince(startedAt)
        guard elapsed > 0.2 else { return }
        let wpm = Double(phrase.dokaWordCount) / (elapsed / 60)
        resultWPM = wpm
        settings.typingSpeedWPM = wpm
        inputFocused = false
    }

    /// Шаг пагинации с цикличностью (‹/›).
    private func step(_ delta: Int) {
        let count = phrases.count
        guard count > 0 else { return }
        phraseIndex = ((phraseIndex + delta) % count + count) % count   // onChange → resetTest()
    }

    private func shufflePhrase() {
        guard phrases.count > 1 else { resetTest(); return }
        var next = phraseIndex
        while next == phraseIndex { next = Int.random(in: phrases.indices) }
        phraseIndex = next   // onChange(of: phraseIndex) → resetTest()
    }

    private func resetTest() {
        typed = ""
        startedAt = nil
        resultWPM = nil
        inputFocused = true
    }
}
