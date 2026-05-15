import Foundation
import Vision
import CoreML
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

    private let yoloRequest: VNCoreMLRequest?
    private let modelLoadFailure: String?

    init() {
        let result = ObjectDetector.makeYoloRequest(modelName: Theme.Performance.detectorModelName)
        self.yoloRequest = result.request
        self.modelLoadFailure = result.failureReason
        if let failure = modelLoadFailure {
            NSLog("ObjectDetector: \(failure) — falling back to Vision built-ins only.")
        } else {
            NSLog("ObjectDetector: loaded \(Theme.Performance.detectorModelName) (\(yoloRequest != nil ? "ANE/GPU" : "n/a")).")
        }
    }

    private static func makeYoloRequest(modelName: String) -> (request: VNCoreMLRequest?, failureReason: String?) {
        guard let compiledURL = Bundle.main.url(forResource: modelName, withExtension: "mlmodelc")
            ?? Bundle.main.url(forResource: modelName, withExtension: "mlpackage")
        else {
            return (nil, "Model \(modelName) not found in app bundle")
        }
        do {
            let config = MLModelConfiguration()
            config.computeUnits = .all
            let mlModel = try MLModel(contentsOf: compiledURL, configuration: config)
            let vnModel = try VNCoreMLModel(for: mlModel)
            let request = VNCoreMLRequest(model: vnModel)
            request.imageCropAndScaleOption = .scaleFill
            return (request, nil)
        } catch {
            return (nil, "Failed to load \(modelName): \(error)")
        }
    }

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

        nonisolated(unsafe) let buffer = pixelBuffer
        queue.async { [weak self] in
            self?.run(pixelBuffer: buffer)
        }
    }

    private func run(pixelBuffer: CVPixelBuffer) {
        let start = CFAbsoluteTimeGetCurrent()

        let faces = VNDetectFaceRectanglesRequest()
        let animals = VNRecognizeAnimalsRequest()
        var requests: [VNRequest] = [faces, animals]
        if let yolo = yoloRequest {
            requests.append(yolo)
        }

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        var collected: [Detection] = []

        do {
            try handler.perform(requests)
        } catch {
            NSLog("Vision perform error: \(error)")
        }

        if let yoloResults = yoloRequest?.results as? [VNRecognizedObjectObservation] {
            let minConfidence = Theme.Performance.detectionMinConfidence
            for obs in yoloResults {
                let top = obs.labels.first
                let topConfidence = top?.confidence ?? obs.confidence
                if topConfidence < minConfidence { continue }
                let label = (top?.identifier ?? "OBJECT").uppercased()
                collected.append(Detection(rect: obs.boundingBox,
                                           label: label,
                                           confidence: topConfidence))
            }
        }

        if let faceResults = faces.results {
            for obs in faceResults {
                collected.append(Detection(rect: obs.boundingBox,
                                           label: "FACE",
                                           confidence: obs.confidence))
            }
        }
        if let animalResults = animals.results {
            for obs in animalResults {
                let label = (obs.labels.first?.identifier ?? "ANIMAL").uppercased()
                collected.append(Detection(rect: obs.boundingBox,
                                           label: label,
                                           confidence: obs.confidence))
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
        let sized = all.filter { $0.rect.width * $0.rect.height >= minArea }

        // Suppress strongly-overlapping detections that share the same label.
        // YOLO already applies NMS internally so cross-class duplicates are rare;
        // a small same-label pass handles overlap between YOLO + face/animal.
        let byLabel = Dictionary(grouping: sized, by: { $0.label })
        var kept: [Detection] = []
        for (_, group) in byLabel {
            let sortedGroup = group.sorted { $0.confidence > $1.confidence }
            var accepted: [Detection] = []
            for det in sortedGroup {
                if accepted.allSatisfy({ iou($0.rect, det.rect) < 0.5 }) {
                    accepted.append(det)
                }
            }
            kept.append(contentsOf: accepted)
        }

        let sorted = kept.sorted { $0.confidence > $1.confidence }
        return Array(sorted.prefix(Theme.Performance.maxDetectionsPerFrame))
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
