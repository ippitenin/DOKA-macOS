import SwiftUI

/// Секции главного окна (сайдбар).
enum MainSection: String, CaseIterable, Identifiable {
    case home        // экран DOKA: онбординг / готовность к диктовке
    case dashboard   // «Дашборд»: статистика диктовки
    case general
    case sound       // микрофон и звуковые эффекты
    case hotkeys
    case dictionary
    case service
    case history
    case transcribe  // транскрибация загруженного аудио/видеофайла
    case library     // библиотека транскрибаций файлов: поиск, запись, плеер

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return L("section.doka")
        case .dashboard: return L("section.dashboard")
        case .general: return L("section.general")
        case .sound: return L("section.sound")
        case .hotkeys: return L("section.hotkeys")
        case .dictionary: return L("section.dictionary")
        case .service: return L("section.service")
        case .history: return L("section.history")
        case .transcribe: return L("section.transcribeAudio")
        case .library: return L("section.library")
        }
    }

    var symbol: String {
        switch self {
        case .home: return "mic.fill"
        case .dashboard: return "chart.line.uptrend.xyaxis"
        case .general: return "gearshape.fill"
        case .sound: return "speaker.wave.2.fill"
        case .hotkeys: return "keyboard.fill"
        case .dictionary: return "character.book.closed.fill"
        case .service: return "key.fill"
        case .history: return "clock.fill"
        case .transcribe: return "waveform"
        case .library: return "books.vertical.fill"
        }
    }

    /// Цвет плитки иконки — приглушённые тона вместо ярких системных,
    /// чтобы сайдбар не пестрил на стекле. DOKA — фирменный персиковый.
    var tileColor: Color {
        switch self {
        case .home: return DS.accent
        case .dashboard: return Color(red: 0.36, green: 0.52, blue: 0.84)
        case .general: return Color(red: 0.52, green: 0.54, blue: 0.58)
        case .sound: return Color(red: 0.72, green: 0.42, blue: 0.58)
        case .hotkeys: return Color(red: 0.56, green: 0.47, blue: 0.76)
        case .dictionary: return Color(red: 0.78, green: 0.57, blue: 0.38)
        case .service: return Color(red: 0.44, green: 0.63, blue: 0.50)
        case .history: return Color(red: 0.40, green: 0.61, blue: 0.66)
        case .transcribe: return Color(red: 0.62, green: 0.45, blue: 0.66)
        case .library: return Color(red: 0.76, green: 0.47, blue: 0.40)
        }
    }
}

/// Состояние главного окна: активная секция.
/// Живёт в WindowManager, чтобы менять секцию у уже открытого окна.
@MainActor
final class MainWindowState: ObservableObject {
    @Published var section: MainSection = .home
}
