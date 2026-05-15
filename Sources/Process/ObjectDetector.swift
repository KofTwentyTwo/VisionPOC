import Foundation
import Vision
import CoreVideo
import CoreGraphics
import os

struct Detection: Sendable {
    var rect: CGRect      // normalized image coords, Vision convention (origin bottom-left)
    var label: String
    var confidence: Float
}

final class ObjectDetector: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.dmdbrands.VisionPOC.detector", qos: .userInitiated)

    private var lock = os_unfair_lock_s()
    private var _currentDetections: [Detection] = []
    private var _lastInferenceMs: Double = 0
    private var _inFlight = false
    private var _lastFinishedAt: CFAbsoluteTime = 0

    var lastInferenceMs: Double {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return _lastInferenceMs
    }

    func currentDetections() -> [Detection] {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return _currentDetections
    }

    func submit(pixelBuffer: CVPixelBuffer) {
        let minInterval = 1.0 / Theme.Performance.detectorTargetHz
        let now = CFAbsoluteTimeGetCurrent()

        os_unfair_lock_lock(&lock)
        if _inFlight || (now - _lastFinishedAt) < minInterval {
            os_unfair_lock_unlock(&lock)
            return
        }
        _inFlight = true
        os_unfair_lock_unlock(&lock)

        // CVPixelBuffer is not Sendable but we only read from it on the detector queue
        // and AVFoundation has already handed it off to us — safe to capture.
        nonisolated(unsafe) let buffer = pixelBuffer
        queue.async { [weak self] in
            self?.run(pixelBuffer: buffer)
        }
    }

    private func run(pixelBuffer: CVPixelBuffer) {
        let start = CFAbsoluteTimeGetCurrent()

        let saliency = VNGenerateObjectnessBasedSaliencyImageRequest()
        let faces = VNDetectFaceRectanglesRequest()
        let humans = VNDetectHumanRectanglesRequest()
        let animals = VNRecognizeAnimalsRequest()

        // Vision picks the optimal compute unit (ANE on Apple Silicon) by default.
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        var collected: [Detection] = []

        do {
            try handler.perform([saliency, faces, humans, animals])
        } catch {
            NSLog("Vision perform error: \(error)")
        }

        if let salient = (saliency.results?.first as? VNSaliencyImageObservation)?.salientObjects {
            for obj in salient {
                collected.append(Detection(rect: obj.boundingBox, label: "OBJECT", confidence: obj.confidence))
            }
        }
        if let face = faces.results {
            for obs in face {
                collected.append(Detection(rect: obs.boundingBox, label: "FACE", confidence: obs.confidence))
            }
        }
        if let human = humans.results {
            for obs in human {
                collected.append(Detection(rect: obs.boundingBox, label: "HUMAN", confidence: obs.confidence))
            }
        }
        if let animalResults = animals.results {
            for obs in animalResults {
                let label = obs.labels.first?.identifier.uppercased() ?? "ANIMAL"
                collected.append(Detection(rect: obs.boundingBox, label: label, confidence: obs.confidence))
            }
        }

        let filtered = filterAndMerge(collected)

        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000.0

        os_unfair_lock_lock(&lock)
        _currentDetections = filtered
        _lastInferenceMs = elapsed
        _lastFinishedAt = CFAbsoluteTimeGetCurrent()
        _inFlight = false
        os_unfair_lock_unlock(&lock)
    }

    private func filterAndMerge(_ all: [Detection]) -> [Detection] {
        let minArea = Theme.Performance.minBoxArea
        let sizeFiltered = all.filter { $0.rect.width * $0.rect.height >= minArea }

        let labeled = sizeFiltered.filter { $0.label != "OBJECT" }
        let generic = sizeFiltered.filter { $0.label == "OBJECT" }

        let prunedGeneric = generic.filter { g in
            !labeled.contains(where: { iou($0.rect, g.rect) > 0.5 })
        }

        var merged = labeled + prunedGeneric
        merged.sort { $0.confidence > $1.confidence }
        if merged.count > Theme.Performance.maxDetectionsPerFrame {
            merged = Array(merged.prefix(Theme.Performance.maxDetectionsPerFrame))
        }
        return merged
    }

    private func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let inter = a.intersection(b)
        if inter.isNull || inter.isEmpty { return 0 }
        let interArea = inter.width * inter.height
        let union = a.width * a.height + b.width * b.height - interArea
        guard union > 0 else { return 0 }
        return interArea / union
    }
}
