import Foundation
import CoreGraphics

/// Shared frame-annotation types produced by `ObjectDetector` and consumed by
/// `Renderer`. All coordinates use Vision's normalized [0..1] image space
/// (origin bottom-left), matching the existing `Detection.rect`. The renderer
/// converts to viewport NDC the same way it does for detections, so adding a
/// new overlay type is just an array of rects-or-points and a draw call.

/// Recognized text region — produced by `VNRecognizeTextRequest`.
struct TextDetection: Sendable {
    var rect: CGRect          // normalized, origin bottom-left
    var text: String          // the recognized string
    var confidence: Float
}

enum PoseKind: Sendable {
    case body
    case hand
}

/// A pose detection — a set of normalized line segments (joint pairs) plus
/// the keypoint positions themselves. The renderer draws lines between the
/// segment endpoints and small dots at each unique point.
struct PoseDetection: Sendable {
    /// Normalized line segments (each segment goes from start to end in
    /// Vision's [0..1] image coords, origin bottom-left).
    var segments: [Segment]
    /// All unique joint points present in this pose, for dot rendering.
    var points: [CGPoint]
    /// Whether this pose is a body skeleton or a hand skeleton.
    var kind: PoseKind
    /// Overall confidence of the pose (max of constituent joint confidences).
    var confidence: Float

    struct Segment: Sendable {
        var start: CGPoint
        var end: CGPoint
    }
}

/// Tells the renderer which detector mode produced the most recent
/// inference, so the footer can label `DET 28.4ms (yolo)` vs `DET 2.1ms (track)`.
enum DetectMode: String, Sendable {
    case yolo  = "yolo"
    case track = "track"
}
