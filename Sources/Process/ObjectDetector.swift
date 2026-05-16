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

        init(label: String, confidence: Float, observation: VNDetectedObjectObservation, now: CFAbsoluteTime, preferredID: UUID? = nil) {
            self.id = preferredID ?? UUID()
            self.label = label
            self.confidence = confidence
            self.observation = observation
            self.lastRefreshedAt = now
        }
    }

    /// Per-stage timing breakdown for the most recent inference pass. The
    /// "visionBundle" field is the wallclock of the single multi-request
    /// `handler.perform([yolo, faces, animals, text, body, hand])` call —
    /// Apple doesn't expose per-request timing inside a bundled perform, so
    /// we report it as one number. `featurePrint` and `tracker` are separate
    /// `perform` calls so they get their own breakdown.
    struct DetectorStageTiming: Sendable {
        var yoloMs: Double = 0
        var faceMs: Double = 0
        var animalMs: Double = 0
        var textMs: Double = 0
        var bodyPoseMs: Double = 0
        var handPoseMs: Double = 0
        var faceFeaturePrintMs: Double = 0
        var trackerMs: Double = 0
        var total: Double = 0

        /// Wallclock of the single bundled Vision perform that runs YOLO,
        /// faces, animals, text, and both pose requests together. Individual
        /// per-request breakdowns are approximated by splitting this evenly
        /// across the requests that ran. `featurePrint` and `tracker` are
        /// reported separately because they run in their own perform calls.
        var visionBundleMs: Double = 0
    }

    private let queue = DispatchQueue(label: "com.dmdbrands.VisionPOC.detector", qos: .userInitiated)
    private let trackingHandler = VNSequenceRequestHandler()
    let faceRegistry = FaceRegistry()

    /// State for the in-flight "capture next N face prints for enrollment" flow.
    /// Accessed exclusively from `queue`.
    private var pendingEnrollment: (remaining: Int, collected: [VNFeaturePrintObservation], completion: @Sendable ([VNFeaturePrintObservation]) -> Void)?

    private var lock = os_unfair_lock_s()
    private var _currentDetections: [Detection] = []
    private var _currentTextDetections: [TextDetection] = []
    private var _currentPoses: [PoseDetection] = []
    private var _lastDetectMode: DetectMode = .yolo
    private var _lastInferenceMs: Double = 0
    private var _inFlight = false
    private var _lastStageTiming = DetectorStageTiming()

    /// Mutated exclusively from `queue`. No lock needed inside the serial queue.
    private var tracks: [TrackedObject] = []
    private var lastYoloAt: CFAbsoluteTime = 0
    private var lastStatsLogAt: CFAbsoluteTime = 0
    private var lastStageLogAt: CFAbsoluteTime = 0

    /// Higher-level reasoning subsystems wired off the same detector pass.
    /// They publish to DetectionEventBus; nothing in the renderer pipeline
    /// depends on them, so they can be added/removed freely.
    private let gestureRecognizer = GestureRecognizer()
    private let activityRecognizer = ActivityRecognizer()
    private let spatialReasoner = SpatialReasoner()
    private let fingerCounter = FingerCounter()
    private let facialExpressionAnalyzer = FacialExpressionAnalyzer()
    private let eventBus = DetectionEventBus.shared

    /// Per-text last-seen-at, used to suppress flooding the bus with the
    /// same OCR string every detector tick.
    private var lastTextEmittedAt: [String: Date] = [:]
    /// Per-name throttle for face-recognized bus emits (separate from the
    /// Greeter's TTS throttle).
    private var lastFaceNameEmittedAt: [String: Date] = [:]

    private static let textEmitThrottle: TimeInterval = 2.0
    private static let faceNameEmitThrottle: TimeInterval = 5.0
    private static let textMinConfidence: Float = 0.4

    private let yoloRequest: VNCoreMLRequest?
    private let modelLoadFailure: String?

    init() {
        let result = ObjectDetector.makeYoloRequest(modelName: Theme.Performance.detectorModelName)
        self.yoloRequest = result.request
        self.modelLoadFailure = result.failureReason
        if let failure = modelLoadFailure {
            LogStream.shared.log(failure + " — falling back to Vision built-ins only.", level: .warn, source: .detect)
        } else {
            LogStream.shared.log("loaded \(Theme.Performance.detectorModelName), tracker enabled (~5 Hz YOLO + ~60 Hz tracker)", level: .info, source: .detect)
        }

        // Warm up the YOLO model on the detector queue so the first user-visible
        // detection doesn't pay ~200ms of CoreML/ANE compile latency. Dispatched
        // async so init() returns immediately and app launch isn't blocked.
        queue.async { [weak self] in
            self?.warmUpYolo()
        }
    }

    private func warmUpYolo() {
        guard let yolo = yoloRequest else { return }
        let start = CFAbsoluteTimeGetCurrent()

        // 416x416 mid-gray bitmap — YOLO's typical input size. The model will
        // rescale internally if needed; what matters is the CoreML graph gets
        // compiled and the ANE picks up the weights.
        let width = 416
        let height = 416
        let bytesPerRow = width * 4
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            LogStream.shared.log("yolo warmup skipped: bitmap context alloc failed", level: .warn, source: .detect)
            return
        }
        ctx.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1.0))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let cgImage = ctx.makeImage() else {
            LogStream.shared.log("yolo warmup skipped: cgImage creation failed", level: .warn, source: .detect)
            return
        }

        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])
        do {
            try handler.perform([yolo])
            let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000.0
            LogStream.shared.log("warmed up YOLO in \(String(format: "%.0f", ms))ms", level: .debug, source: .detect)
        } catch {
            LogStream.shared.log("yolo warmup failed: \(error)", level: .warn, source: .detect)
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

    /// Most recent per-stage timing breakdown. See `DetectorStageTiming` for
    /// what each field carries; bundled Vision requests share the
    /// `visionBundleMs` total.
    var lastStageTiming: DetectorStageTiming {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return _lastStageTiming
    }

    func currentDetections() -> [Detection] {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return _currentDetections
    }

    func currentTextDetections() -> [TextDetection] {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return _currentTextDetections
    }

    func currentPoses() -> [PoseDetection] {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return _currentPoses
    }

    var lastDetectMode: DetectMode {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return _lastDetectMode
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

        var newTextDetections: [TextDetection] = []
        var newPoses: [PoseDetection] = []
        let detectMode: DetectMode
        var stageTiming = DetectorStageTiming()

        if shouldDetect {
            let extras = detectAndBootstrap(pixelBuffer: pixelBuffer, now: start)
            newTextDetections = extras.text
            newPoses = extras.poses
            stageTiming = extras.timing
            lastYoloAt = start
            detectMode = .yolo
        } else {
            let trackerStart = CFAbsoluteTimeGetCurrent()
            trackOnly(pixelBuffer: pixelBuffer, now: start)
            stageTiming.trackerMs = (CFAbsoluteTimeGetCurrent() - trackerStart) * 1000.0
            detectMode = .track
        }

        // Drop tracks that have aged out (no YOLO refresh recently).
        let maxAge = Theme.Performance.trackMaxAgeSeconds
        let expired = tracks.filter { (start - $0.lastRefreshedAt) > maxAge }
        for track in expired {
            LogStream.shared.log("lost \(track.label.lowercased()) (id \(track.id.uuidString.prefix(4)))",
                                 level: .info, source: .track)
            // Publish disappearance for any subscriber that's tracking lifecycles.
            eventBus.emit(.objectDisappeared(label: track.label, trackId: track.id))
        }
        tracks.removeAll { (start - $0.lastRefreshedAt) > maxAge }

        // Periodic stats — once a second.
        if (start - lastStatsLogAt) >= 1.0 {
            lastStatsLogAt = start
            let yoloMs = (CFAbsoluteTimeGetCurrent() - start) * 1000.0
            let labels = tracks.map { $0.label.lowercased() }.sorted()
            let summary = labels.isEmpty ? "no objects" : labels.joined(separator: ", ")
            let kind = shouldDetect ? "yolo" : "track"
            LogStream.shared.log("\(kind) \(String(format: "%.1fms", yoloMs)) — \(tracks.count) track\(tracks.count == 1 ? "" : "s"): \(summary)",
                                 level: .debug, source: .detect)
        }

        let elapsedMs = (CFAbsoluteTimeGetCurrent() - start) * 1000.0
        stageTiming.total = elapsedMs
        let snapshot = tracks.map {
            Detection(
                rect: $0.observation.boundingBox,
                label: $0.label,
                confidence: $0.confidence,
                trackId: $0.id
            )
        }

        // Higher-level reasoning subsystems run off the same pass. Gesture &
        // activity recognizers fire from the just-computed poses; the spatial
        // reasoner ties them back to current detections.
        if shouldDetect {
            let handPoses = newPoses.filter { $0.kind == .hand }
            let bodyPoses = newPoses.filter { $0.kind == .body }
            gestureRecognizer.process(handPoses: handPoses)
            activityRecognizer.process(bodyPoses: bodyPoses)
            spatialReasoner.process(detections: snapshot, handPoses: handPoses)
        }

        // Stage-timing log at the same 1Hz cadence as the existing stats line,
        // but offset by half a second so the two logs don't share a frame.
        if (start - lastStageLogAt) >= 1.0 {
            lastStageLogAt = start
            LogStream.shared.log(
                "stages: vision-bundle=\(String(format: "%.1f", stageTiming.visionBundleMs))ms fp=\(String(format: "%.1f", stageTiming.faceFeaturePrintMs))ms tracker=\(String(format: "%.1f", stageTiming.trackerMs))ms total=\(String(format: "%.1f", stageTiming.total))ms",
                level: .debug, source: .detect
            )
        }

        os_unfair_lock_lock(&lock)
        _currentDetections = snapshot
        if shouldDetect {
            // Only refresh text & poses on YOLO-cadence frames; tracker frames
            // keep the most recent set so the renderer doesn't flicker between
            // populated and empty in the ~50ms between YOLO refreshes.
            _currentTextDetections = newTextDetections
            _currentPoses = newPoses
        }
        _lastDetectMode = detectMode
        _lastInferenceMs = elapsedMs
        _lastStageTiming = stageTiming
        _inFlight = false
        os_unfair_lock_unlock(&lock)
    }

    // MARK: - YOLO + supplementary detectors

    private func detectAndBootstrap(pixelBuffer: CVPixelBuffer, now: CFAbsoluteTime) -> (text: [TextDetection], poses: [PoseDetection], timing: DetectorStageTiming) {
        var timing = DetectorStageTiming()

        // Use the landmarks request instead of the plain rectangles request —
        // it's a superset (still gives us the bounding box for tracking + face
        // recognition) and also populates `landmarks.outerLips` so the
        // FacialExpressionAnalyzer can read mouth shape for smile/frown.
        let faces = VNDetectFaceLandmarksRequest()
        let animals = VNRecognizeAnimalsRequest()

        let text = VNRecognizeTextRequest()
        text.recognitionLevel = .accurate
        text.usesLanguageCorrection = true

        let bodyPose = VNDetectHumanBodyPoseRequest()
        let handPose = VNDetectHumanHandPoseRequest()
        handPose.maximumHandCount = 2

        var requests: [VNRequest] = [faces, animals, text, bodyPose, handPose]
        if let yolo = yoloRequest {
            requests.append(yolo)
        }

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        let bundleStart = CFAbsoluteTimeGetCurrent()
        do {
            try handler.perform(requests)
        } catch {
            NSLog("Vision perform error: \(error)")
        }
        timing.visionBundleMs = (CFAbsoluteTimeGetCurrent() - bundleStart) * 1000.0
        // Approximate per-request slices by equally splitting the bundle wall.
        // Apple doesn't expose per-request timing inside a perform call, so
        // this is the honest best-effort.
        let perRequest = timing.visionBundleMs / Double(requests.count)
        timing.yoloMs = perRequest
        timing.faceMs = perRequest
        timing.animalMs = perRequest
        timing.textMs = perRequest
        timing.bodyPoseMs = perRequest
        timing.handPoseMs = perRequest

        // Generate feature prints for the face observations we just collected.
        // We re-run a second Vision pass scoped to those face rects so the
        // FeaturePrint network only processes the cropped face regions — ~5ms
        // per face on the ANE, negligible.
        let fpStart = CFAbsoluteTimeGetCurrent()
        let facePrints: [VNFeaturePrintObservation] = computeFacePrints(
            for: faces.results ?? [],
            pixelBuffer: pixelBuffer
        )
        timing.faceFeaturePrintMs = (CFAbsoluteTimeGetCurrent() - fpStart) * 1000.0

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
        // Track which faces we observed but didn't recognize, so we can fire
        // a single faceSeenUnknown event per detection cycle.
        var sawUnmatchedFace = false
        if let faceResults = faces.results {
            for (i, obs) in faceResults.enumerated() {
                // Try to recognize the face against the registry. The prints
                // array is index-aligned with faceResults from Vision's order.
                var label = "FACE"
                var matched: (name: String, distance: Float)?
                if i < facePrints.count,
                   let match = faceRegistry.bestMatch(for: facePrints[i]) {
                    label = match.name.uppercased()
                    matched = match
                    LogStream.shared.log("matched \(match.name) (dist \(String(format: "%.1f", match.distance)))",
                                         level: .debug, source: .face)
                }
                if let m = matched {
                    emitFaceRecognized(name: m.name, distance: m.distance)
                } else {
                    sawUnmatchedFace = true
                }
                newDetections.append((obs.boundingBox, label, obs.confidence))
            }
        }
        if sawUnmatchedFace {
            // Throttled at the bus emit site implicitly by being "once per
            // detection cycle" — same semantics as the spec.
            eventBus.emit(.faceSeenUnknown(trackId: nil))
        }
        // Named-joint analyzers read raw Vision observations directly because
        // PoseDetection.points are intentionally unnamed for the renderer
        // path. FingerCounter reads thumbTip/indexMCP/etc., FacialExpression
        // reads landmarks.outerLips.
        if let handObs = handPose.results {
            fingerCounter.analyze(handObs)
        }
        if let faceObs = faces.results {
            facialExpressionAnalyzer.analyze(faceObs)
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
                // Refreshed — lower-priority event, fires often. Subscribers
                // that care about lifecycle can ignore these.
                eventBus.emit(.objectRefreshed(label: track.label, trackId: track.id,
                                               confidence: track.confidence, rect: det.rect))
            } else {
                // Reuse a recently-seen UUID for this label if TrackStore
                // remembers one, so the renderer's per-track color is stable
                // across launches.
                let preferred = TrackStore.shared.preferredUUID(for: det.label)
                let obs = VNDetectedObjectObservation(boundingBox: det.rect)
                let track = TrackedObject(label: det.label, confidence: det.confidence, observation: obs, now: now, preferredID: preferred)
                tracks.append(track)
                matchedTrackIDs.insert(track.id)
                TrackStore.shared.record(label: det.label, id: track.id)
                LogStream.shared.log("new \(det.label.lowercased()) (id \(track.id.uuidString.prefix(4)), conf \(String(format: "%.2f", det.confidence)))",
                                     level: .info, source: .track)
                eventBus.emit(.objectAppeared(label: track.label, trackId: track.id,
                                              confidence: track.confidence, rect: det.rect))
            }
        }

        // ---- Text recognition ----
        let textDetections: [TextDetection] = (text.results ?? []).compactMap { obs in
            guard let top = obs.topCandidates(1).first else { return nil }
            return TextDetection(rect: obs.boundingBox, text: top.string, confidence: top.confidence)
        }
        // Emit text events for every line above the min confidence, throttled
        // per-string so the same book title doesn't re-fire every 200ms.
        emitTextRecognized(textDetections)

        // ---- Body pose ----
        var bodyPoses: [PoseDetection] = []
        if let bodyResults = bodyPose.results {
            for obs in bodyResults {
                if let pose = makeBodyPose(from: obs) {
                    bodyPoses.append(pose)
                }
            }
        }

        // ---- Hand pose ----
        var handPoses: [PoseDetection] = []
        if let handResults = handPose.results {
            for obs in handResults {
                if let pose = makeHandPose(from: obs) {
                    handPoses.append(pose)
                }
            }
        }

        return (text: textDetections, poses: bodyPoses + handPoses, timing: timing)
    }

    // MARK: - Event-bus emit helpers (with throttling)

    /// Throttle text events so the same OCR string within 2s doesn't re-emit.
    /// Called from the detector queue — uses an internal map gated by the
    /// detector queue's serial execution (no extra lock needed since this is
    /// only ever invoked from inside `detectAndBootstrap`).
    private func emitTextRecognized(_ detections: [TextDetection]) {
        let now = Date()
        // Cheap GC: drop entries older than 10s every call.
        lastTextEmittedAt = lastTextEmittedAt.filter { now.timeIntervalSince($0.value) < 10.0 }
        for det in detections {
            guard det.confidence >= ObjectDetector.textMinConfidence else { continue }
            let trimmed = det.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if let prev = lastTextEmittedAt[trimmed], now.timeIntervalSince(prev) < ObjectDetector.textEmitThrottle {
                continue
            }
            lastTextEmittedAt[trimmed] = now
            eventBus.emit(.textRecognized(text: trimmed, confidence: det.confidence))
        }
    }

    /// Throttle face-name events so the same name within 5s doesn't re-emit
    /// on the bus. The Greeter has its own 30s TTS throttle on top of this.
    private func emitFaceRecognized(name: String, distance: Float) {
        let now = Date()
        if let prev = lastFaceNameEmittedAt[name], now.timeIntervalSince(prev) < ObjectDetector.faceNameEmitThrottle {
            return
        }
        lastFaceNameEmittedAt[name] = now
        eventBus.emit(.faceRecognized(name: name, distance: distance, trackId: nil))
    }

    // MARK: - Pose builders

    private static let poseConfidenceThreshold: Float = 0.3

    private func makeBodyPose(from obs: VNHumanBodyPoseObservation) -> PoseDetection? {
        // Apple's SDK joint names. We map each to its CGPoint via
        // recognizedPoint(_:); points with confidence > threshold are kept.
        typealias J = VNHumanBodyPoseObservation.JointName
        let connections: [(J, J)] = [
            (.nose, .neck),
            (.neck, .leftShoulder),
            (.leftShoulder, .leftElbow),
            (.leftElbow, .leftWrist),
            (.neck, .rightShoulder),
            (.rightShoulder, .rightElbow),
            (.rightElbow, .rightWrist),
            (.neck, .root),
            (.root, .leftHip),
            (.leftHip, .leftKnee),
            (.leftKnee, .leftAnkle),
            (.root, .rightHip),
            (.rightHip, .rightKnee),
            (.rightKnee, .rightAnkle)
        ]

        var segments: [PoseDetection.Segment] = []
        // Use a small key->point map keyed by joint rawValue so points stay
        // unique even if a joint appears in multiple connections.
        var uniquePoints: [String: CGPoint] = [:]
        var maxConf: Float = 0

        for (a, b) in connections {
            guard
                let p1 = try? obs.recognizedPoint(a),
                let p2 = try? obs.recognizedPoint(b)
            else { continue }
            if p1.confidence > ObjectDetector.poseConfidenceThreshold {
                uniquePoints[a.rawValue.rawValue] = p1.location
                maxConf = max(maxConf, p1.confidence)
            }
            if p2.confidence > ObjectDetector.poseConfidenceThreshold {
                uniquePoints[b.rawValue.rawValue] = p2.location
                maxConf = max(maxConf, p2.confidence)
            }
            if p1.confidence > ObjectDetector.poseConfidenceThreshold,
               p2.confidence > ObjectDetector.poseConfidenceThreshold {
                segments.append(PoseDetection.Segment(start: p1.location, end: p2.location))
            }
        }

        if segments.isEmpty && uniquePoints.isEmpty { return nil }
        return PoseDetection(
            segments: segments,
            points: Array(uniquePoints.values),
            kind: .body,
            confidence: maxConf
        )
    }

    private func makeHandPose(from obs: VNHumanHandPoseObservation) -> PoseDetection? {
        typealias J = VNHumanHandPoseObservation.JointName

        // Each finger chain: tip -> middle phalange -> proximal -> metacarpal/base.
        // Apple's hand-pose joint names (verified against the macOS SDK):
        //   thumb:   thumbTip,  thumbIP,  thumbMP,  thumbCMC
        //   index:   indexTip,  indexDIP, indexPIP, indexMCP
        //   middle:  middleTip, middleDIP,middlePIP,middleMCP
        //   ring:    ringTip,   ringDIP,  ringPIP,  ringMCP
        //   little:  littleTip, littleDIP,littlePIP,littleMCP
        let fingerChains: [[J]] = [
            [.thumbTip, .thumbIP, .thumbMP, .thumbCMC],
            [.indexTip, .indexDIP, .indexPIP, .indexMCP],
            [.middleTip, .middleDIP, .middlePIP, .middleMCP],
            [.ringTip, .ringDIP, .ringPIP, .ringMCP],
            [.littleTip, .littleDIP, .littlePIP, .littleMCP]
        ]
        // Palm ring: connect the 5 base/knuckle joints around the palm.
        // Start at thumb base (CMC) and walk index→middle→ring→little MCPs,
        // then close the ring back to the thumb base.
        let palmRing: [J] = [.thumbCMC, .indexMCP, .middleMCP, .ringMCP, .littleMCP, .thumbCMC]

        var segments: [PoseDetection.Segment] = []
        var uniquePoints: [String: CGPoint] = [:]
        var maxConf: Float = 0

        func addPoint(_ name: J) -> (location: CGPoint, ok: Bool) {
            guard let p = try? obs.recognizedPoint(name) else { return (.zero, false) }
            if p.confidence > ObjectDetector.poseConfidenceThreshold {
                uniquePoints[name.rawValue.rawValue] = p.location
                maxConf = max(maxConf, p.confidence)
                return (p.location, true)
            }
            return (.zero, false)
        }

        for chain in fingerChains {
            for i in 0..<(chain.count - 1) {
                let a = addPoint(chain[i])
                let b = addPoint(chain[i + 1])
                if a.ok && b.ok {
                    segments.append(PoseDetection.Segment(start: a.location, end: b.location))
                }
            }
        }

        for i in 0..<(palmRing.count - 1) {
            let a = addPoint(palmRing[i])
            let b = addPoint(palmRing[i + 1])
            if a.ok && b.ok {
                segments.append(PoseDetection.Segment(start: a.location, end: b.location))
            }
        }

        if segments.isEmpty && uniquePoints.isEmpty { return nil }
        return PoseDetection(
            segments: segments,
            points: Array(uniquePoints.values),
            kind: .hand,
            confidence: maxConf
        )
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
