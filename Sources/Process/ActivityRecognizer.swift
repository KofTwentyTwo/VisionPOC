import Foundation
import CoreGraphics

/// Inspects body `PoseDetection`s and emits coarse activity events on the
/// shared DetectionEventBus. Heuristics over normalized [0..1] image-space
/// joint positions (origin bottom-left, so larger y = higher in the scene).
///
/// Joint extraction: PoseDetection only carries an unordered `points` array
/// without name labels, so we approximate landmark positions from positional
/// statistics:
///   - "root" / hip ≈ vertical median of the joint cluster
///   - "neck" / upper-body ≈ near-top y of the joint cluster
///   - "nose" ≈ topmost y
///   - "wrists" ≈ the points farthest from the body's central vertical axis
///     among the upper half
///
/// Throttle: one emit per activity per 5 seconds.
final class ActivityRecognizer: @unchecked Sendable {
    private let bus: DetectionEventBus

    private var lock = os_unfair_lock_s()
    private var lastEmittedAt: [String: Date] = [:]
    private let throttleInterval: TimeInterval = 5.0

    init(bus: DetectionEventBus = .shared) {
        self.bus = bus
    }

    /// Called by ObjectDetector at the end of each detect-and-bootstrap pass
    /// with the freshly-computed body-pose snapshots.
    func process(bodyPoses: [PoseDetection]) {
        for pose in bodyPoses where pose.kind == .body {
            evaluate(pose: pose)
        }
    }

    private func evaluate(pose: PoseDetection) {
        let points = pose.points
        guard points.count >= 5 else { return }

        let ys = points.map { Float($0.y) }
        let xs = points.map { Float($0.x) }

        let minY = ys.min() ?? 0
        let maxY = ys.max() ?? 0
        // Pseudo "root" ≈ vertical center of the body cluster; "neck" ≈ near
        // the top; "nose" ≈ the topmost joint.
        let rootY = (minY + maxY) * 0.5
        let neckY = (minY + maxY * 3) / 4.0
        let noseY = maxY

        // ---- standing ----
        if rootY < 0.3 && (neckY - rootY) > 0.3 {
            let strength = min(1.0, (neckY - rootY - 0.3) / 0.3 + 0.3)
            emit("standing", confidence: max(0, min(1, strength)))
        }

        // ---- sitting ----
        if rootY >= 0.3 && rootY <= 0.5 {
            // Confidence peaks in the middle of the band, tapers at edges.
            let center: Float = 0.4
            let strength = 1.0 - abs(rootY - center) / 0.1
            emit("sitting", confidence: max(0, min(1, strength)))
        }

        // ---- crouching ----
        if rootY > 0.5 && neckY < 0.7 {
            let strength = min(1.0, (rootY - 0.5) / 0.3)
            emit("crouching", confidence: max(0, min(1, strength)))
        }

        // ---- hand_raised: any joint above the nose ----
        // Wrists aren't tagged in our point set, but if *any* keypoint is
        // above the inferred nose y (which is already the topmost), the
        // rule can't fire — so instead we look for a wrist-like point: a
        // joint among the top-quartile y values that's *also* an extremum
        // in x. The wrist is usually farthest from the body's vertical axis.
        let bodyCenterX = (xs.reduce(0, +)) / Float(xs.count)
        let topQuartileThreshold: Float = noseY - 0.10
        let upperPoints = zip(xs, ys).filter { $0.1 >= topQuartileThreshold }
        let wristCandidate = upperPoints.max(by: { abs($0.0 - bodyCenterX) < abs($1.0 - bodyCenterX) })
        if let (wx, wy) = wristCandidate {
            // A "raised hand" means a joint that's near or above nose y and
            // displaced laterally from the body's centerline.
            let lateralOffset = abs(wx - bodyCenterX)
            if wy >= noseY - 0.02 && lateralOffset > 0.10 {
                let strength = min(1.0, (lateralOffset - 0.10) / 0.20 + 0.3)
                emit("hand_raised", confidence: max(0, min(1, strength)))
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
        bus.emit(.activityDetected(activity: name, confidence: confidence))
    }
}
