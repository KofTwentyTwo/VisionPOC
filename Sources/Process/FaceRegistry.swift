import Foundation
import Vision
import os

/// Persists enrolled face feature prints to
/// `~/Library/Application Support/VisionPOC/faces.json` and matches incoming
/// face observations against them.
///
/// Each person can be enrolled multiple times — the registry stores every
/// captured print and matches against the minimum distance, so seeing the
/// same person at slightly different angles/lighting only improves accuracy.
///
/// Distance interpretation (`VNFeaturePrintObservation.computeDistance(...)`):
/// - 0.0 → identical
/// - ~0.6 → conservative threshold for "same person"
/// - 1.0+ → different people
final class FaceRegistry: @unchecked Sendable {
    /// Match threshold. Distances below this are considered the same person.
    /// Sourced from `Theme.Performance.faceMatchThreshold` so the Settings
    /// panel slider can adjust it live.
    var matchThreshold: Float {
        get { Theme.Performance.faceMatchThreshold }
        set { Theme.Performance.faceMatchThreshold = newValue }
    }

    private var lock = os_unfair_lock_s()
    private var templates: [String: [VNFeaturePrintObservation]] = [:]

    private static var storageURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("VisionPOC", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("faces.json")
    }

    init() {
        loadFromDisk()
    }

    // MARK: - Public API

    func enrolledNames() -> [String] {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return Array(templates.keys).sorted()
    }

    func enroll(name: String, prints: [VNFeaturePrintObservation]) {
        guard !prints.isEmpty else { return }
        os_unfair_lock_lock(&lock)
        var existing = templates[name] ?? []
        existing.append(contentsOf: prints)
        templates[name] = existing
        let total = existing.count
        os_unfair_lock_unlock(&lock)
        saveToDisk()
        LogStream.shared.log("enrolled \(name) (+\(prints.count) prints, \(total) total)",
                             level: .info, source: .face)
    }

    func forget(name: String) {
        os_unfair_lock_lock(&lock)
        let existed = templates.removeValue(forKey: name) != nil
        os_unfair_lock_unlock(&lock)
        saveToDisk()
        if existed {
            LogStream.shared.log("forgot \(name)", level: .info, source: .face)
        }
    }

    /// Returns the closest match below `matchThreshold`, or nil if no enrolled
    /// person is similar enough. Returns the best name plus the achieved
    /// distance so callers can display a confidence cue.
    func bestMatch(for print: VNFeaturePrintObservation) -> (name: String, distance: Float)? {
        os_unfair_lock_lock(&lock)
        let snapshot = templates
        let threshold = matchThreshold
        os_unfair_lock_unlock(&lock)

        var bestName: String?
        var bestDistance: Float = .greatestFiniteMagnitude

        for (name, prints) in snapshot {
            for template in prints {
                var distance: Float = 0
                do {
                    try template.computeDistance(&distance, to: print)
                } catch {
                    continue
                }
                if distance < bestDistance {
                    bestDistance = distance
                    bestName = name
                }
            }
        }

        guard let bestName, bestDistance < threshold else { return nil }
        return (bestName, bestDistance)
    }

    // MARK: - Persistence

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: Self.storageURL) else { return }
        guard let decoded = try? JSONDecoder().decode([String: [Data]].self, from: data) else { return }

        var loaded: [String: [VNFeaturePrintObservation]] = [:]
        for (name, blobs) in decoded {
            var prints: [VNFeaturePrintObservation] = []
            for blob in blobs {
                if let obs = try? NSKeyedUnarchiver.unarchivedObject(
                    ofClass: VNFeaturePrintObservation.self,
                    from: blob
                ) {
                    prints.append(obs)
                }
            }
            if !prints.isEmpty {
                loaded[name] = prints
            }
        }
        templates = loaded
        let nameCount = loaded.count
        let printCount = loaded.values.reduce(0) { $0 + $1.count }
        LogStream.shared.log("loaded \(nameCount) enrolled face\(nameCount == 1 ? "" : "s") (\(printCount) prints)",
                             level: .info, source: .face)
    }

    private func saveToDisk() {
        os_unfair_lock_lock(&lock)
        let snapshot = templates
        os_unfair_lock_unlock(&lock)

        var encoded: [String: [Data]] = [:]
        for (name, prints) in snapshot {
            var blobs: [Data] = []
            for p in prints {
                if let blob = try? NSKeyedArchiver.archivedData(
                    withRootObject: p,
                    requiringSecureCoding: true
                ) {
                    blobs.append(blob)
                }
            }
            encoded[name] = blobs
        }

        do {
            let json = try JSONEncoder().encode(encoded)
            try json.write(to: Self.storageURL, options: .atomic)
        } catch {
            NSLog("FaceRegistry: failed to write \(Self.storageURL.path): \(error)")
        }
    }
}
