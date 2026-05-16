import XCTest
@testable import VisionPOC

/// Tests for the `DetectionEventBus` pub/sub primitive. The bus is a
/// singleton, so tokens from a previous test could be lingering — but since
/// we always emit fresh events and assert per-subscriber receipt, leakage
/// from other tests cannot fool a positive assertion. Token deinit cleanup
/// is exercised explicitly.
final class DetectionEventBusTests: XCTestCase {
    func testSubscribeReceivesEmittedEvent() {
        let received = LockedBox<String?>(nil)
        let token = DetectionEventBus.shared.subscribe { event in
            if case let .objectAppeared(label, _, _, _) = event.kind {
                received.set(label)
            }
        }
        defer { token.cancel() }

        DetectionEventBus.shared.emit(.objectAppeared(
            label: "dog",
            trackId: UUID(),
            confidence: 0.9,
            rect: .zero
        ))
        XCTAssertEqual(received.get(), "dog")
    }

    func testMultipleSubscribersAllReceive() {
        let countA = LockedBox<Int>(0)
        let countB = LockedBox<Int>(0)
        let tA = DetectionEventBus.shared.subscribe { _ in countA.set(countA.get() + 1) }
        let tB = DetectionEventBus.shared.subscribe { _ in countB.set(countB.get() + 1) }
        defer { tA.cancel(); tB.cancel() }

        DetectionEventBus.shared.emit(.textRecognized(text: "x", confidence: 1.0))
        XCTAssertEqual(countA.get(), 1)
        XCTAssertEqual(countB.get(), 1)
    }

    func testCancelRemovesHandler() {
        let count = LockedBox<Int>(0)
        let token = DetectionEventBus.shared.subscribe { _ in count.set(count.get() + 1) }
        DetectionEventBus.shared.emit(.textRecognized(text: "a", confidence: 1.0))
        XCTAssertEqual(count.get(), 1)
        token.cancel()
        DetectionEventBus.shared.emit(.textRecognized(text: "b", confidence: 1.0))
        XCTAssertEqual(count.get(), 1, "handler should not fire after cancel")
    }

    func testTokenDeinitRemovesHandler() {
        let count = LockedBox<Int>(0)
        do {
            let token = DetectionEventBus.shared.subscribe { _ in count.set(count.get() + 1) }
            _ = token // hold for the scope
            DetectionEventBus.shared.emit(.textRecognized(text: "a", confidence: 1.0))
        } // token deinit fires here, calling cancel()
        XCTAssertEqual(count.get(), 1)
        DetectionEventBus.shared.emit(.textRecognized(text: "b", confidence: 1.0))
        XCTAssertEqual(count.get(), 1, "deinit'd token should have unsubscribed")
    }
}

/// Tiny thread-safe box so handler closures (Sendable) can mutate test state
/// without tripping Swift 6's concurrency checking.
private final class LockedBox<T>: @unchecked Sendable {
    private var value: T
    private let lock = NSLock()
    init(_ initial: T) { self.value = initial }
    func get() -> T {
        lock.lock(); defer { lock.unlock() }
        return value
    }
    func set(_ newValue: T) {
        lock.lock(); defer { lock.unlock() }
        value = newValue
    }
}
