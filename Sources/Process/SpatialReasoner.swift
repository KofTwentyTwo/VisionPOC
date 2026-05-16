import Foundation
import CoreGraphics

/// Identifies meaningful pairwise spatial relationships between detections
/// (and hand-pose wrists vs. object centers) and emits `spatialRelation`
/// events on the shared DetectionEventBus.
///
/// Relations:
///   - `near`    — bounding-box centers within 0.15 normalized distance
///   - `above`   — B's bottom edge is above A's top edge; centers within 0.3 horizontal
///   - `inside`  — A is fully contained within B (e.g. FACE inside PERSON)
///   - `holding` — a hand-pose wrist is within 0.05 of an object's center
///
/// Throttle: one emit per (subject, relation, object) triple per 10 seconds.
/// "Holding" pairs the hand with the closest object label by class name.
final class SpatialReasoner: @unchecked Sendable {
    private let bus: DetectionEventBus

    private var lock = os_unfair_lock_s()
    private var lastEmittedAt: [String: Date] = [:]
    private let throttleInterval: TimeInterval = 10.0

    init(bus: DetectionEventBus = .shared) {
        self.bus = bus
    }

    /// Called from ObjectDetector after each detect-and-bootstrap pass.
    func process(detections: [Detection], handPoses: [PoseDetection]) {
        // Pairwise relations among detections.
        let n = detections.count
        if n >= 2 {
            for i in 0..<n {
                for j in 0..<n where j != i {
                    let a = detections[i]
                    let b = detections[j]
                    evaluatePair(a: a, b: b)
                }
            }
        }

        // Holding: hand wrist near a detection center.
        if !handPoses.isEmpty && !detections.isEmpty {
            for pose in handPoses where pose.kind == .hand {
                evaluateHolding(pose: pose, detections: detections)
            }
        }
    }

    // MARK: - Pair-relation rules

    private func evaluatePair(a: Detection, b: Detection) {
        let ac = center(of: a.rect)
        let bc = center(of: b.rect)
        let dx = ac.x - bc.x
        let dy = ac.y - bc.y
        let dist = sqrt(dx * dx + dy * dy)

        // near
        if dist < 0.15 {
            emit(subject: a.label, relation: "near", object: b.label)
        }

        // above (B above A)
        let bBottom = b.rect.minY
        let aTop = a.rect.maxY
        if bBottom > aTop && abs(dx) < 0.3 {
            emit(subject: b.label, relation: "above", object: a.label)
        }

        // inside (A inside B)
        if b.rect.contains(a.rect) && a.rect != b.rect {
            emit(subject: a.label, relation: "inside", object: b.label)
        }
    }

    private func evaluateHolding(pose: PoseDetection, detections: [Detection]) {
        // The pose's "wrist" isn't named, but the lowest-y points cluster near
        // the wrist when a hand is held out. Use each unique pose point as a
        // candidate wrist location — the rule only fires if the closest one is
        // within 0.05 of an object's center, which is a tight bar.
        for p in pose.points {
            for det in detections {
                let c = center(of: det.rect)
                let dx = c.x - p.x
                let dy = c.y - p.y
                let dist = sqrt(dx * dx + dy * dy)
                if dist < 0.05 {
                    emit(subject: "HAND", relation: "holding", object: det.label)
                }
            }
        }
    }

    private func center(of r: CGRect) -> CGPoint {
        return CGPoint(x: r.midX, y: r.midY)
    }

    private func emit(subject: String, relation: String, object: String) {
        // Triple key for per-triple throttling.
        let key = "\(subject)|\(relation)|\(object)"
        let now = Date()
        os_unfair_lock_lock(&lock)
        if let prev = lastEmittedAt[key], now.timeIntervalSince(prev) < throttleInterval {
            os_unfair_lock_unlock(&lock)
            return
        }
        lastEmittedAt[key] = now
        os_unfair_lock_unlock(&lock)
        bus.emit(.spatialRelation(subject: subject, relation: relation, object: object))
    }
}
