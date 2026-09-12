import AppKit
import SwiftUI

// Общие контролы расшифровки файлов: страница «Транскрибация», запись
// библиотеки (обе раскладки) и экспорт из списка библиотеки. Раньше жили
// приватно в TranscribeAudioSectionView — вынесены, чтобы запись и страница
// не расходились видом и поведением.

/// Компактная плашка «подпись + текущее значение», клик раскрывает нативное
/// меню выбора. Ряд таких плашек занимает одну строку вместо трёх строк формы.
/// Ловушка: SwiftUI `Menu` на macOS ломает кастомный многострочный лейбл
/// (плашка схлопывалась в текст с шевроном) — поэтому плашка рисуется чистым
/// SwiftUI, а кликом заведует растянутый поверх невидимый `NSPopUpButton`
/// (`isTransparent`: не рисуется, но получает события — как `PopUpButton`
/// в SettingsForm).
struct OptionTile: View {
    let caption: String
    let value: String
    let options: [String]
    let selectedIndex: Int
    let onSelect: (Int) -> Void

    @State private var isHovering = false
    /// Плашка недоступна, когда параметр принадлежит только встроенному
    /// сервису: остаётся на месте приглушённой, чтобы было видно, что функция
    /// существует, а не исчезла.
    @Environment(\.isEnabled) private var isEnabled

    /// Ховер не должен «оживать» на недоступной плашке.
    private var showsHover: Bool { isHovering && isEnabled }

    var body: some View {
        HStack(spacing: 4) {
            VStack(alignment: .leading, spacing: 3) {
                Text(caption)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .lineLimit(1)
                Text(value)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(showsHover ? DS.accent : .secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Подложка и кромка адаптивные (Color.primary, НЕ .white: белый тинт на
        // белом фоне светлой темы невидим); ховер подсвечивает плашку кнопкой.
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.badge, style: .continuous)
                .fill(Color.primary.opacity(showsHover ? 0.08 : 0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.badge, style: .continuous)
                .strokeBorder(showsHover ? DS.accent.opacity(0.6) : Color.primary.opacity(0.12), lineWidth: 1)
        )
        .overlay(
            TilePopUpOverlay(titles: options, selectedIndex: selectedIndex,
                             isEnabled: isEnabled, onSelect: onSelect)
        )
        .opacity(isEnabled ? 1 : 0.5)
        .onHover { isHovering = $0 }
        .animation(DS.Anim.hover, value: showsHover)
    }
}

/// Невидимый NSPopUpButton на всю плашку: системное меню с галочкой на
/// выбранном пункте, кликается вся площадь. Копия паттерна `PopUpButton`
/// из SettingsForm (тот приватный и рисует стандартную кнопку).
struct TilePopUpOverlay: NSViewRepresentable {
    let titles: [String]
    let selectedIndex: Int
    let isEnabled: Bool
    let onSelect: (Int) -> Void

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.isBordered = false
        button.isTransparent = true     // не рисует фон, но получает клики
        // Нативную стрелку гасим — свой шеврон рисует плашка (иначе задвоение).
        (button.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        button.target = context.coordinator
        button.action = #selector(Coordinator.didChange(_:))
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        // Прозрачная кнопка лежит ПОВЕРХ плашки и ловит клики сама: без явного
        // isEnabled внешний `.disabled` её не остановит (SwiftUI не пробрасывает
        // окружение внутрь NSViewRepresentable).
        button.isEnabled = isEnabled
        if button.itemTitles != titles {
            button.removeAllItems()
            // Не addItems(withTitles:) — он молча выкидывает дубликаты.
            for title in titles {
                button.menu?.addItem(NSMenuItem(title: title, action: nil, keyEquivalent: ""))
            }
        }
        if button.indexOfSelectedItem != selectedIndex,
           titles.indices.contains(selectedIndex) {
            button.selectItem(at: selectedIndex)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor
    final class Coordinator: NSObject {
        var parent: TilePopUpOverlay

        init(_ parent: TilePopUpOverlay) {
            self.parent = parent
        }

        @objc func didChange(_ sender: NSPopUpButton) {
            parent.onSelect(sender.indexOfSelectedItem)
        }
    }
}

// MARK: - Форматы сохранения

/// Формат сохранения расшифровки в файл.
enum SaveFormat: String, Identifiable, CaseIterable {
    case plain, timestamps, srt, vtt, speakers, timestampsSpeakers

    var id: String { rawValue }

    var title: String {
        switch self {
        case .plain: return L("transcribe.format.plain")
        case .timestamps: return L("transcribe.format.timestamps")
        case .srt: return L("transcribe.format.srt")
        case .vtt: return L("transcribe.format.vtt")
        case .speakers: return L("transcribe.format.speakers")
        case .timestampsSpeakers: return L("transcribe.format.timestampsSpeakers")
        }
    }

    /// Расширение файла. SRT/VTT — свои; остальные текстовые форматы — .txt.
    var fileExtension: String {
        switch self {
        case .srt: return "srt"
        case .vtt: return "vtt"
        case .plain, .timestamps, .speakers, .timestampsSpeakers: return "txt"
        }
    }

    /// Форматы, осмысленные для результата: «по спикерам» — только со спикерами.
    static func available(for result: TranscriptResult) -> [SaveFormat] {
        var formats: [SaveFormat] = [.plain, .timestamps]
        if result.hasSpeakers { formats += [.speakers, .timestampsSpeakers] }
        formats += [.srt, .vtt]
        return formats
    }

    /// Форматы экспорта «Отдельные файлы в папку»: выбираются для пачки
    /// записей сразу, поэтому «по спикерам» есть всегда (без спикеров он
    /// сводится к чистому тексту).
    static let folderExport: [SaveFormat] = [.plain, .timestamps, .srt, .vtt, .speakers]

    func text(for result: TranscriptResult) -> String {
        switch self {
        case .plain: return TranscriptFormatter.plainText(result)
        case .timestamps: return TranscriptFormatter.textWithTimestamps(result)
        case .srt: return TranscriptFormatter.srt(result)
        case .vtt: return TranscriptFormatter.vtt(result)
        case .speakers: return TranscriptFormatter.bySpeaker(result)
        case .timestampsSpeakers: return TranscriptFormatter.textWithTimestampsAndSpeakers(result)
        }
    }
}

/// Формат сохранения LLM-анализа в файл. Markdown — сырой ответ как есть;
/// обычный текст — без символов разметки. (PDF сознательно отложен.)
enum AnalysisSaveFormat: String, Identifiable, CaseIterable {
    case markdown, plain

    var id: String { rawValue }

    var title: String {
        switch self {
        case .markdown: return L("transcribe.analysisFormat.markdown")
        case .plain: return L("transcribe.analysisFormat.plain")
        }
    }

    var fileExtension: String {
        switch self {
        case .markdown: return "md"
        case .plain: return "txt"
        }
    }

    func text(for markdown: String) -> String {
        self == .markdown ? markdown : LightMarkdown.plainText(markdown)
    }
}

/// Меню «Сохранить как…» с единым оформлением; пункты задаёт вызывающий.
/// `Label` + `.borderlessButton` — рабочий паттерн: кастомный лейбл SwiftUI
/// `Menu` на macOS ломает.
struct SaveAsMenu<Items: View>: View {
    @ViewBuilder var items: Items

    var body: some View {
        Menu {
            items
        } label: {
            Label(L("transcribe.save"), systemImage: "square.and.arrow.down")
                .font(.caption)
                .foregroundStyle(DS.accent)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L("transcribe.save"))
    }
}

/// Запись текста в файл через системный диалог. Приложение не в песочнице —
/// пишем по выбранному пути напрямую.
@MainActor
enum TextFileSaver {
    static func save(_ text: String, suggestedName: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        // Расширения SRT/VTT/MD система как UTType может не знать — формат
        // задаёт само имя файла; ограничиваем тип только для txt.
        if (suggestedName as NSString).pathExtension.lowercased() == "txt" {
            panel.allowedContentTypes = [.plainText]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        write(text, to: url)
    }

    @discardableResult
    static func write(_ text: String, to url: URL) -> Bool {
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch {
            NSLog("DOKA: не удалось сохранить файл: \(error.localizedDescription)")
            return false
        }
    }
}

// MARK: - Спикеры

/// Цвета бэйджей спикеров. Какой спикер какого цвета — решает чистый
/// `SpeakerName.colorIndices` (через `TranscriptResult.speakerColorIndices`).
enum SpeakerPalette {
    static let colors: [Color] = [
        DS.accent, DS.Aurora.indigo, DS.coral,
        Color(red: 0.44, green: 0.63, blue: 0.50),
        Color(red: 0.36, green: 0.52, blue: 0.84)
    ]

    static func color(at index: Int) -> Color {
        // Остаток неотрицательный: индекс мог прийти из битых данных.
        let count = colors.count
        return colors[((index % count) + count) % count]
    }
}

// MARK: - Запись библиотеки для UI

extension FileTranscriptRecord {
    /// Иконка по расширению исходника (списки форматов — у контроллера на главном акторе).
    @MainActor
    var fileIcon: String {
        let ext = (fileName as NSString).pathExtension.lowercased()
        return FileTranscriptionController.videoExtensions.contains(ext) ? "film" : "waveform"
    }

    /// Название сервиса: builtin — локализованное, пресет и локальная модель —
    /// как записано (тот же маппинг, что в инспекторе истории).
    var providerLabel: String {
        TranscriptionProvider(rawValue: provider)?.title ?? provider
    }

    /// Длительность готовой записи тайм-кодом; nil — неизвестна.
    var durationLabel: String? {
        guard isDone, let duration, duration > 0 else { return nil }
        return TranscriptFormatter.clock(duration)
    }

    /// «Дата · сервис [· длительность]» — строка списка и метаданные экспорта.
    var metaLine: String {
        var parts = [date.formatted(date: .abbreviated, time: .shortened), providerLabel]
        if let durationLabel { parts.append(durationLabel) }
        return parts.joined(separator: " · ")
    }

    /// Звук записи заархивирован (без обращения к диску — для строк списка).
    var hasArchivedAudio: Bool { audioFileName != nil }

    /// Готовое имя файла для «Сохранить как…».
    var exportBaseName: String { LibraryExport.sanitizedFileName(displayTitle) }
}
