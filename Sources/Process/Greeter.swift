import Foundation
import AVFoundation

/// Listens on the DetectionEventBus and speaks "Hello, <name>" via
/// AVSpeechSynthesizer when a known face is recognized. Independent from
/// ObjectDetector — the bus is the only contract between them.
///
/// Threading: subscriptions fire on the emitter's queue (the detector queue).
/// AVSpeechSynthesizer is MainActor-bound on recent macOS releases, so the
/// subscriber closure dispatches into `Task { @MainActor }` before calling
/// `speak(_:)`. The synthesizer is created lazily on the MainActor for the
/// same reason.
///
/// Throttle: the bus-level face-recognized event is already throttled to one
/// emit per 5s per name (in ObjectDetector). This class additionally rate-
/// limits to one *spoken* greeting per name per 30s, so even if the bus
/// throttle is loosened the greeter doesn't become spammy.
final class Greeter: @unchecked Sendable {
    /// Set to true to suppress all speech without unsubscribing. The UI agent
    /// surfaces this via `Theme.Performance.greeterMuted`, which is read on
    /// each event.
    var isMuted: Bool {
        get { Theme.Performance.greeterMuted }
        set { Theme.Performance.greeterMuted = newValue }
    }

    private var lock = os_unfair_lock_s()
    private var lastSpokenAt: [String: Date] = [:]
    /// Per-name minimum interval between greetings.
    private let throttleInterval: TimeInterval = 30.0

    private var token: DetectionEventBus.Token?

    /// Lazily-created on MainActor. AVSpeechSynthesizer's initializer touches
    /// AppKit/AVFoundation state that's safer to construct on main.
    @MainActor private static var synthesizer: AVSpeechSynthesizer = AVSpeechSynthesizer()

    init(bus: DetectionEventBus = .shared) {
        self.token = bus.subscribe { [weak self] event in
            guard let self else { return }
            self.handle(event)
        }
    }

    deinit {
        token?.cancel()
    }

    private func handle(_ event: DetectionEvent) {
        guard case let .faceRecognized(name, _, _) = event.kind else { return }
        if isMuted { return }

        let now = Date()
        os_unfair_lock_lock(&lock)
        if let prev = lastSpokenAt[name], now.timeIntervalSince(prev) < throttleInterval {
            os_unfair_lock_unlock(&lock)
            return
        }
        lastSpokenAt[name] = now
        os_unfair_lock_unlock(&lock)

        let phrase = "Hello, \(name)"
        Task { @MainActor in
            let utterance = AVSpeechUtterance(string: phrase)
            // Keep the voice neutral; use the system default. Volume/rate stay
            // at AVSpeechUtterance defaults so this respects user accessibility
            // preferences.
            Greeter.synthesizer.speak(utterance)
        }
    }
}
