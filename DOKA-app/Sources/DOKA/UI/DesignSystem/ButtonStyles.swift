import SwiftUI

extension View {
    /// Непрерывное «дыхание» SF Symbol внутри вью (`.breathe` доступен с
    /// macOS 15 — минимальной версии приложения).
    func dsBreathe() -> some View {
        symbolEffect(.breathe)
    }
}

extension View {
    /// Главная кнопка: Liquid Glass на macOS 26, системная prominent ниже.
    /// Форма — капсула («таблетки» Tahoe), тон — фирменный оранжевый.
    @ViewBuilder
    func dsProminentButton() -> some View {
        if #available(macOS 26.0, *) {
            buttonStyle(.glassProminent).buttonBorderShape(.capsule).tint(DS.accent)
        } else {
            buttonStyle(.borderedProminent).buttonBorderShape(.capsule).tint(DS.accent)
        }
    }

    /// Вторичная кнопка: прозрачное стекло на macOS 26, bordered ниже.
    /// Форма — капсула («таблетки» Tahoe).
    @ViewBuilder
    func dsGlassButton() -> some View {
        if #available(macOS 26.0, *) {
            buttonStyle(.glass).buttonBorderShape(.capsule)
        } else {
            buttonStyle(.bordered).buttonBorderShape(.capsule)
        }
    }
}
