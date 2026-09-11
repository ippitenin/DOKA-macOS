import Foundation

/// Преобразование результата транскрипции в текстовые форматы для копирования.
/// Чистые детерминированные функции (как `WordCount`) — единый источник правды
/// для «чистый текст / с тайм-кодами / SRT / VTT / по спикерам». Отдельных
/// запросов к API для субтитров не делаем: всё строим из сегментов.
enum TranscriptFormatter {
    /// Чистый текст без разметки.
    static func plainText(_ r: TranscriptResult) -> String {
        let trimmed = r.fullText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return r.segments.map(\.text).joined(separator: " ")
    }

    /// Текст с тайм-кодом начала каждого сегмента: «[1:23] …».
    /// Спикеров сюда намеренно не подмешиваем — для этого есть отдельный
    /// формат `textWithTimestampsAndSpeakers`, иначе варианты неразличимы.
    static func textWithTimestamps(_ r: TranscriptResult) -> String {
        guard !r.segments.isEmpty else { return plainText(r) }
        return r.segments.map { seg in
            "[\(clock(seg.start))] \(seg.text)"
        }.joined(separator: "\n")
    }

    /// Текст с тайм-кодом и спикером: «[1:23] Спикер 1: …».
    /// У сегмента без спикера — строка без префикса.
    static func textWithTimestampsAndSpeakers(_ r: TranscriptResult) -> String {
        guard !r.segments.isEmpty else { return plainText(r) }
        return r.segments.map { seg in
            if let speaker = seg.speaker {
                return "[\(clock(seg.start))] \(SpeakerName.displayName(for: speaker)): \(seg.text)"
            }
            return "[\(clock(seg.start))] \(seg.text)"
        }.joined(separator: "\n")
    }

    /// Субтитры SRT (время `ЧЧ:ММ:СС,ммм`, нумерация с 1).
    static func srt(_ r: TranscriptResult) -> String {
        guard !r.segments.isEmpty else { return plainText(r) }
        let blocks = r.segments.enumerated().map { index, seg -> String in
            let line = seg.speaker.map { "\(SpeakerName.displayName(for: $0)): \(seg.text)" } ?? seg.text
            return "\(index + 1)\n\(srtTime(seg.start)) --> \(srtTime(seg.end))\n\(line)"
        }
        return blocks.joined(separator: "\n\n") + "\n"
    }

    /// Субтитры WebVTT (заголовок `WEBVTT`, время `ЧЧ:ММ:СС.ммм`).
    static func vtt(_ r: TranscriptResult) -> String {
        guard !r.segments.isEmpty else { return "WEBVTT\n\n" + plainText(r) + "\n" }
        let cues = r.segments.map { seg -> String in
            let line = seg.speaker.map { "\(SpeakerName.displayName(for: $0)): \(seg.text)" } ?? seg.text
            return "\(vttTime(seg.start)) --> \(vttTime(seg.end))\n\(line)"
        }
        return "WEBVTT\n\n" + cues.joined(separator: "\n\n") + "\n"
    }

    /// Текст по спикерам: подряд идущие реплики одного спикера объединены.
    static func bySpeaker(_ r: TranscriptResult) -> String {
        guard r.hasSpeakers else { return plainText(r) }
        var lines: [String] = []
        var currentSpeaker: String? = nil
        var buffer: [String] = []

        func flush() {
            guard !buffer.isEmpty else { return }
            // Группировка — по сырому id, отображение — человекочитаемое.
            let speaker = currentSpeaker.map(SpeakerName.displayName) ?? L("transcribe.speaker.unknown")
            lines.append("\(speaker): \(buffer.joined(separator: " "))")
            buffer.removeAll()
        }

        for seg in r.segments {
            if seg.speaker != currentSpeaker {
                flush()
                currentSpeaker = seg.speaker
            }
            buffer.append(seg.text)
        }
        flush()
        return lines.joined(separator: "\n")
    }

    // MARK: - Форматирование времени

    /// «м:сс» или «ч:мм:сс» для тайм-кода в тексте (и в строках записи библиотеки).
    static func clock(_ seconds: Double) -> String {
        let total = Int(safeSeconds(seconds))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }

    /// «ЧЧ:ММ:СС,ммм» — формат времени SRT.
    private static func srtTime(_ seconds: Double) -> String {
        let (h, m, s, ms) = parts(seconds)
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
    }

    /// «ЧЧ:ММ:СС.ммм» — формат времени WebVTT.
    private static func vttTime(_ seconds: Double) -> String {
        let (h, m, s, ms) = parts(seconds)
        return String(format: "%02d:%02d:%02d.%03d", h, m, s, ms)
    }

    private static func parts(_ seconds: Double) -> (Int, Int, Int, Int) {
        let totalMs = Int((safeSeconds(seconds) * 1000).rounded())
        return (totalMs / 3_600_000,
                (totalMs % 3_600_000) / 60_000,
                (totalMs % 60_000) / 1000,
                totalMs % 1000)
    }

    /// Защита от NaN/бесконечности/отрицательных значений.
    private static func safeSeconds(_ seconds: Double) -> Double {
        (seconds.isFinite && seconds > 0) ? seconds : 0
    }
}
