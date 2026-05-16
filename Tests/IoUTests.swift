import XCTest
import CoreGraphics

/// Tests for the intersection-over-union algorithm used by ObjectDetector to
/// match new detections against existing tracks.
///
/// The production implementation is `private func iou(_:_:)` in
/// `Sources/Process/ObjectDetector.swift` (around line 649). Because it is
/// private and the surface area is one tiny pure function, we mirror the
/// algorithm here verbatim and assert behavior against the mirror. This
/// gives us regression coverage of the IoU contract; drift between the
/// mirror and production would not be caught by this test, so the
/// production source carries a comment pointing here and vice versa.
///
/// MIRROR of Sources/Process/ObjectDetector.swift:iou — keep in sync.
final class IoUTests: XCTestCase {
    private func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let inter = a.intersection(b)
        if inter.isNull || inter.isEmpty { return 0 }
        let interArea = inter.width * inter.height
        let union = a.width * a.height + b.width * b.height - interArea
        guard union > 0 else { return 0 }
        return interArea / union
    }

    func testIdenticalRectsReturnOne() {
        let r = CGRect(x: 0.2, y: 0.2, width: 0.4, height: 0.4)
        XCTAssertEqual(iou(r, r), 1.0, accuracy: 1e-9)
    }

    func testDisjointRectsReturnZero() {
        let a = CGRect(x: 0, y: 0, width: 0.2, height: 0.2)
        let b = CGRect(x: 0.5, y: 0.5, width: 0.2, height: 0.2)
        XCTAssertEqual(iou(a, b), 0.0, accuracy: 1e-9)
    }

    func testPartialOverlapKnownValue() {
        // Two 0.5x0.5 squares overlapping in a 0.25x0.25 quadrant.
        // intersection area = 0.0625, union = 0.25 + 0.25 - 0.0625 = 0.4375
        // iou = 0.0625 / 0.4375 = 1/7
        let a = CGRect(x: 0, y: 0, width: 0.5, height: 0.5)
        let b = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        XCTAssertEqual(iou(a, b), 1.0 / 7.0, accuracy: 1e-9)
    }

    func testZeroAreaInputReturnsZero() {
        let a = CGRect(x: 0, y: 0, width: 0, height: 0)
        let b = CGRect(x: 0, y: 0, width: 0.5, height: 0.5)
        XCTAssertEqual(iou(a, b), 0.0, accuracy: 1e-9)
    }

    func testRectFullyInsideAnother() {
        // Small rect entirely within large rect:
        // inter = small area = 0.04, union = 1.0 + 0.04 - 0.04 = 1.0
        // iou = 0.04
        let big = CGRect(x: 0, y: 0, width: 1.0, height: 1.0)
        let small = CGRect(x: 0.3, y: 0.3, width: 0.2, height: 0.2)
        XCTAssertEqual(iou(big, small), 0.04, accuracy: 1e-9)
    }
}
