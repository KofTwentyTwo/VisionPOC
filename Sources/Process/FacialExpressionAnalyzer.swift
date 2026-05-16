import Foundation
import Vision
import CoreGraphics
import os

/// Classifies face observations into one of three expressions — `smile`,
/// `frown`, `neutral_face` — based on the geometry of the outer-lip
/// landmark contour. Emits `gestureDetected(...)` events on the bus.
///
/// Algorithm
/// ---------
/// `VNFaceObservation.landmarks.outerLips` returns a closed contour around
/// the mouth. The mouth corners are the points with the most extreme x;
/// the "Cupid's bow / chin midline" is captured by the contour's vertical
/// centroid. By comparing the average y of the two corners against the
/// centroid y (Vision coords are origin-bottom-left, so larger y = higher
/// on the face):
///
/// - corners above the centroid → mouth pulls up at the edges → smile
/// - corners below the centroid → mouth pulls down at the edges → frown
/// - within a small dead-band → neutral
///
/// Throttle: same expression not emitted more than once per 4 seconds.
final class FacialExpressionAnalyzer: @unchecked Sendable {
    private let bus: DetectionEventBus
    private var lock = os_unfair_lock_s()
    private var lastEmit: [String: Date] = [:]
    private let throttle: TimeInterval = 4.0

    /// Dead-band: the corner-to-centroid delta has to exceed this fraction of
    /// the face's bounding-box height before we commit to smile/frown.
    private let deadBandFraction: CGFloat = 0.01

    init(bus: DetectionEventBus = .shared) {
        self.bus = bus
    }

    func analyze(_ faces: [VNFaceObservation]) {
        for face in faces {
            guard let lips = face.landmarks?.outerLips else { continue }
            // VNFaceLandmarkRegion2D exposes points either as
            // `pointsInImage(imageSize:)` (pixel coords) or as
            // `normalizedPoints` (in [0,1] within the face's bounding box).
            // We use normalized so we can compare in a unit-coordinate frame.
            let points = lips.normalizedPoints
            guard !points.isEmpty else { continue }

            let summary = classify(points: points, faceHeight: face.boundingBox.height)
            emitIfFresh(expression: summary.name, confidence: summary.confidence)
        }
    }

    private struct Summary {
        let name: String
        let confidence: Float
    }

    private func classify(points: [CGPoint], faceHeight: CGFloat) -> Summary {
        // Corners: leftmost and rightmost x.
        let left = points.min(by: { $0.x < $1.x }) ?? points[0]
        let right = points.max(by: { $0.x < $1.x }) ?? points[0]
        let cornerAvgY = (left.y + right.y) / 2.0

        // Centroid (vertical) of the contour.
        let avgY = points.reduce(CGFloat(0)) { $0 + $1.y } / CGFloat(points.count)

        let delta = cornerAvgY - avgY
        // Scale the dead-band to the face's bounding-box height so it stays
        // sensible regardless of how big the face is in frame.
        let deadBand = max(0.005, faceHeight * deadBandFraction)

        // Confidence reflects how strongly the corner offset exceeds the
        // dead-band. Clamp to [0, 1].
        let magnitude = min(CGFloat(1), abs(delta) / max(deadBand * 4, 0.001))
        let confidence = Float(magnitude)

        if delta > deadBand {
            return Summary(name: "smile", confidence: confidence)
        } else if delta < -deadBand {
            return Summary(name: "frown", confidence: confidence)
        } else {
            return Summary(name: "neutral_face", confidence: 0.5)
        }
    }

    private func emitIfFresh(expression: String, confidence: Float) {
        let now = Date()
        os_unfair_lock_lock(&lock)
        if let last = lastEmit[expression], now.timeIntervalSince(last) < throttle {
            os_unfair_lock_unlock(&lock)
            return
        }
        lastEmit[expression] = now
        os_unfair_lock_unlock(&lock)
        bus.emit(.gestureDetected(gesture: expression, confidence: confidence))
        LogStream.shared.log("expression: \(expression) (conf \(String(format: "%.2f", confidence)))",
                             level: .debug, source: .detect)
    }
}
