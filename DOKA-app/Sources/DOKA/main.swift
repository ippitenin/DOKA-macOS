import AppKit

// Аппаратный кодировщик видео «Губ» — только в приложении: тесты этот файл
// не исполняют и кодируют программно (`LipVideoEncoding`).
LipVideoEncoding.hardwareAllowed = true

// Top-level код не изолирован на MainActor, но приложение стартует на главном потоке.
MainActor.assumeIsolated {
    LegacyMigration.run()
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    // По умолчанию — только меню-бар; тоггл «Показывать иконку в Dock»
    // («Расширенные» настройки) переводит в .regular и на старте, и на лету.
    app.setActivationPolicy(SettingsStore.shared.showDockIcon ? .regular : .accessory)
    app.run()
}
