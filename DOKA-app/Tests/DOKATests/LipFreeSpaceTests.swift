import XCTest
@testable import DOKA

/// Свободное место перед дублем губ.
///
/// Зачем: опрос тома (`volumeAvailableCapacityForImportantUsage`) — около
/// 30 мс, а на почти полном диске дольше. На главном потоке при старте КАЖДОЙ
/// диктовки это задержка до начала записи. Поэтому значение кэшируется и
/// обновляется фоном; старт диктовки только читает кэш.
final class LipFreeSpaceTests: XCTestCase {
    private func refreshed(_ space: LipFreeSpace) {
        let done = expectation(description: "refresh")
        space.refresh { done.fulfill() }
        wait(for: [done], timeout: 2)
    }

    /// Пока не опрошено — не мешаем диктовке.
    func testUnknownAllowsTake() {
        XCTAssertTrue(LipFreeSpace(probe: { 1 }).hasRoom)
    }

    func testLowSpaceRefusesTake() {
        let space = LipFreeSpace(probe: { 1_000_000_000 })
        refreshed(space)
        XCTAssertFalse(space.hasRoom)
    }

    func testEnoughSpaceAllowsTake() {
        let space = LipFreeSpace(probe: { 5_000_000_000 })
        refreshed(space)
        XCTAssertTrue(space.hasRoom)
    }

    /// Том не ответил — не мешаем диктовке.
    func testFailedProbeAllowsTake() {
        let space = LipFreeSpace(probe: { nil })
        refreshed(space)
        XCTAssertTrue(space.hasRoom)
    }

    /// Опрос — не на вызывающем потоке.
    func testProbeRunsOffCallerThread() {
        // Идентификатор, а не сам `Thread`: он Sendable, и замыкание опроса
        // может его захватить без предупреждения.
        let caller = ObjectIdentifier(Thread.current)
        let space = LipFreeSpace(probe: {
            XCTAssertNotEqual(ObjectIdentifier(Thread.current), caller)
            return 5_000_000_000
        })
        refreshed(space)
    }
}
