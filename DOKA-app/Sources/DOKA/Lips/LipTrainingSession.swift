import Foundation

/// Учёт сеанса окна «Тренировка». Чистая логика.
///
/// Какая фраза на экране, какая записана и ждёт следующей (её ещё можно
/// переписать), какие ушли в обработку и чем кончилась прошлая. Камеру,
/// микрофон, таймеры и стор держит `LipTrainingController` — здесь только
/// решения, поэтому они проверяются тестами.
struct LipTrainingSession {
    /// Записанная фраза, отложенная до следующей: до фиксации «Переписать
    /// прошлую» — просто выброс.
    struct Held: Equatable {
        let take: LipTake
        let audio: RecordedDictation
        let phrase: LipTrainingPhrase
    }

    /// Судьба прошлой фразы.
    struct Last: Equatable {
        enum Result: Equatable {
            /// Записана, ещё можно переписать (R).
            case held
            /// Ушла в обработку.
            case processing
            case saved
            /// nil — данные потерялись (не решение по паре).
            case rejected(LipRejectReason?)
        }

        let phrase: LipTrainingPhrase
        var result: Result
    }

    /// Окно открыто.
    private(set) var isOpen = false
    private(set) var queue = LipTrainingQueue.empty
    private(set) var held: Held?
    /// Зафиксированные фразы, ждущие исхода обработки. Закрытие окна их не
    /// забывает: исход может прийти и после него.
    private(set) var inFlight: [UUID: LipTrainingPhrase] = [:]
    private(set) var last: Last?
    /// Сохранено за сеанс.
    private(set) var saved = 0

    /// Фраза на экране; nil — фразы кончились или ещё грузятся.
    var current: LipTrainingPhrase? { queue.current }
    var canRewrite: Bool { held != nil }

    /// Ключи фраз, записанных в этом процессе, но ещё не дошедших до диска:
    /// отложенная и в обработке. Новая очередь их не предлагает.
    var pendingKeys: Set<String> {
        var keys = Set(inFlight.values.map { LipTrainingPhrases.normalize($0.text) })
        if let held { keys.insert(LipTrainingPhrases.normalize(held.phrase.text)) }
        return keys
    }

    // MARK: - Сеанс

    /// Окно открыли: счётчик и «прошлая» — с нуля, фразы в обработке остаются.
    /// false — окно уже открыто.
    mutating func open() -> Bool {
        guard !isOpen else { return false }
        isOpen = true
        saved = 0
        last = nil
        return true
    }

    /// Окно закрыли. false — оно и не было открыто. Отложенную фразу
    /// фиксирует контроллер (`releaseHeld`).
    mutating func close() -> Bool {
        guard isOpen else { return false }
        isOpen = false
        return true
    }

    /// Новая очередь фраз; `.empty` — пока фразы грузятся.
    mutating func reload(_ queue: LipTrainingQueue) {
        self.queue = queue
    }

    // MARK: - Фразы

    /// Фраза записана и прошла проверку: откладывается до следующей, а на
    /// экран выходит следующая.
    mutating func hold(_ held: Held) {
        self.held = held
        last = Last(phrase: held.phrase, result: .held)
        queue.advance()
    }

    /// Отложенную фразу пора фиксировать: началась следующая фраза, окно закрыли
    /// или приложение выходит. Фраза встаёт в обработку раньше, чем стор
    /// получит дубль, — исход сбоя фиксации должен её найти.
    mutating func releaseHeld() -> Held? {
        guard let held else { return nil }
        self.held = nil
        inFlight[held.take.id] = held.phrase
        if last?.phrase == held.phrase { last?.result = .processing }
        return held
    }

    /// «Переписать прошлую»: отложенная пара выбрасывается, её фраза снова на
    /// экране.
    mutating func rewrite() -> Held? {
        guard let held else { return nil }
        self.held = nil
        queue.pushFront(held.phrase)
        last = nil
        return held
    }

    /// «Пропустить» — фраза уходит в конец очереди.
    mutating func skip() {
        queue.skip()
    }

    /// Исход обработки. Счётчик сеанса растёт, а отброшенная фраза
    /// возвращается в очередь только при открытом окне: закрытое очереди не
    /// держит, следующий сеанс соберёт её заново. false — исход чужой
    /// (диктовка или дубль прошлого запуска).
    @discardableResult
    mutating func apply(_ outcome: LipTakeOutcome) -> Bool {
        guard let phrase = inFlight.removeValue(forKey: outcome.id) else { return false }
        switch outcome {
        case .saved:
            if isOpen { saved += 1 }
            if last?.phrase == phrase { last?.result = .saved }
        case .rejected(_, let reason):
            // Отброшенная фраза вернётся позже: причина (свет, ладонь) могла уйти.
            if isOpen { queue.requeue(phrase) }
            last = Last(phrase: phrase, result: .rejected(reason))
        }
        return true
    }
}
