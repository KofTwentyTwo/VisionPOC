import Foundation
import os

/// Persists a small label → most-recent-track-UUID mapping to disk so that
/// when an object reappears in a new session, the same UUID is reused — which
/// in turn makes the renderer's per-track color stay stable across launches.
///
/// Storage: `~/Library/Application Support/VisionPOC/tracks.json`
/// Format: `[String: String]` (label → UUID string)
/// Size cap: last-50 MRU; oldest entries are pruned on save.
final class TrackStore: @unchecked Sendable {
    static let shared = TrackStore()

    /// MRU cap: keep the last N entries on disk so the file doesn't grow
    /// unboundedly over months of use.
    private static let maxEntries = 50

    private var lock = os_unfair_lock_s()
    /// In-memory map.
    private var labelToUUID: [String: String] = [:]
    /// MRU ordering — most recently touched label is at the end.
    private var order: [String] = []

    /// Debounce so back-to-back track bootstraps don't each hit the disk.
    private var pendingSave: DispatchWorkItem?
    private let saveQueue = DispatchQueue(label: "com.dmdbrands.VisionPOC.trackstore.save", qos: .utility)

    private static var storageURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("VisionPOC", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("tracks.json")
    }

    init() {
        loadFromDisk()
    }

    /// Returns the most recently persisted UUID for this label, if any.
    /// Callers should treat this as a *preference* — if the persisted string
    /// fails to parse as a UUID, this returns nil and a fresh UUID should be
    /// minted.
    func preferredUUID(for label: String) -> UUID? {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        guard let str = labelToUUID[label] else { return nil }
        return UUID(uuidString: str)
    }

    /// Record that `label` is now associated with `id`. Moves the label to
    /// the MRU end and schedules a debounced save.
    func record(label: String, id: UUID) {
        os_unfair_lock_lock(&lock)
        labelToUUID[label] = id.uuidString
        if let existing = order.firstIndex(of: label) {
            order.remove(at: existing)
        }
        order.append(label)
        prune()
        os_unfair_lock_unlock(&lock)
        scheduleSave()
    }

    /// Caller must hold the lock.
    private func prune() {
        while order.count > TrackStore.maxEntries {
            let dropped = order.removeFirst()
            labelToUUID.removeValue(forKey: dropped)
        }
    }

    private func scheduleSave() {
        os_unfair_lock_lock(&lock)
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.saveToDisk()
        }
        pendingSave = work
        os_unfair_lock_unlock(&lock)
        // Coalesce bursts of track creations into a single disk write.
        saveQueue.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: Self.storageURL) else { return }
        struct Persisted: Codable {
            var labelToUUID: [String: String]
            var order: [String]
        }
        if let decoded = try? JSONDecoder().decode(Persisted.self, from: data) {
            os_unfair_lock_lock(&lock)
            labelToUUID = decoded.labelToUUID
            order = decoded.order.filter { labelToUUID[$0] != nil }
            // Defensive: ensure any keys missing from `order` get appended so
            // pruning still works deterministically.
            for k in labelToUUID.keys where !order.contains(k) {
                order.append(k)
            }
            prune()
            os_unfair_lock_unlock(&lock)
        } else if let flat = try? JSONDecoder().decode([String: String].self, from: data) {
            // Backward-compat: a previous version stored just the flat map.
            os_unfair_lock_lock(&lock)
            labelToUUID = flat
            order = Array(flat.keys)
            prune()
            os_unfair_lock_unlock(&lock)
        }
    }

    private func saveToDisk() {
        os_unfair_lock_lock(&lock)
        struct Persisted: Codable {
            var labelToUUID: [String: String]
            var order: [String]
        }
        let snapshot = Persisted(labelToUUID: labelToUUID, order: order)
        os_unfair_lock_unlock(&lock)

        do {
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: Self.storageURL, options: .atomic)
        } catch {
            NSLog("TrackStore: failed to write \(Self.storageURL.path): \(error)")
        }
    }
}
