import CryptoKit
import Foundation

/// Системный словарь — встроенный список общих замен (бренды и продукты
/// латиницей: «в телеграме» → «в Telegram»). Чистая логика: разбор файла
/// `Resources/SystemDictionary.txt`, обновление рабочей копии пользователя
/// при новой версии списка и итоговый набор правил вместе с личными.
///
/// У пользователя — РАБОЧАЯ КОПИЯ (`SettingsStore.systemReplacements`): её
/// можно править, выключать и удалять строки. Встроенная запись узнаётся
/// между версиями по детерминированному `id` от шаблона, поэтому новая версия
/// списка только ДОБАВЛЯЕТ записи, которых у пользователя нет и которые он
/// не удалял, — его правки не трогаются.
enum SystemDictionary {
    struct Bundled: Equatable {
        let version: Int
        let rules: [ReplacementRule]
    }

    static let arrow = "→"

    /// Разбор файла: `шаблон → замена`, `#` — комментарий, `# version: N` —
    /// версия списка. Строки без стрелки или с пустой стороной пропускаются.
    static func parse(_ contents: String) -> Bundled {
        var version = 0
        var rules: [ReplacementRule] = []
        for line in contents.split(whereSeparator: \.isNewline) {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("#") {
                let body = text.dropFirst().trimmingCharacters(in: .whitespaces)
                if body.hasPrefix("version:"), let number = Int(body.dropFirst("version:".count)
                    .trimmingCharacters(in: .whitespaces)) {
                    version = number
                }
                continue
            }
            let parts = text.components(separatedBy: arrow)
            guard parts.count == 2 else { continue }
            let from = parts[0].trimmingCharacters(in: .whitespaces)
            let to = parts[1].trimmingCharacters(in: .whitespaces)
            guard !from.isEmpty, !to.isEmpty else { continue }
            rules.append(ReplacementRule(id: id(for: from), from: from, to: to))
        }
        return Bundled(version: version, rules: rules)
    }

    /// Список из бандла.
    static func bundled(bundle: Bundle = .module) -> Bundled {
        guard let url = bundle.url(forResource: "SystemDictionary", withExtension: "txt"),
              let contents = try? String(contentsOf: url, encoding: .utf8) else {
            NSLog("DOKA: системный словарь не найден в бандле")
            return Bundled(version: 0, rules: [])
        }
        return parse(contents)
    }

    /// Детерминированный `id` встроенной записи — от шаблона без учёта регистра.
    static func id(for from: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(key(from).utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50   // версия 5 (имя → UUID)
        bytes[8] = (bytes[8] & 0x3F) | 0x80   // вариант RFC 4122
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// Ключ сравнения шаблонов: без регистра и пробелов по краям.
    static func key(_ from: String) -> String {
        from.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// Новая версия списка: к рабочей копии добавляются встроенные записи,
    /// которых в ней нет и которые пользователь не удалял. Порядок и правки
    /// пользователя сохраняются.
    static func merge(stored: [ReplacementRule], bundled: [ReplacementRule],
                      removed: Set<UUID>) -> [ReplacementRule] {
        let present = Set(stored.map(\.id))
        return stored + bundled.filter { !present.contains($0.id) && !removed.contains($0.id) }
    }

    /// Итоговый набор для движка: личные правила плюс системные (если словарь
    /// включён). Личное ВКЛЮЧЁННОЕ правило главнее: системное с тем же
    /// шаблоном пропускается.
    static func active(user: [ReplacementRule], system: [ReplacementRule],
                       systemEnabled: Bool) -> [ReplacementRule] {
        guard systemEnabled else { return user }
        let shadowed = Set(user.filter(\.enabled).map { key($0.from) })
        return user + system.filter { !shadowed.contains(key($0.from)) }
    }
}
