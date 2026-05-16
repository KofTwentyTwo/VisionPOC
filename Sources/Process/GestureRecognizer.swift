import Foundation
import Vision
import CoreGraphics

/// Inspects hand `PoseDetection`s and emits discrete gesture events on the
/// shared DetectionEventBus. Heuristics-based — no ML model — using the
/// joint-name keys produced by `ObjectDetector.makeHandPose(...)`.
///
/// All gesture rules operate in Vision's normalized [0..1] image space, origin
/// bottom-left. "Above" therefore means a larger y value.
///
/// Throttle: one emit per gesture name per 2 seconds, even if the rule keeps
/// firing on consecutive frames.
final class GestureRecognizer: @unchecked Sendable {
    private let bus: DetectionEventBus

    private var lock = os_unfair_lock_s()
    private var lastEmittedAt: [String: Date] = [:]
    private let throttleInterval: TimeInterval = 2.0

    init(bus: DetectionEventBus = .shared) {
        self.bus = bus
    }

    /// Called by ObjectDetector at the end of each detect-and-bootstrap pass
    /// with the freshly-computed hand-pose snapshots.
    func process(handPoses: [PoseDetection]) {
        for pose in handPoses where pose.kind == .hand {
            evaluate(pose: pose)
        }
    }

    // MARK: - Rule evaluation

    private func evaluate(pose: PoseDetection) {
        // The pose builder discards segments but keeps joints in
        // `points` — there's no joint-name-keyed dict on PoseDetection.
        // Reconstruct an approximate joint dict by clustering points to the
        // nearest expected fingertip/MCP relative ordering. To keep this
        // robust (without re-running Vision), we instead read from
        // `pose.points` and apply rules that don't require named joints —
        // looking at the *distribution* of y-values and palm-center proximity.
        //
        // For most rules we only need:
        //   - tip set: the 5 highest-y points (assumes hand is roughly upright)
        //   - base set: the 5 lowest-y points among the keypoints
        //   - palm center: average of the 5 lowest-y points
        //
        // This is approximate but sufficient for the gesture vocabulary —
        // discrete classification with 2s throttling absorbs occasional
        // misfires.

        let points = pose.points
        // Need at least a few joints to reason about. A typical hand pose
        // produces 15–21 keypoints; below 8 we don't bother.
        guard points.count >= 8 else { return }

        let sortedByY = points.sorted { $0.y < $1.y }
        let lowerHalf = Array(sortedByY.prefix(points.count / 2))
        let upperHalf = Array(sortedByY.suffix(points.count / 2))

        let palmCenter = centroid(of: lowerHalf)

        // Heuristic "fingertip set": the 5 highest-y points. Heuristic "base
        // set": the 5 lowest-y points.
        let tipCount = min(5, upperHalf.count)
        let baseCount = min(5, lowerHalf.count)
        let tips = Array(upperHalf.suffix(tipCount))
        let bases = Array(lowerHalf.prefix(baseCount))
        guard tips.count >= 4, bases.count >= 4 else { return }

        let tipYs = tips.map { Float($0.y) }
        let baseYs = bases.map { Float($0.y) }

        // ---- fist: all tips close to palm center ----
        let distancesFromPalm = tips.map { CGFloat(hypot(Double($0.x - palmCenter.x), Double($0.y - palmCenter.y))) }
        let maxTipPalmDist = distancesFromPalm.max() ?? .greatestFiniteMagnitude
        if maxTipPalmDist < 0.08 {
            let strength = Float(0.08 - maxTipPalmDist) / 0.08
            emit("fist", confidence: clamp01(strength))
        }

        // ---- open_hand: every "tip" is above every "base" ----
        let minTipY = tipYs.min() ?? 0
        let maxBaseY = baseYs.max() ?? 1
        let spread = minTipY - maxBaseY
        if spread > 0.05 && maxTipPalmDist > 0.10 {
            let strength = min(1.0, spread / 0.25)
            emit("open_hand", confidence: clamp01(strength))
        }

        // ---- thumbs_up: a single tip well above all other tips ----
        let sortedTipsByY = tipYs.sorted()
        if sortedTipsByY.count >= 2 {
            let topTip = sortedTipsByY[sortedTipsByY.count - 1]
            let nextTip = sortedTipsByY[sortedTipsByY.count - 2]
            let gap = topTip - nextTip
            // Plus the other 3 (or 4) tips should be bunched (not spread): if
            // 3 tips are within 0.05 of each other and the top tip is +0.05
            // above them, call it thumbs_up.
            let others = Array(sortedTipsByY.prefix(sortedTipsByY.count - 1))
            let othersSpread = (others.max() ?? 0) - (others.min() ?? 0)
            if gap > 0.05 && othersSpread < 0.05 {
                let strength = min(1.0, gap / 0.20)
                emit("thumbs_up", confidence: clamp01(strength))
            }
        }

        // ---- pointing: exactly one tip stands tall above all others ----
        // Similar to thumbs_up but the "extended" tip should be far from the
        // palm center, and the other tips should be near it.
        if sortedTipsByY.count >= 4 {
            let topTip = sortedTipsByY[sortedTipsByY.count - 1]
            let others = Array(sortedTipsByY.prefix(sortedTipsByY.count - 1))
            let othersMax = others.max() ?? 0
            let extension_ = topTip - othersMax
            // Also require: the tip farthest from palm is much farther than
            // the other tips.
            let distSorted = distancesFromPalm.sorted()
            if distSorted.count >= 2 {
                let topDist = distSorted[distSorted.count - 1]
                let nextDist = distSorted[distSorted.count - 2]
                if extension_ > 0.07 && topDist > 0.12 && (topDist - nextDist) > 0.04 {
                    let strength = min(1.0, Float(topDist - nextDist) / 0.15)
                    emit("pointing", confidence: clamp01(strength))
                }
            }
        }

        // ---- peace: two tips extended, others curled ----
        if tipYs.count >= 5 {
            let s = tipYs.sorted()
            let top2 = Array(s.suffix(2))
            let bot3 = Array(s.prefix(3))
            let top2Min = top2.min() ?? 0
            let bot3Max = bot3.max() ?? 0
            let separation = top2Min - bot3Max
            // Also: the top 2 should be near each other (parallel fingers).
            let top2Spread = (top2.max() ?? 0) - (top2.min() ?? 0)
            if separation > 0.05 && top2Spread < 0.05 {
                let strength = min(1.0, separation / 0.15)
                emit("peace", confidence: clamp01(strength))
            }
        }
    }

    private func emit(_ name: String, confidence: Float) {
        let now = Date()
        os_unfair_lock_lock(&lock)
        if let prev = lastEmittedAt[name], now.timeIntervalSince(prev) < throttleInterval {
            os_unfair_lock_unlock(&lock)
            return
        }
        lastEmittedAt[name] = now
        os_unfair_lock_unlock(&lock)
        bus.emit(.gestureDetected(gesture: name, confidence: confidence))
    }

    private func centroid(of pts: [CGPoint]) -> CGPoint {
        guard !pts.isEmpty else { return .zero }
        var sx: CGFloat = 0
        var sy: CGFloat = 0
        for p in pts { sx += p.x; sy += p.y }
        return CGPoint(x: sx / CGFloat(pts.count), y: sy / CGFloat(pts.count))
    }

    private func clamp01(_ x: Float) -> Float {
        return max(0, min(1, x))
    }
}
