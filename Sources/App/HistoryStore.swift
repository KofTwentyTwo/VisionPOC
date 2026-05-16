import Foundation
import os

/// Ring buffer of recent detection events for the History viewer.
///
/// Subscribes to `DetectionEventBus.shared` once at init and converts each
/// event into a `HistoryEntry`. The viewer polls `snapshot()` at 1 Hz; the
/// store itself is thread-safe so background-thread emitters can write
/// without hopping to MainActor.
///
/// Filtering rules:
/// - `.objectRefreshed` is dropped (too noisy for history).
/// - Face events are dropped when `Theme.Performance.faceRecognitionDisabled`
///   is set (Privacy Mode). This is the privacy guarantee the App layer can
///   make on its own, independent of whether the detector honors the flag.
final class HistoryStore: @unchecked Sendable {
    static let shared = HistoryStore()

    static let capacity = 500

    private var lock = os_unfair_lock_s()
    private var buffer: [HistoryEntry] = []
    private var _version: UInt64 = 0
    private var subscription: DetectionEventBus.Token?

    private init() {
        buffer.reserveCapacity(HistoryStore.capacity)
        subscription = DetectionEventBus.shared.subscribe { [weak self] event in
            self?.ingest(event)
        }
    }

    /// Snapshot of current entries, oldest-first. Cheap copy because the
    /// store is bounded to `capacity` rows.
    func snapshot() -> [HistoryEntry] {
        os_unfair_lock_lock(&lock)
        let copy = buffer
        os_unfair_lock_unlock(&lock)
        return copy
    }

    /// Monotonically increasing counter that bumps on every append. The
    /// viewer polls this to decide whether to re-render — same pattern as
    /// `LogStream.shared.version`.
    var version: UInt64 {
        os_unfair_lock_lock(&lock)
        let v = _version
        os_unfair_lock_unlock(&lock)
        return v
    }

    func clear() {
        os_unfair_lock_lock(&lock)
        buffer.removeAll(keepingCapacity: true)
        _version &+= 1
        os_unfair_lock_unlock(&lock)
    }

    // MARK: - Ingestion

    private func ingest(_ event: DetectionEvent) {
        guard let entry = HistoryStore.translate(event) else { return }
        os_unfair_lock_lock(&lock)
        if buffer.count >= HistoryStore.capacity {
            buffer.removeFirst(buffer.count - HistoryStore.capacity + 1)
        }
        buffer.append(entry)
        _version &+= 1
        os_unfair_lock_unlock(&lock)
    }

    private static func translate(_ event: DetectionEvent) -> HistoryEntry? {
        switch event.kind {
        case .objectRefreshed:
            return nil

        case .objectAppeared(let label, _, let confidence, _):
            return HistoryEntry(
                id: UUID(),
                timestamp: event.timestamp,
                summary: "\(label.capitalized) appeared (conf \(String(format: "%.2f", confidence)))",
                category: "object"
            )

        case .objectDisappeared(let label, _):
            return HistoryEntry(
                id: UUID(),
                timestamp: event.timestamp,
                summary: "\(label.capitalized) disappeared",
                category: "object"
            )

        case .faceRecognized(let name, let distance, _):
            if Theme.Performance.faceRecognitionDisabled { return nil }
            return HistoryEntry(
                id: UUID(),
                timestamp: event.timestamp,
                summary: "\(name) recognized (dist \(String(format: "%.1f", distance)))",
                category: "face-known"
            )

        case .faceSeenUnknown:
            if Theme.Performance.faceRecognitionDisabled { return nil }
            return HistoryEntry(
                id: UUID(),
                timestamp: event.timestamp,
                summary: "Unknown face seen",
                category: "face-unknown"
            )

        case .textRecognized(let text, _):
            return HistoryEntry(
                id: UUID(),
                timestamp: event.timestamp,
                summary: "Read: \"\(text)\"",
                category: "ocr"
            )

        case .gestureDetected(let gesture, _):
            return HistoryEntry(
                id: UUID(),
                timestamp: event.timestamp,
                summary: "Gesture: \(gesture)",
                category: "gesture"
            )

        case .activityDetected(let activity, _):
            return HistoryEntry(
                id: UUID(),
                timestamp: event.timestamp,
                summary: "Activity: \(activity)",
                category: "activity"
            )

        case .spatialRelation(let subject, let relation, let object):
            return HistoryEntry(
                id: UUID(),
                timestamp: event.timestamp,
                summary: "\(subject.capitalized) is \(relation) \(object)",
                category: "spatial"
            )
        }
    }
}
