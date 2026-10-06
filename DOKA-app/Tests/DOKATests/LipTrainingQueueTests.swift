import XCTest
@testable import DOKA

/// Очередь фраз сеанса тренировки.
///
/// Зачем: записанная фраза, предложенная снова, — потерянная минута и дубль
/// одного текста в данных; пул без чередования даёт сеанс из одних рабочих
/// указаний; отброшенная обработкой фраза не должна потеряться.
final class LipTrainingQueueTests: XCTestCase {
    private func pool(_ origin: LipTrainingPhrase.Origin, _ texts: [String]) -> [LipTrainingPhrase] {
        texts.map { LipTrainingPhrase(text: $0, origin: origin) }
    }

    private var pools: [[LipTrainingPhrase]] {
        [pool(.history, ["история один", "история два"]),
         pool(.work, ["работа один", "работа два", "работа три"]),
         pool(.everyday, ["быт один"])]
    }

    /// Пулы чередуются по кругу; короткий пул кончается — остальные идут дальше.
    func testPoolsInterleave() {
        let queue = LipTrainingQueue(pools: pools, done: [], seed: 1)
        XCTAssertEqual(queue.items.map(\.origin),
                       [.history, .work, .everyday, .history, .work, .work])
        XCTAssertEqual(queue.count, 6)
    }

    /// Записанные фразы не предлагаются (сравнение без регистра, «ё» и пунктуации).
    func testDoneAndDuplicatesAreExcluded() {
        let pools = [pool(.history, ["Ещё раз проверь сборку!", "Купи хлеба по дороге."]),
                     pool(.everyday, ["купи хлеба по дороге", "Полей цветы на подоконнике."])]
        let done: Set<String> = [LipTrainingPhrases.normalize("еще раз проверь сборку")]
        let queue = LipTrainingQueue(pools: pools, done: done, seed: 7)
        XCTAssertEqual(queue.items, [
            LipTrainingPhrase(text: "Купи хлеба по дороге.", origin: .history),
            LipTrainingPhrase(text: "Полей цветы на подоконнике.", origin: .everyday),
        ])
    }

    func testSameSeedSameOrderDifferentSeedShuffles() {
        // Различаются буквой: цифры нормализация отбрасывает, и фразы слиплись бы.
        let big = [pool(.work, (0..<30).map { "работа буква " + String(UnicodeScalar(0x0430 + $0)!) })]
        let a = LipTrainingQueue(pools: big, done: [], seed: 42).items
        XCTAssertEqual(a, LipTrainingQueue(pools: big, done: [], seed: 42).items)
        XCTAssertNotEqual(a, LipTrainingQueue(pools: big, done: [], seed: 43).items)
        XCTAssertEqual(Set(a), Set(big[0]), "перемешаны те же фразы")
    }

    func testAdvanceSkipRequeueAndPushFront() {
        var queue = LipTrainingQueue(pools: [pool(.work, ["а б в", "г д е", "ж з и", "к л м", "н о п"])],
                                     done: [], seed: 0)
        let order = queue.items
        queue.skip()
        XCTAssertEqual(queue.items, Array(order.dropFirst()) + [order[0]])

        let recorded = queue.current!
        queue.advance()
        XCTAssertFalse(queue.items.contains(recorded))

        queue.requeue(recorded)
        XCTAssertEqual(queue.items.firstIndex(of: recorded), 3)

        var short = LipTrainingQueue(pools: [pool(.work, ["а б в"])], done: [], seed: 0)
        short.requeue(recorded)
        XCTAssertEqual(short.items.last, recorded, "в короткой очереди — в конец")

        queue.pushFront(order[1])
        XCTAssertEqual(queue.current, order[1])
    }

    func testEmptyQueue() {
        var queue = LipTrainingQueue(pools: [[], []], done: [], seed: 0)
        XCTAssertNil(queue.current)
        queue.advance()
        queue.skip()
        XCTAssertEqual(queue.count, 0)
    }
}
