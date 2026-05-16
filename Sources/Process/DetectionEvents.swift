import Foundation
import CoreGraphics

/// Cross-subsystem event vocabulary. Subsystems publish through
/// `DetectionEventBus.shared.emit(_:)`; subscribers (UI history view,
/// TTS greeter, IPC bridge, ...) listen via `subscribe(_:)`.
///
/// All cases carry the minimum data needed for a downstream consumer to act
/// on the event without going back to ObjectDetector. Track IDs stay stable
/// across an object's lifetime so consumers can dedupe (e.g. the greeter
/// only speaks each appearance once per track-id).
struct DetectionEvent: Sendable {
    enum Kind: Sendable, Equatable {
        case objectAppeared(label: String, trackId: UUID, confidence: Float, rect: CGRect)
        case objectDisappeared(label: String, trackId: UUID)
        case objectRefreshed(label: String, trackId: UUID, confidence: Float, rect: CGRect)
        case faceRecognized(name: String, distance: Float, trackId: UUID?)
        case faceSeenUnknown(trackId: UUID?)
        case textRecognized(text: String, confidence: Float)
        case gestureDetected(gesture: String, confidence: Float)
        case activityDetected(activity: String, confidence: Float)
        case spatialRelation(subject: String, relation: String, object: String)
    }

    let kind: Kind
    let timestamp: Date
}
