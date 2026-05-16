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

    /// Per-chirality finger entries time out after this many seconds without
    /// a fresh `recordFingers` write. Without this, a hand that leaves the
    /// frame leaves a stale "Left: 3 fingers" in the Status panel forever.
    private static let fingerStaleSeconds: TimeInterval = 1.2

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
                // FingerCounter is the authoritative writer for finger counts
                // via `recordFingers(chirality:count:at:)`. The bus event is
                // just a notification — don't shadow-write an "unknown" entry
                // here, that's how the duplicate-row bug crept in.
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

    /// Called by the FingerCounter (the sole authoritative writer for finger
    /// counts) on each detection cycle.
    func recordFingers(chirality: String, count: Int, at time: Date) {
        os_unfair_lock_lock(&lock)
        _snapshot.fingerCounts[chirality] = count
        _snapshot.fingerUpdatedAt = time
        _version &+= 1
        os_unfair_lock_unlock(&lock)
    }

    /// Called by the FingerCounter at the END of each detection cycle (after
    /// it has finished publishing every hand it saw this frame). Anything
    /// that wasn't refreshed within the staleness window gets pruned so the
    /// Status panel reflects only currently-visible hands.
    func ageFingerEntries(currentSeen: Set<String>, at time: Date) {
        os_unfair_lock_lock(&lock)
        var changed = false
        for key in Array(_snapshot.fingerCounts.keys) where !currentSeen.contains(key) {
            // Drop if it hasn't been touched recently. We can't store
            // per-entry timestamps without bloating the struct, so use the
            // single fingerUpdatedAt as a global staleness proxy: if a
            // chirality wasn't seen this cycle AND we haven't seen any hand
            // for staleSeconds, drop it.
            if let last = _snapshot.fingerUpdatedAt,
               time.timeIntervalSince(last) > CurrentStateStore.fingerStaleSeconds {
                _snapshot.fingerCounts.removeValue(forKey: key)
                changed = true
            }
        }
        if changed {
            _version &+= 1
        }
        os_unfair_lock_unlock(&lock)
    }

    /// Clears every per-chirality finger entry. Used when there are zero hand
    /// observations this cycle.
    func clearFingers() {
        os_unfair_lock_lock(&lock)
        if !_snapshot.fingerCounts.isEmpty {
            _snapshot.fingerCounts.removeAll()
            _version &+= 1
        }
        os_unfair_lock_unlock(&lock)
    }
}
