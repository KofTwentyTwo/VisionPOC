import Foundation
import os

/// Thread-safe pub/sub for `DetectionEvent`s. Singleton because every event
/// producer and consumer in the app refers to the same one; the bus itself
/// holds no app state — it just routes events synchronously to subscribers.
///
/// Threading: `emit` is callable from any queue. Each subscriber's handler
/// runs on the emitter's thread; if a subscriber needs MainActor or another
/// queue, it hops itself inside the handler. The bus does NOT serialize
/// handlers across emit calls — multiple producers can be racing inside
/// different handlers at once. Don't store mutable state in a subscriber
/// without your own lock.
final class DetectionEventBus: @unchecked Sendable {
    static let shared = DetectionEventBus()

    typealias Handler = @Sendable (DetectionEvent) -> Void

    /// Returned from `subscribe(_:)`. Keep a reference for the lifetime of
    /// the subscription; deinit removes the handler. Calling `cancel()` does
    /// the same explicitly.
    final class Token: @unchecked Sendable {
        private let id: UUID
        private weak var bus: DetectionEventBus?

        fileprivate init(id: UUID, bus: DetectionEventBus) {
            self.id = id
            self.bus = bus
        }

        func cancel() {
            bus?.unsubscribe(id: id)
        }

        deinit {
            cancel()
        }
    }

    private var lock = os_unfair_lock_s()
    private var handlers: [UUID: Handler] = [:]

    func emit(_ kind: DetectionEvent.Kind) {
        let event = DetectionEvent(kind: kind, timestamp: Date())
        os_unfair_lock_lock(&lock)
        let snapshot = handlers
        os_unfair_lock_unlock(&lock)
        for (_, handler) in snapshot {
            handler(event)
        }
    }

    @discardableResult
    func subscribe(_ handler: @escaping Handler) -> Token {
        let id = UUID()
        os_unfair_lock_lock(&lock)
        handlers[id] = handler
        os_unfair_lock_unlock(&lock)
        return Token(id: id, bus: self)
    }

    fileprivate func unsubscribe(id: UUID) {
        os_unfair_lock_lock(&lock)
        handlers.removeValue(forKey: id)
        os_unfair_lock_unlock(&lock)
    }
}
