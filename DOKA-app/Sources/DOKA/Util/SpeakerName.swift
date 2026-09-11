import Foundation

/// Отображаемое имя спикера: серверный id «speaker_0» → локализованное
/// «Спикер 1». Сырые id показывать нельзя — выглядят как системный мусор.
/// Чистые детерминированные функции (как `TranscriptFormatter`).
enum SpeakerName {
    private static let prefix = "speaker_"
    /// Метка лишнего говорящего при разметке ролей: спикеров оказалось
    /// больше, чем задано ролей. Nexara нумерует unknown с единицы.
    private static let unknownPrefix = "unknown_"

    /// Индекс из сырого id: «speaker_0» → 0. nil, если формат не распознан.
    static func index(of raw: String) -> Int? {
        let lowered = raw.lowercased()
        guard lowered.hasPrefix(prefix) else { return nil }
        return Int(lowered.dropFirst(prefix.count))
    }

    /// «speaker_N» → «Спикер N+1» (нумерация для людей — с единицы),
    /// «unknown_N» → «Неизвестный N». Нераспознанный id (имя роли —
    /// «Клиент», «Агент») возвращается как есть.
    static func displayName(for raw: String) -> String {
        if let index = index(of: raw) {
            return L("transcribe.speaker.name", index + 1)
        }
        let lowered = raw.lowercased()
        if lowered.hasPrefix(unknownPrefix),
           let number = Int(lowered.dropFirst(unknownPrefix.count)) {
            return L("transcribe.speaker.unknownName", number)
        }
        return raw
    }

    /// id нового спикера («Назначить реплику → Новый спикер»): `speaker_N`
    /// со следующим номером после всех известных. `existing` обязан включать
    /// и ключи слияний — иначе новый спикер мог бы получить id влитого, и
    /// переназначение молча слилось бы с ним.
    static func nextID(existing: some Sequence<String>) -> String {
        let maxIndex = existing.compactMap(index(of:)).max() ?? -1
        return prefix + String(maxIndex + 1)
    }

    /// Индексы цветов бэйджей: `speaker_N` — по номеру, остальные id (роли,
    /// `unknown_N`, новые спикеры) — по порядку в `orderedIDs`, пропуская
    /// номера, занятые `speaker_N`: иначе роль и «Новый спикер» делили бы цвет.
    /// Детерминировано между запусками — hashValue String рандомизирован на
    /// процесс, и цвет роли «плавал» бы.
    static func colorIndices(orderedIDs: [String]) -> [String: Int] {
        let reserved = Set(orderedIDs.compactMap(index(of:)))
        var indices: [String: Int] = [:]
        var nextOrdinal = 0
        for id in orderedIDs where indices[id] == nil {
            if let index = index(of: id) {
                indices[id] = index
            } else {
                while reserved.contains(nextOrdinal) { nextOrdinal += 1 }
                indices[id] = nextOrdinal
                nextOrdinal += 1
            }
        }
        return indices
    }
}
