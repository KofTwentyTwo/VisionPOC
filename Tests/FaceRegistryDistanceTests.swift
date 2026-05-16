import XCTest
@testable import VisionPOC

/// Tests for `FaceRegistry`. The actual face-matching paths require a
/// `VNFeaturePrintObservation`, which can only be produced by running a
/// real Vision request against an image — i.e. it can't be synthesized in a
/// unit test without fixtures and a full Vision pipeline. So this file is
/// intentionally light:
///
/// - Verify the registry initializes without crashing when no `faces.json`
///   exists on disk (the loadFromDisk path is a no-op when the file is
///   missing).
/// - Verify `enrolledNames()` is empty on a fresh-but-empty registry, or
///   at least returns a stable sorted array.
/// - Verify the threshold property round-trips through `Theme.Performance`.
///
/// Deeper coverage of the match logic would require either a stored set of
/// pre-computed feature prints (binary fixtures) or refactoring the
/// distance computation out of the Vision-coupled call site. Neither is in
/// scope for the unit-test POC.
final class FaceRegistryDistanceTests: XCTestCase {
    func testRegistryInitDoesNotCrashOnMissingFile() {
        // Init triggers loadFromDisk(); if faces.json doesn't exist it
        // should be a silent no-op.
        let registry = FaceRegistry()
        _ = registry.enrolledNames()
    }

    func testEnrolledNamesIsSorted() {
        let registry = FaceRegistry()
        let names = registry.enrolledNames()
        XCTAssertEqual(names, names.sorted(), "enrolledNames should be sorted")
    }

    func testMatchThresholdRoundTripsThroughTheme() {
        let registry = FaceRegistry()
        let original = registry.matchThreshold
        registry.matchThreshold = 0.42
        XCTAssertEqual(registry.matchThreshold, 0.42, accuracy: 1e-6)
        // restore so we don't leak state into other tests
        registry.matchThreshold = original
    }

    func testForgetUnknownNameIsNoOp() {
        let registry = FaceRegistry()
        let before = registry.enrolledNames()
        registry.forget(name: "__definitely_not_enrolled__")
        let after = registry.enrolledNames()
        XCTAssertEqual(before, after)
    }
}
