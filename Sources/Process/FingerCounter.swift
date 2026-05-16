import Foundation
import Vision
import CoreGraphics
import os

/// Counts extended fingers on each detected hand and emits a
/// `gestureDetected(gesture: "fingers_N", ...)` event for that count.
///
/// "Extended" definition:
/// - For index / middle / ring / little: the tip joint must be farther from
///   the wrist (Euclidean distance) than the MCP (base) joint. A relaxed
///   threshold (1.25× the MCP-to-wrist distance) avoids false positives from
///   partially-curled fingers.
/// - The thumb is special: its tip is largely lateral to the palm, so we
///   measure the tip's perpendicular offset from the wrist→middleMCP axis.
///   If it sticks out >0.04 normalized units, count it as extended.
///
/// Per-hand confidence: average confidence of the joints we read.
/// Throttle: same gesture count not emitted more than once per 1.5 seconds.
final class FingerCounter: @unchecked Sendable {
    private let bus: DetectionEventBus
    private var lock = os_unfair_lock_s()
    private var lastEmit: [String: Date] = [:]
    private let throttle: TimeInterval = 1.5

    init(bus: DetectionEventBus = .shared) {
        self.bus = bus
    }

    func analyze(_ hands: [VNHumanHandPoseObservation]) {
        for hand in hands {
            guard let summary = countExtended(hand: hand) else { continue }
            emitIfFresh(count: summary.count, confidence: summary.confidence)
        }
    }

    private struct HandSummary {
        let count: Int
        let confidence: Float
    }

    private func countExtended(hand: VNHumanHandPoseObservation) -> HandSummary? {
        guard let pointsByGroup = try? hand.recognizedPoints(.all) else { return nil }

        // Wrist anchor.
        guard let wrist = pointsByGroup[.wrist], wrist.confidence > 0.3 else { return nil }

        var extendedCount = 0
        var confidenceSum: Float = 0
        var confidenceN: Int = 0

        // Helper: read a joint by name with a minimum confidence.
        func point(_ name: VNHumanHandPoseObservation.JointName) -> VNRecognizedPoint? {
            guard let p = pointsByGroup[name], p.confidence > 0.3 else { return nil }
            confidenceSum += p.confidence
            confidenceN += 1
            return p
        }

        // 4-finger rule: tip is farther from wrist than the MCP joint by >1.25×.
        func isFingerExtended(tip: VNHumanHandPoseObservation.JointName,
                              mcp: VNHumanHandPoseObservation.JointName) -> Bool {
            guard let t = point(tip), let m = point(mcp) else { return false }
            let dTip = distance(t.location, wrist.location)
            let dMcp = distance(m.location, wrist.location)
            return dTip > dMcp * 1.25
        }

        if isFingerExtended(tip: .indexTip, mcp: .indexMCP)   { extendedCount += 1 }
        if isFingerExtended(tip: .middleTip, mcp: .middleMCP) { extendedCount += 1 }
        if isFingerExtended(tip: .ringTip, mcp: .ringMCP)     { extendedCount += 1 }
        if isFingerExtended(tip: .littleTip, mcp: .littleMCP) { extendedCount += 1 }

        // Thumb: measure lateral offset from the wrist→middleMCP axis.
        if let thumbTip = point(.thumbTip),
           let middleMcp = point(.middleMCP) {
            let axisStart = wrist.location
            let axisEnd = middleMcp.location
            let perp = perpendicularDistance(point: thumbTip.location,
                                             lineStart: axisStart,
                                             lineEnd: axisEnd)
            if perp > 0.045 { extendedCount += 1 }
        }

        let confidence: Float = confidenceN > 0 ? confidenceSum / Float(confidenceN) : 0
        return HandSummary(count: extendedCount, confidence: confidence)
    }

    private func emitIfFresh(count: Int, confidence: Float) {
        let key = "fingers_\(count)"
        let now = Date()
        os_unfair_lock_lock(&lock)
        if let last = lastEmit[key], now.timeIntervalSince(last) < throttle {
            os_unfair_lock_unlock(&lock)
            return
        }
        lastEmit[key] = now
        os_unfair_lock_unlock(&lock)
        bus.emit(.gestureDetected(gesture: key, confidence: confidence))
        LogStream.shared.log("fingers: \(count) (conf \(String(format: "%.2f", confidence)))",
                             level: .debug, source: .detect)
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = a.x - b.x
        let dy = a.y - b.y
        return (dx * dx + dy * dy).squareRoot()
    }

    /// Perpendicular distance from `point` to the infinite line through
    /// `lineStart` and `lineEnd`. Returns 0 if the line is degenerate.
    private func perpendicularDistance(point: CGPoint, lineStart: CGPoint, lineEnd: CGPoint) -> CGFloat {
        let dx = lineEnd.x - lineStart.x
        let dy = lineEnd.y - lineStart.y
        let denom = (dx * dx + dy * dy).squareRoot()
        guard denom > 0 else { return 0 }
        let numer = abs(dy * point.x - dx * point.y + lineEnd.x * lineStart.y - lineEnd.y * lineStart.x)
        return numer / denom
    }
}
