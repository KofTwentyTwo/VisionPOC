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
    var trackId: UUID     // stable across frames once YOLO bootstraps the track
}

/// Combined detect-and-track. YOLO produces ground-truth detections at a
/// configurable cadence (`Theme.Performance.yoloDetectionHz`, default 5 Hz);
/// between YOLO runs, `VNTrackObjectRequest` updates each active track's box
/// from the latest frame so the rendered overlay tracks objects smoothly.
final class ObjectDetector: @unchecked Sendable {
    private final class TrackedObject {
        let id: UUID
        var label: String
        var confidence: Float
        var observation: VNDetectedObjectObservation
        var lastRefreshedAt: CFAbsoluteTime

        init(label: String, confidence: Float, observation: VNDetectedObjectObservation, now: CFAbsoluteTime) {
            self.id = UUID()
            self.label = label
            self.confidence = confidence
            self.observation = observation
            self.lastRefreshedAt = now
        }
    }

    private let queue = DispatchQueue(label: "com.dmdbrands.VisionPOC.detector", qos: .userInitiated)
    private let trackingHandler = VNSequenceRequestHandler()
    let faceRegistry = FaceRegistry()

    /// State for the in-flight "capture next N face prints for enrollment" flow.
    /// Accessed exclusively from `queue`.
    private var pendingEnrollment: (remaining: Int, collected: [VNFeaturePrintObservation], completion: @Sendable ([VNFeaturePrintObservation]) -> Void)?

    private var lock = os_unfair_lock_s()
    private var _currentDetections: [Detection] = []
    private var _lastInferenceMs: Double = 0
    private var _inFlight = false

    /// Mutated exclusively from `queue`. No lock needed inside the serial queue.
    private var tracks: [TrackedObject] = []
    private var lastYoloAt: CFAbsoluteTime = 0

    private let yoloRequest: VNCoreMLRequest?
    private let modelLoadFailure: String?

    init() {
        let result = ObjectDetector.makeYoloRequest(modelName: Theme.Performance.detectorModelName)
        self.yoloRequest = result.request
        self.modelLoadFailure = result.failureReason
        if let failure = modelLoadFailure {
            NSLog("ObjectDetector: \(failure) — falling back to Vision built-ins only.")
        } else {
            NSLog("ObjectDetector: loaded \(Theme.Performance.detectorModelName), tracker enabled.")
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
        os_unfair_lock_lock(&lock)
        if _inFlight {
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

    // MARK: - Pipeline

    private func run(pixelBuffer: CVPixelBuffer) {
        let start = CFAbsoluteTimeGetCurrent()
        let yoloInterval = 1.0 / max(0.5, Theme.Performance.yoloDetectionHz)
        let shouldDetect = (start - lastYoloAt) >= yoloInterval

        if shouldDetect {
            detectAndBootstrap(pixelBuffer: pixelBuffer, now: start)
            lastYoloAt = start
        } else {
            trackOnly(pixelBuffer: pixelBuffer, now: start)
        }

        // Drop tracks that have aged out (no YOLO refresh recently).
        let maxAge = Theme.Performance.trackMaxAgeSeconds
        tracks.removeAll { (start - $0.lastRefreshedAt) > maxAge }

        let elapsedMs = (CFAbsoluteTimeGetCurrent() - start) * 1000.0
        let snapshot = tracks.map {
            Detection(
                rect: $0.observation.boundingBox,
                label: $0.label,
                confidence: $0.confidence,
                trackId: $0.id
            )
        }

        os_unfair_lock_lock(&lock)
        _currentDetections = snapshot
        _lastInferenceMs = elapsedMs
        _inFlight = false
        os_unfair_lock_unlock(&lock)
    }

    // MARK: - YOLO + supplementary detectors

    private func detectAndBootstrap(pixelBuffer: CVPixelBuffer, now: CFAbsoluteTime) {
        let faces = VNDetectFaceRectanglesRequest()
        let animals = VNRecognizeAnimalsRequest()
        var requests: [VNRequest] = [faces, animals]
        if let yolo = yoloRequest {
            requests.append(yolo)
        }

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        do {
            try handler.perform(requests)
        } catch {
            NSLog("Vision perform error: \(error)")
        }

        // Generate feature prints for the face observations we just collected.
        // We re-run a second Vision pass scoped to those face rects so the
        // FeaturePrint network only processes the cropped face regions — ~5ms
        // per face on the ANE, negligible.
        let facePrints: [VNFeaturePrintObservation] = computeFacePrints(
            for: faces.results ?? [],
            pixelBuffer: pixelBuffer
        )

        // If an enrollment capture is pending, feed it the largest face's
        // print from this frame.
        consumeEnrollmentIfNeeded(faces: faces.results ?? [], prints: facePrints)

        var newDetections: [(rect: CGRect, label: String, confidence: Float)] = []

        let minConfidence = Theme.Performance.detectionMinConfidence
        if let yoloResults = yoloRequest?.results as? [VNRecognizedObjectObservation] {
            for obs in yoloResults {
                let top = obs.labels.first
                let confidence = top?.confidence ?? obs.confidence
                if confidence < minConfidence { continue }
                let label = (top?.identifier ?? "OBJECT").uppercased()
                newDetections.append((obs.boundingBox, label, confidence))
            }
        }
        if let faceResults = faces.results {
            for (i, obs) in faceResults.enumerated() {
                // Try to recognize the face against the registry. The prints
                // array is index-aligned with faceResults from Vision's order.
                var label = "FACE"
                if i < facePrints.count,
                   let match = faceRegistry.bestMatch(for: facePrints[i]) {
                    label = match.name.uppercased()
                }
                newDetections.append((obs.boundingBox, label, obs.confidence))
            }
        }
        if let animalResults = animals.results {
            for obs in animalResults {
                let label = (obs.labels.first?.identifier ?? "ANIMAL").uppercased()
                newDetections.append((obs.boundingBox, label, obs.confidence))
            }
        }

        // Match each new detection against existing tracks. Same-label matches
        // are preferred over cross-label matches so a YOLO "PERSON" doesn't
        // accidentally inherit the label from a partially-overlapping "FACE"
        // track. If nothing matches, bootstrap a fresh track.
        var matchedTrackIDs = Set<UUID>()
        for det in newDetections {
            let matchIdx = bestMatchIndex(for: det.rect, label: det.label, excluding: matchedTrackIDs)
            if let idx = matchIdx {
                let track = tracks[idx]
                track.label = det.label
                track.confidence = det.confidence
                track.observation = VNDetectedObjectObservation(boundingBox: det.rect)
                track.lastRefreshedAt = now
                matchedTrackIDs.insert(track.id)
            } else {
                let obs = VNDetectedObjectObservation(boundingBox: det.rect)
                let track = TrackedObject(label: det.label, confidence: det.confidence, observation: obs, now: now)
                tracks.append(track)
                matchedTrackIDs.insert(track.id)
            }
        }
    }

    // MARK: - Tracker-only update

    private func trackOnly(pixelBuffer: CVPixelBuffer, now: CFAbsoluteTime) {
        guard !tracks.isEmpty else { return }

        // Build one tracking request per active track. Apple's tracker can
        // handle a handful of objects in a single perform() call without
        // measurable extra latency.
        let trackRequests = tracks.map { track -> VNTrackObjectRequest in
            let req = VNTrackObjectRequest(detectedObjectObservation: track.observation)
            req.trackingLevel = .accurate
            return req
        }

        do {
            try trackingHandler.perform(trackRequests, on: pixelBuffer, orientation: .up)
        } catch {
            NSLog("Tracking perform error: \(error)")
            return
        }

        let minConfidence = Theme.Performance.trackerMinConfidence
        for (idx, req) in trackRequests.enumerated() where idx < tracks.count {
            guard let updated = req.results?.first as? VNDetectedObjectObservation else { continue }
            if updated.confidence < minConfidence {
                // Tracker has lost the object; keep the old observation and
                // let the age-out timer drop the track if YOLO doesn't see it
                // again soon.
                continue
            }
            tracks[idx].observation = updated
        }
    }

    // MARK: - Matching

    private func bestMatchIndex(for rect: CGRect, label: String, excluding excluded: Set<UUID>) -> Int? {
        let threshold = CGFloat(Theme.Performance.trackMatchIoU)
        var bestIdx: Int?
        var bestScore: CGFloat = threshold

        for (idx, track) in tracks.enumerated() where !excluded.contains(track.id) {
            let score = iou(rect, track.observation.boundingBox)
            // Prefer same-label matches by giving them a small score boost.
            let adjusted: CGFloat = (track.label == label) ? score + 0.05 : score
            if adjusted > bestScore {
                bestScore = adjusted
                bestIdx = idx
            }
        }
        return bestIdx
    }

    // MARK: - Face feature prints & enrollment

    /// Generates a per-face feature print by running `VNGenerateImageFeaturePrintRequest`
    /// on a region-of-interest crop for each face. Vision's public API doesn't
    /// expose a dedicated face-embedding model, but the general-purpose image
    /// FeaturePrint applied to a tight face crop produces distances that
    /// reliably separate "same person" from "different person" for the small
    /// number of enrolled identities typical of a POC.
    private func computeFacePrints(
        for faces: [VNFaceObservation],
        pixelBuffer: CVPixelBuffer
    ) -> [VNFeaturePrintObservation] {
        guard !faces.isEmpty else { return [] }
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])

        var requests: [VNGenerateImageFeaturePrintRequest] = []
        requests.reserveCapacity(faces.count)
        for face in faces {
            let req = VNGenerateImageFeaturePrintRequest()
            // Slightly pad the face rect so we capture some surrounding context
            // (hairline, jaw). Clamp to [0,1].
            req.regionOfInterest = padFaceRect(face.boundingBox)
            requests.append(req)
        }

        do {
            try handler.perform(requests)
        } catch {
            NSLog("Face FeaturePrint perform error: \(error)")
            return []
        }

        var out: [VNFeaturePrintObservation] = []
        for req in requests {
            if let obs = req.results?.first as? VNFeaturePrintObservation {
                out.append(obs)
            }
        }
        return out
    }

    private func padFaceRect(_ r: CGRect) -> CGRect {
        let pad: CGFloat = 0.08
        let x = max(0, r.origin.x - r.width * pad)
        let y = max(0, r.origin.y - r.height * pad)
        let w = min(1 - x, r.width * (1 + 2 * pad))
        let h = min(1 - y, r.height * (1 + 2 * pad))
        return CGRect(x: x, y: y, width: w, height: h)
    }

    private func consumeEnrollmentIfNeeded(
        faces: [VNFaceObservation],
        prints: [VNFeaturePrintObservation]
    ) {
        guard var enrollment = pendingEnrollment else { return }
        guard !faces.isEmpty, !prints.isEmpty else {
            // Wait for a frame that actually contains a face.
            return
        }

        // Use the largest face by bounding-box area — most likely to be the
        // person actively enrolling rather than a bystander in the background.
        let pairs = zip(faces, prints)
        let chosen = pairs.max(by: { lhs, rhs in
            let la = lhs.0.boundingBox.width * lhs.0.boundingBox.height
            let ra = rhs.0.boundingBox.width * rhs.0.boundingBox.height
            return la < ra
        })
        guard let (_, print) = chosen else { return }

        enrollment.collected.append(print)
        enrollment.remaining -= 1

        if enrollment.remaining <= 0 {
            let captured = enrollment.collected
            let completion = enrollment.completion
            pendingEnrollment = nil
            completion(captured)
        } else {
            pendingEnrollment = enrollment
        }
    }

    /// Captures `count` feature prints from upcoming detection frames and
    /// delivers them to `completion` on an arbitrary queue. The caller is
    /// responsible for hopping back to main if it touches UI.
    func captureFeaturePrints(count: Int, completion: @escaping @Sendable ([VNFeaturePrintObservation]) -> Void) {
        let n = max(1, count)
        queue.async { [weak self] in
            guard let self else { return }
            self.pendingEnrollment = (remaining: n, collected: [], completion: completion)
        }
    }

    func cancelEnrollment() {
        queue.async { [weak self] in
            self?.pendingEnrollment = nil
        }
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
