import XCTest
import CoreGraphics

/// Tests for the aspect-fit letterboxing math used by Renderer to keep the
/// camera feed square with its source even when the pane cell isn't.
///
/// Production lives in `Sources/Render/Renderer.swift` as
/// `private func aspectFitRect(into:sourceAspect:)`. Same caveat as
/// `IoUTests`: we mirror the algorithm here to avoid changing the production
/// access level just to test five lines of arithmetic.
///
/// MIRROR of Sources/Render/Renderer.swift:aspectFitRect — keep in sync.
final class AspectFitTests: XCTestCase {
    private func aspectFitRect(into pane: CGRect, sourceAspect: CGFloat) -> CGRect {
        guard pane.width > 0, pane.height > 0, sourceAspect > 0 else { return pane }
        let paneAspect = pane.width / pane.height
        if abs(paneAspect - sourceAspect) < 0.001 {
            return pane
        }
        var width = pane.width
        var height = pane.height
        if paneAspect > sourceAspect {
            width = pane.height * sourceAspect
        } else {
            height = pane.width / sourceAspect
        }
        let originX = pane.origin.x + (pane.width - width) * 0.5
        let originY = pane.origin.y + (pane.height - height) * 0.5
        return CGRect(x: originX, y: originY, width: width, height: height)
    }

    func testSameAspectReturnsPane() {
        let pane = CGRect(x: 10, y: 20, width: 320, height: 180)
        let result = aspectFitRect(into: pane, sourceAspect: 320.0 / 180.0)
        XCTAssertEqual(result, pane)
    }

    func testPaneWiderThanSourceShrinksWidth() {
        // Pane is 4:1, source is 1:1 — height matches pane, width = 100
        let pane = CGRect(x: 0, y: 0, width: 400, height: 100)
        let result = aspectFitRect(into: pane, sourceAspect: 1.0)
        XCTAssertEqual(result.height, 100, accuracy: 1e-9)
        XCTAssertEqual(result.width, 100, accuracy: 1e-9)
        // Centered horizontally: (400 - 100) / 2 = 150
        XCTAssertEqual(result.origin.x, 150, accuracy: 1e-9)
        XCTAssertEqual(result.origin.y, 0, accuracy: 1e-9)
    }

    func testPaneTallerThanSourceShrinksHeight() {
        // Pane is 1:4, source is 1:1 — width matches pane, height = 100
        let pane = CGRect(x: 0, y: 0, width: 100, height: 400)
        let result = aspectFitRect(into: pane, sourceAspect: 1.0)
        XCTAssertEqual(result.width, 100, accuracy: 1e-9)
        XCTAssertEqual(result.height, 100, accuracy: 1e-9)
        XCTAssertEqual(result.origin.x, 0, accuracy: 1e-9)
        // Centered vertically: (400 - 100) / 2 = 150
        XCTAssertEqual(result.origin.y, 150, accuracy: 1e-9)
    }

    func testZeroWidthPaneReturnsPane() {
        let pane = CGRect(x: 5, y: 5, width: 0, height: 100)
        XCTAssertEqual(aspectFitRect(into: pane, sourceAspect: 1.0), pane)
    }

    func testZeroHeightPaneReturnsPane() {
        let pane = CGRect(x: 5, y: 5, width: 100, height: 0)
        XCTAssertEqual(aspectFitRect(into: pane, sourceAspect: 1.0), pane)
    }

    func testZeroSourceAspectReturnsPane() {
        let pane = CGRect(x: 5, y: 5, width: 100, height: 100)
        XCTAssertEqual(aspectFitRect(into: pane, sourceAspect: 0.0), pane)
    }
}
