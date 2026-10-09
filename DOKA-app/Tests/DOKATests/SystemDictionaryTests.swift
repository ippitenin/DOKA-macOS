import XCTest
@testable import DOKA

/// Системный словарь: встроенный список общих замен, рабочая копия
/// пользователя и её обновление новой версией списка.
///
/// Зачем: словарь применяется к каждой диктовке у каждого, кто его не
/// выключил, — ложная замена обычного русского слова испортит текст молча.
/// А обновление списка не должно ни вернуть удалённое пользователем, ни
/// затереть его правки.
final class SystemDictionaryTests: XCTestCase {

    func testParseReadsRulesVersionAndSkipsJunk() {
        let parsed = SystemDictionary.parse("""
        # комментарий
        # version: 3
        телеграм → Telegram
          ютуб   →   YouTube
        без стрелки
         → пустой шаблон
        пустая замена →
        """)
        XCTAssertEqual(parsed.version, 3)
        XCTAssertEqual(parsed.rules.map(\.from), ["телеграм", "ютуб"])
        XCTAssertEqual(parsed.rules.map(\.to), ["Telegram", "YouTube"])
        XCTAssertTrue(parsed.rules.allSatisfy { $0.enabled && $0.matchWordForms && !$0.matchInsideWords })
    }

    /// `id` встроенной записи не зависит от регистра и запуска — по нему
    /// запись узнаётся между версиями списка.
    func testIDIsDeterministic() {
        XCTAssertEqual(SystemDictionary.id(for: "Телеграм"), SystemDictionary.id(for: "телеграм "))
        XCTAssertNotEqual(SystemDictionary.id(for: "телеграм"), SystemDictionary.id(for: "ютуб"))
        XCTAssertEqual(SystemDictionary.parse("телеграм → Telegram").rules[0].id, SystemDictionary.id(for: "телеграм"))
    }

    /// Новая версия: добавляются только новые записи; удалённые не
    /// воскресают, правки и порядок пользователя целы.
    func testMergeAddsOnlyNewEntries() {
        let v1 = SystemDictionary.parse("телеграм → Telegram\nютуб → YouTube\nгугл → Google").rules
        var stored = v1
        stored[0].to = "Телеграм"          // правка пользователя
        stored[1].enabled = false           // выключил
        stored.removeLast()                 // удалил «гугл»
        stored.reverse()                    // переставил
        let removed: Set<UUID> = [SystemDictionary.id(for: "гугл")]
        let v2 = SystemDictionary.parse("телеграм → Telegram\nютуб → YouTube\nгугл → Google\nфигма → Figma").rules
        let merged = SystemDictionary.merge(stored: stored, bundled: v2, removed: removed)
        XCTAssertEqual(merged.map(\.from), ["ютуб", "телеграм", "фигма"])
        XCTAssertEqual(merged[1].to, "Телеграм")
        XCTAssertFalse(merged[0].enabled)
    }

    /// Личное включённое правило главнее системного с тем же шаблоном;
    /// выключенный словарь не даёт ничего.
    func testActivePrefersEnabledUserRules() {
        let system = SystemDictionary.parse("телеграм → Telegram\nютуб → YouTube").rules
        let mine = [ReplacementRule(from: "Телеграм", to: "TG")]
        var muted = ReplacementRule(from: "ютуб", to: "Ютуб")
        muted.enabled = false
        let active = SystemDictionary.active(user: mine + [muted], system: system, systemEnabled: true)
        XCTAssertEqual(ReplacementEngine.apply("в телеграме и на ютубе", rules: active), "в TG и на YouTube")
        XCTAssertEqual(SystemDictionary.active(user: mine, system: system, systemEnabled: false), mine)
    }

    // MARK: - Встроенный список

    /// Каждая строка разбирается, дублей нет, у списка есть версия.
    func testBundledListIsValid() {
        let bundled = SystemDictionary.bundled()
        XCTAssertGreaterThanOrEqual(bundled.version, 1)
        XCTAssertGreaterThanOrEqual(bundled.rules.count, 300)
        let keys = bundled.rules.map { SystemDictionary.key($0.from) }
        XCTAssertEqual(Set(keys).count, keys.count, "дубли шаблонов")
        XCTAssertEqual(Set(bundled.rules.map(\.id)).count, bundled.rules.count)
    }

    /// Обычные русские слова — не шаблоны системного словаря: «зум камеры»,
    /// «сафари», «виза», «редис» должны остаться как есть у всех.
    func testBundledListAvoidsCommonRussianWords() {
        let stoplist: Set<String> = [
            "зум", "хром", "сафари", "виза", "курсор", "лама", "озон", "дока", "мда", "редис", "блендер",
            "канва", "асана", "премьер", "обсидиан", "ажур", "питон", "сигнал", "метрика", "телеграмма",
            "телеграмм", "клауд", "иллюстратор", "сора", "мейк", "лум", "тайп", "нода",
            // Формы этих шаблонов — обычные слова (проверка орфографией macOS):
            "убер", "раст", "бинг", "тильда", "юнити", "хероку", "сони",
        ]
        let keys = Set(SystemDictionary.bundled().rules.map { SystemDictionary.key($0.from) })
        XCTAssertEqual(keys.intersection(stoplist), [])
        let text = "Сделай зум камеры, пришла телеграмма, мда, в сафари нужна виза, курсор у лама, " +
            "на озоне редис, погугли, гуглить, гугли, Леонардо да Винчи, в доке написано. " +
            "Давай уберём это, будем расти, бинго, нажми тильду, юниты, у Сони."
        XCTAssertEqual(ReplacementEngine.apply(text, rules: SystemDictionary.bundled().rules), text)
    }

    /// Сквозной пример: падежи, многословные шаблоны и регистр латиницы.
    func testBundledListOnTypicalDictation() {
        let rules = SystemDictionary.bundled().rules
        XCTAssertEqual(
            ReplacementEngine.apply("Скинь в телеграме и в вотсапе, файл в гугл докс, спроси у чата гпт про iphone.",
                                    rules: rules),
            "Скинь в Telegram и в WhatsApp, файл в Google Docs, спроси у ChatGPT про iPhone.")
    }

    /// Весь системный словарь на длинной расшифровке (словарь для файлов
    /// применяется на каждом рендере). Замер 9.10.2026, debug, M5 Pro: 84 мс
    /// со 100 тыс. знаков, диктовка — 1 мс; без отсева `memmem` было 5,7 с.
    /// Порог с запасом под медленный раннер CI — ловит именно такой откат.
    func testBundledListIsFastOnLongTranscript() {
        let rules = SystemDictionary.bundled().rules
        let chunk = "Сегодня обсудили релиз, в телеграме выложили пост, на ютубе ролик, дальше по плану. "
        let text = String(repeating: chunk, count: 1_200)   // ~100 тыс. знаков
        let started = Date()
        _ = ReplacementEngine.apply(text, rules: rules)
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertLessThan(elapsed, 0.5, "\(rules.count) правил на \(text.count) знаках: \(elapsed) с")
    }
}
