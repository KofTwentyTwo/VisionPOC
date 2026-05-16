import Foundation
import os

/// In-memory ring buffer of recent system events from every subsystem, plus
/// a single sink that mirrors entries to stdout for `xcrun log stream`. The
/// log viewer window polls `snapshot()` to render entries; it never holds a
/// long-lived reference, so the buffer can be safely mutated from background
/// queues.
final class LogStream: @unchecked Sendable {
    static let shared = LogStream()

    enum Level: String, Sendable, CaseIterable, Identifiable {
        case debug = "DBG"
        case info  = "INF"
        case warn  = "WRN"
        case error = "ERR"
        var id: String { rawValue }
    }

    enum Source: String, Sendable, CaseIterable, Identifiable {
        case app    = "APP"
        case camera = "CAM"
        case detect = "DETECT"
        case track  = "TRACK"
        case face   = "FACE"
        case render = "RENDER"
        case other  = "VPOC"
        var id: String { rawValue }
    }

    struct Entry: Identifiable, Sendable {
        let id = UUID()
        let timestamp: Date
        let level: Level
        let source: Source
        let message: String
    }

    private var lock = os_unfair_lock_s()
    private var buffer: [Entry] = []
    private let maxEntries: Int = 1000

    /// Monotonic counter bumped on every append. The viewer reads this to
    /// short-circuit polling when nothing has changed.
    private var _version: UInt64 = 0
    var version: UInt64 {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return _version
    }

    func log(_ message: String, level: Level = .info, source: Source = .other) {
        let entry = Entry(timestamp: Date(), level: level, source: source, message: message)
        os_unfair_lock_lock(&lock)
        buffer.append(entry)
        if buffer.count > maxEntries {
            buffer.removeFirst(buffer.count - maxEntries)
        }
        _version &+= 1
        os_unfair_lock_unlock(&lock)

        // Mirror to stdout for tail-from-terminal scenarios.
        // Keep it terse: it's the running stream, not a permanent archive.
        let stamp = LogStream.iso8601.string(from: entry.timestamp)
        print("[\(stamp)] \(level.rawValue) \(source.rawValue.padding(toLength: 6, withPad: " ", startingAt: 0)) \(message)")
    }

    func snapshot() -> [Entry] {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return buffer
    }

    func clear() {
        os_unfair_lock_lock(&lock)
        buffer.removeAll()
        _version &+= 1
        os_unfair_lock_unlock(&lock)
    }

    /// Drop-in replacement for NSLog that also surfaces in the log viewer.
    func bridgeNSLog(_ message: String, source: Source = .other) {
        NSLog("%@", message)
        log(message, level: .info, source: source)
    }

    // Helpers
    private static let iso8601: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss.SSS"
        return df
    }()
}
