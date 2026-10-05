import QuartzCore
import XCTest
@testable import DOKA

/// Почтовый ящик кадров зеркала: `visionQueue` кладёт, главный поток забирает.
///
/// Зачем: картинка и маска одного кадра должны показываться вместе и
/// свежими. Если main не успел — показывается последний кадр, а не очередь
/// старых; кадр прошлого дубля или под старый размер окна не показывается
/// никогда (картинка растянулась бы, маска осталась бы в старых точках); а
/// пересоздание вью не должно отписывать новую вью руками старой.
@MainActor
final class LipMirrorFeedTests: XCTestCase {

    private let target = LipMirrorTarget(size: CGSize(width: 224, height: 120), scale: 2, reduceMotion: false)
    private let take = UUID()

    /// Картинка 1×1 — ящику её содержимое безразлично.
    private static let image = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                         space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)!.makeImage()!

    private func frame(take: UUID? = nil, target: LipMirrorTarget? = nil, host: Double = CACurrentMediaTime())
        -> LipMirrorFrame {
        LipMirrorFrame(take: take ?? self.take, target: target ?? self.target, host: host, image: Self.image,
                       paths: nil)
    }

    /// Прокрутить главную очередь: всё, что `post` поставил раньше, доставлено.
    private func flush() {
        let done = expectation(description: "главная очередь")
        DispatchQueue.main.async { done.fulfill() }
        wait(for: [done], timeout: 2)
    }

    /// Подписка, которая копит доставленное (nil — «пусто»).
    private func subscribe(_ feed: LipMirrorFeed, target: LipMirrorTarget? = nil) -> (UUID, () -> [LipMirrorFrame?]) {
        var received: [LipMirrorFrame?] = []
        let owner = feed.attach(target: target ?? self.target) { received.append($0) }
        return (owner, { received })
    }

    func testLatestFrameWins() {
        let feed = LipMirrorFeed()
        let (_, received) = subscribe(feed)
        feed.begin(take: take)
        XCTAssertEqual(received().count, 1)
        XCTAssertNil(received()[0])

        let first = frame(host: 1), second = frame(host: 2)
        feed.post(first)
        feed.post(second)
        flush()
        XCTAssertEqual(received().count, 2)
        XCTAssertEqual(received().last??.host, 2)
        XCTAssertEqual(feed.latencySummary(take: take)?.count, 1)

        // Доставка снова возможна: флаг «запланировано» снят.
        feed.post(frame(host: 3))
        flush()
        XCTAssertEqual(received().last??.host, 3)
    }

    func testFrameOfAnotherTakeIsDropped() {
        let feed = LipMirrorFeed()
        let (_, received) = subscribe(feed)
        feed.begin(take: take)
        feed.post(frame(take: UUID()))
        flush()
        XCTAssertEqual(received().count, 1, "кадр чужого дубля не доставляется")

        // Висящий кадр прошлого дубля выбрасывается сменой дубля.
        feed.post(frame())
        let next = UUID()
        feed.begin(take: next)
        flush()
        XCTAssertEqual(received().count, 2)
        XCTAssertNil(received().last!)
        XCTAssertNil(feed.latencySummary(take: take))
    }

    func testFrameForOldTargetIsSkipped() {
        let feed = LipMirrorFeed()
        let (owner, received) = subscribe(feed)
        feed.begin(take: take)
        feed.post(frame())
        let bigger = LipMirrorTarget(size: CGSize(width: 300, height: 160), scale: 2, reduceMotion: false)
        feed.update(target: bigger, owner: owner)
        XCTAssertEqual(feed.target, bigger)
        flush()
        XCTAssertEqual(received().count, 1, "кадр под старый размер окна не показывается")

        feed.post(frame(target: bigger))
        flush()
        XCTAssertEqual(received().last??.target, bigger)
    }

    func testDetachOnlyRemovesOwnSubscription() {
        let feed = LipMirrorFeed()
        let (old, oldReceived) = subscribe(feed)
        let (fresh, freshReceived) = subscribe(feed)
        feed.begin(take: take)

        // Старая вью уходит позже, чем подписалась новая.
        let other = LipMirrorTarget(size: CGSize(width: 10, height: 10), scale: 1, reduceMotion: true)
        feed.update(target: other, owner: old)
        feed.detach(owner: old)
        XCTAssertEqual(feed.target, target)

        feed.post(frame())
        flush()
        XCTAssertEqual(oldReceived().count, 0)
        XCTAssertEqual(freshReceived().count, 2)

        feed.detach(owner: fresh)
        XCTAssertNil(feed.target, "без окна зеркало не считается")
        feed.post(frame())
        flush()
        XCTAssertEqual(freshReceived().count, 2)
    }

    func testBeginSendsEmptyFrame() {
        let feed = LipMirrorFeed()
        let (_, received) = subscribe(feed)
        feed.begin(take: take)
        feed.post(frame())
        flush()
        feed.begin(take: UUID())
        XCTAssertEqual(received().count, 3)
        XCTAssertNil(received()[0])
        XCTAssertNotNil(received()[1])
        XCTAssertNil(received()[2], "новый дубль начинается с пустого зеркала")
    }

    func testEndDropsLateFrames() {
        let feed = LipMirrorFeed()
        let (_, received) = subscribe(feed)
        feed.begin(take: take)
        feed.post(frame(host: 1))
        flush()

        // Кадр, ушедший до конца дубля, но не доставленный, и кадр после.
        feed.post(frame(host: 2))
        feed.end()
        feed.post(frame(host: 3))
        flush()
        XCTAssertEqual(received().count, 2, "картинка остаётся последней показанной, без «пусто»")
        XCTAssertEqual(received().last??.host, 1)
        XCTAssertEqual(feed.latencySummary(take: take)?.count, 1, "латентность дубля переживает конец")
    }
}
