import Foundation
import os

/// Live "what does VisionPOC know right now?" view of the event bus.
///
/// Unlike `HistoryStore` (which keeps a scrolling timeline of past events),
/// `CurrentStateStore` only holds the *most recent* value per concept —
/// current expression, current activity, gestures-fired-recently, hands and
/// their finger counts. It's what the on-screen Status panel reads to show
/// "right now."
///
/// Threading: subscribes to `DetectionEventBus.shared` on its own queue. Each
/// update bumps a monotonically-increasing `version`. UI views poll
/// `snapshot()` at their own cadence.
final class CurrentStateStore: @unchecked Sendable {
    static let shared = CurrentStateStore()

    struct Snapshot: Sendable {
        var expression: String?
        var expressionAt: Date?
        var activity: String?
        var activityAt: Date?
        /// Last 6 gestures (newest first), excluding the dedicated
        /// finger/expression event names which surface elsewhere.
        var recentGestures: [(name: String, at: Date)]
        /// Per-chirality finger count from the most recent hand-pose pass.
        /// Key: "left" | "right" | "unknown". Value: 0...5.
        var fingerCounts: [String: Int]
        var fingerUpdatedAt: Date?
    }

    private var lock = os_unfair_lock_s()
    private var _version: UInt64 = 0
    private var _snapshot = Snapshot(
        expression: nil, expressionAt: nil,
        activity: nil, activityAt: nil,
        recentGestures: [],
        fingerCounts: [:], fingerUpdatedAt: nil
    )

    private var token: DetectionEventBus.Token?

    private init() {
        token = DetectionEventBus.shared.subscribe { [weak self] event in
            self?.absorb(event)
        }
    }

    var version: UInt64 {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return _version
    }

    func snapshot() -> Snapshot {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return _snapshot
    }

    private static let expressionNames: Set<String> = ["smile", "frown", "neutral_face"]
    private static let activityNames: Set<String> = ["standing", "sitting", "crouching", "hand_raised"]

    /// Synchronously absorbs a single event. Called from the bus's
    /// arbitrary-thread emit path.
    private func absorb(_ event: DetectionEvent) {
        switch event.kind {
        case .gestureDetected(let name, _):
            os_unfair_lock_lock(&lock)
            if CurrentStateStore.expressionNames.contains(name) {
                _snapshot.expression = name
                _snapshot.expressionAt = event.timestamp
            } else if name.hasPrefix("fingers_") {
                // Pull the count out of the name; chirality not in the
                // gesture event vocabulary, so default to "unknown" until
                // we get a typed event.
                let countStr = name.dropFirst("fingers_".count)
                if let count = Int(countStr) {
                    _snapshot.fingerCounts["unknown"] = count
                    _snapshot.fingerUpdatedAt = event.timestamp
                }
            } else {
                _snapshot.recentGestures.insert((name, event.timestamp), at: 0)
                if _snapshot.recentGestures.count > 6 {
                    _snapshot.recentGestures.removeLast()
                }
            }
            _version &+= 1
            os_unfair_lock_unlock(&lock)

        case .activityDetected(let name, _):
            os_unfair_lock_lock(&lock)
            _snapshot.activity = name
            _snapshot.activityAt = event.timestamp
            _version &+= 1
            os_unfair_lock_unlock(&lock)

        default:
            break  // objects/faces/text/spatial — the Status panel reads these directly from ObjectDetector
        }
    }

    /// Called by the FingerCounter (or a future per-hand publisher) to
    /// register a known chirality alongside the count.
    func recordFingers(chirality: String, count: Int, at time: Date) {
        os_unfair_lock_lock(&lock)
        _snapshot.fingerCounts[chirality] = count
        _snapshot.fingerUpdatedAt = time
        _version &+= 1
        os_unfair_lock_unlock(&lock)
    }
}
