import XCTest
@testable import VisionPOC

/// Tests for the in-memory ring buffer behavior of `LogStream`. The buffer
/// is bounded at 1000 entries with FIFO eviction. The singleton's state
/// leaks across tests — we call `clear()` in setUp to make each test
/// hermetic.
final class LogStreamTests: XCTestCase {
    override func setUp() {
        super.setUp()
        LogStream.shared.clear()
    }

    func testLogAppendsEntry() {
        let before = LogStream.shared.snapshot().count
        LogStream.shared.log("hello", level: .info, source: .other)
        let after = LogStream.shared.snapshot()
        XCTAssertEqual(after.count, before + 1)
        XCTAssertEqual(after.last?.message, "hello")
    }

    func testRingBufferEvictsOldestPastCap() {
        // The cap is 1000 (see LogStream.maxEntries). Write 1500 and assert
        // we land at exactly 1000 with the tail being the most recent writes.
        for i in 0..<1500 {
            LogStream.shared.log("entry \(i)", level: .debug, source: .other)
        }
        let snap = LogStream.shared.snapshot()
        XCTAssertEqual(snap.count, 1000)
        XCTAssertEqual(snap.last?.message, "entry 1499")
        XCTAssertEqual(snap.first?.message, "entry 500")
    }

    func testVersionIsMonotonic() {
        let v0 = LogStream.shared.version
        LogStream.shared.log("a")
        let v1 = LogStream.shared.version
        LogStream.shared.log("b")
        let v2 = LogStream.shared.version
        XCTAssertGreaterThan(v1, v0)
        XCTAssertGreaterThan(v2, v1)
    }

    func testClearResetsBuffer() {
        LogStream.shared.log("a")
        LogStream.shared.log("b")
        XCTAssertFalse(LogStream.shared.snapshot().isEmpty)
        LogStream.shared.clear()
        XCTAssertTrue(LogStream.shared.snapshot().isEmpty)
    }

    func testClearBumpsVersion() {
        let v0 = LogStream.shared.version
        LogStream.shared.clear()
        XCTAssertGreaterThan(LogStream.shared.version, v0)
    }
}
