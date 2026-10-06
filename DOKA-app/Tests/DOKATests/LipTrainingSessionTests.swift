import XCTest
@testable import DOKA

/// Учёт сеанса окна «Тренировка».
///
/// Зачем: здесь решается судьба каждой фразы. Ошибка — и записанная фраза
/// либо теряется (не фиксируется, не возвращается после отбраковки), либо
/// предлагается снова, либо счётчик «за сеанс» врёт. Камера и микрофон тут
/// не участвуют — только решения.
final class LipTrainingSessionTests: XCTestCase {
    private let phrases = ["Первая тестовая фраза", "Вторая тестовая фраза", "Третья тестовая фраза",
                           "Четвёртая тестовая фраза", "Пятая тестовая фраза"]
        .map { LipTrainingPhrase(text: $0, origin: .work) }

    /// Открытый сеанс с фразами в заданном порядке (один пул — без перемешивания).
    private func openSession() -> LipTrainingSession {
        var session = LipTrainingSession()
        XCTAssertTrue(session.open())
        session.reload(LipTrainingQueue(pools: phrases.map { [$0] }, done: [], seed: 0))
        return session
    }

    private func held(_ phrase: LipTrainingPhrase) -> LipTrainingSession.Held {
        let take = LipTake(id: UUID(), pendingRoot: FileManager.default.temporaryDirectory)
        let audio = RecordedDictation(url: URL(fileURLWithPath: "/tmp/doka-\(take.id).wav"), duration: 3,
                                      speechDuration: 0, microphone: nil, lipTake: take)
        return .init(take: take, audio: audio, phrase: phrase)
    }

    /// Записать текущую фразу: стоп с решением «оставить».
    @discardableResult
    private func record(_ session: inout LipTrainingSession) throws -> LipTrainingSession.Held {
        let item = held(try XCTUnwrap(session.current))
        session.hold(item)
        return item
    }

    func testRecordedPhraseIsHeldAndNextIsShown() throws {
        var session = openSession()
        let first = try record(&session)
        XCTAssertEqual(session.current, phrases[1])
        XCTAssertEqual(session.held, first)
        XCTAssertTrue(session.canRewrite)
        XCTAssertEqual(session.last, .init(phrase: phrases[0], result: .held))
        XCTAssertTrue(session.inFlight.isEmpty, "до следующей фразы — не в обработке")
    }

    /// Следующая фраза (или закрытие окна) — прошлая уходит в обработку.
    func testReleaseMovesHeldToProcessing() throws {
        var session = openSession()
        let first = try record(&session)
        XCTAssertEqual(session.releaseHeld(), first)
        XCTAssertNil(session.held)
        XCTAssertFalse(session.canRewrite)
        XCTAssertEqual(session.inFlight, [first.take.id: phrases[0]])
        XCTAssertEqual(session.last?.result, .processing)
        XCTAssertNil(session.releaseHeld(), "дважды не фиксируется")
    }

    /// «Переписать прошлую» — пара выбрасывается, фраза снова первой.
    func testRewriteReturnsPhraseToFront() throws {
        var session = openSession()
        let first = try record(&session)
        XCTAssertEqual(session.rewrite(), first)
        XCTAssertEqual(session.current, phrases[0])
        XCTAssertNil(session.held)
        XCTAssertNil(session.last)
        XCTAssertTrue(session.inFlight.isEmpty)
        XCTAssertNil(session.rewrite(), "переписывать больше нечего")
    }

    func testSavedOutcomeCountsOnlyWhileOpen() throws {
        var session = openSession()
        let first = try record(&session)
        _ = session.releaseHeld()
        XCTAssertTrue(session.apply(.saved(first.take.id)))
        XCTAssertEqual(session.saved, 1)
        XCTAssertEqual(session.last?.result, .saved)

        // Окно закрыли, пока вторая фраза обрабатывалась: исход приходит, но
        // в счётчик закрытого сеанса не идёт.
        let second = try record(&session)
        _ = session.releaseHeld()
        XCTAssertTrue(session.close())
        XCTAssertTrue(session.apply(.saved(second.take.id)))
        XCTAssertEqual(session.saved, 1)
        XCTAssertTrue(session.inFlight.isEmpty)
    }

    /// Отброшенная фраза возвращается через три позиции и объясняет причину.
    func testRejectedPhraseComesBackLater() throws {
        var session = openSession()
        let first = try record(&session)
        _ = session.releaseHeld()
        XCTAssertTrue(session.apply(.rejected(first.take.id, .noLips)))
        XCTAssertEqual(session.last, .init(phrase: phrases[0], result: .rejected(.noLips)))
        XCTAssertEqual(session.queue.items.firstIndex(of: phrases[0]), 3)
        XCTAssertEqual(session.current, phrases[1])
        XCTAssertEqual(session.saved, 0)
    }

    /// Фразы кончились, а последняя отброшена — она снова на экране.
    func testRejectedPhraseFillsEmptyScreen() throws {
        var session = LipTrainingSession()
        _ = session.open()
        session.reload(LipTrainingQueue(pools: [[phrases[0]]], done: [], seed: 0))
        let only = try record(&session)
        XCTAssertNil(session.current)
        _ = session.releaseHeld()
        session.apply(.rejected(only.take.id, nil))
        XCTAssertEqual(session.current, phrases[0])
        XCTAssertEqual(session.last?.result, .rejected(nil))
    }

    /// В закрытом окне очереди нет — отброшенная фраза в неё не встаёт
    /// (следующий сеанс соберёт её заново: на диске её нет).
    func testRejectedAfterCloseIsNotRequeued() throws {
        var session = openSession()
        let first = try record(&session)
        _ = session.releaseHeld()
        _ = session.close()
        let before = session.queue.items
        session.apply(.rejected(first.take.id, .tooShort))
        XCTAssertEqual(session.queue.items, before)
        XCTAssertEqual(session.last?.result, .rejected(.tooShort))
    }

    /// Исход диктовки или дубля прошлого запуска — не наш.
    func testForeignOutcomeIsIgnored() throws {
        var session = openSession()
        let first = try record(&session)
        _ = session.releaseHeld()
        XCTAssertFalse(session.apply(.saved(UUID())))
        XCTAssertFalse(session.apply(.rejected(UUID(), .noLips)))
        XCTAssertEqual(session.saved, 0)
        XCTAssertEqual(session.inFlight.count, 1)
        XCTAssertEqual(session.last?.result, .processing)
        XCTAssertTrue(session.apply(.saved(first.take.id)))
    }

    /// Отложенная фраза и фразы в обработке ещё не на диске — новая очередь
    /// (повторное открытие окна) их не предлагает.
    func testPendingKeysCoverHeldAndInFlight() throws {
        var session = openSession()
        try record(&session)
        _ = session.releaseHeld()
        try record(&session)
        XCTAssertEqual(session.pendingKeys, Set(phrases[0...1].map { LipTrainingPhrases.normalize($0.text) }))

        let reloaded = LipTrainingQueue(pools: phrases.map { [$0] }, done: session.pendingKeys, seed: 0)
        XCTAssertEqual(reloaded.items, Array(phrases[2...]))
    }

    /// Новый сеанс: счётчик и «прошлая» с нуля, но фраза, ушедшая в
    /// обработку в прошлом сеансе, не теряется — её исход ещё придёт.
    func testReopenKeepsInFlight() throws {
        var session = openSession()
        let first = try record(&session)
        _ = session.releaseHeld()
        _ = session.close()
        XCTAssertTrue(session.open())
        XCTAssertFalse(session.open(), "второй раз не открывается")
        XCTAssertNil(session.last)
        XCTAssertEqual(session.saved, 0)
        XCTAssertTrue(session.apply(.saved(first.take.id)))
        XCTAssertEqual(session.saved, 1)
    }

    func testSkipAndLoadingState() throws {
        var session = openSession()
        session.skip()
        XCTAssertEqual(session.current, phrases[1])
        session.reload(.empty)
        XCTAssertNil(session.current, "пока фразы грузятся, на экране пусто")
        XCTAssertTrue(session.close())
        XCTAssertFalse(session.close())
    }
}
