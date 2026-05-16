import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Metal
import QuartzCore

/// Captures the rendered Metal drawable into an H.264 .mov on the user's
/// Desktop. Designed to be wired into `Renderer.frameTap` — the renderer hands
/// us the drawable's MTLTexture each frame and we synchronously blit + copy
/// the bytes into a CVPixelBuffer, then append via an
/// `AVAssetWriterInputPixelBufferAdaptor`.
///
/// V1 design intentionally takes the simple synchronous path:
///   blit drawable → shared MTLTexture, waitUntilCompleted, getBytes →
///   CVPixelBuffer, appendPixelBuffer.
///
/// At 1080p this costs ~5–15 ms per frame on the render thread. At a 60 fps
/// target this can cause some renderer backpressure, but the recording itself
/// remains watchable (effective 30–45 fps). A later optimization could move to
/// a ring of shared textures + an async background appender, but that's a
/// substantial restructure and not needed for the POC.
@MainActor
final class Recorder {

    // MARK: - Public state

    private(set) var isRecording: Bool = false

    // MARK: - Configuration

    /// Target frame rate hint for the H.264 encoder. The actual cadence is
    /// driven by render frame arrivals.
    private let targetFPS: Int = 60
    /// Average video bitrate in bits per second. ~12 Mbps is a reasonable
    /// quality/size trade for 1080p screen content.
    private let bitrate: Int = 12_000_000

    // MARK: - AVAssetWriter plumbing

    private var assetWriter: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var outputURL: URL?

    // MARK: - Metal staging

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    /// CPU-readable staging texture we blit the drawable into each frame.
    /// Allocated once at startRecording so we don't pay the cost per frame.
    private var stagingTexture: MTLTexture?

    // MARK: - Timing

    private var recordStartTime: CFTimeInterval = 0
    private var frameCount: Int = 0
    private var lastDropLogTime: CFTimeInterval = 0
    private var droppedSinceLastLog: Int = 0

    // MARK: - Init

    init?(device: MTLDevice) {
        guard let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.commandQueue = queue
    }

    // MARK: - Lifecycle

    /// Begin recording. Returns true on success.
    func startRecording(width: Int, height: Int) -> Bool {
        guard !isRecording else { return false }
        guard width > 0, height > 0 else {
            LogStream.shared.log(
                "recorder: invalid dimensions \(width)x\(height)",
                level: .warn,
                source: .render
            )
            return false
        }

        let url = Self.makeOutputURL()

        // Drop any stale file at the same path (extremely unlikely given the
        // timestamp filename).
        try? FileManager.default.removeItem(at: url)

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        } catch {
            LogStream.shared.log(
                "recorder: failed to create AVAssetWriter: \(error.localizedDescription)",
                level: .error,
                source: .render
            )
            return false
        }

        let compressionProps: [String: Any] = [
            AVVideoAverageBitRateKey: bitrate,
            AVVideoExpectedSourceFrameRateKey: targetFPS,
            AVVideoMaxKeyFrameIntervalKey: targetFPS * 2,
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
        ]
        let outputSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compressionProps
        ]

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
        input.expectsMediaDataInRealTime = true

        // Source pixel buffer attributes — BGRA matches the Metal drawable so
        // we can do a straight memcpy in writeFrame.
        let sourcePixelBufferAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: sourcePixelBufferAttrs
        )

        guard writer.canAdd(input) else {
            LogStream.shared.log(
                "recorder: writer cannot add input",
                level: .error,
                source: .render
            )
            return false
        }
        writer.add(input)

        guard writer.startWriting() else {
            LogStream.shared.log(
                "recorder: startWriting failed: \(writer.error?.localizedDescription ?? "unknown")",
                level: .error,
                source: .render
            )
            return false
        }
        writer.startSession(atSourceTime: .zero)

        // Pre-allocate the CPU-readable staging texture used for every frame.
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.usage = [.shaderRead]
        desc.storageMode = .shared
        guard let staging = device.makeTexture(descriptor: desc) else {
            LogStream.shared.log(
                "recorder: failed to allocate staging texture",
                level: .error,
                source: .render
            )
            writer.cancelWriting()
            return false
        }

        self.assetWriter = writer
        self.writerInput = input
        self.pixelBufferAdaptor = adaptor
        self.outputURL = url
        self.stagingTexture = staging
        self.recordStartTime = CACurrentMediaTime()
        self.frameCount = 0
        self.droppedSinceLastLog = 0
        self.lastDropLogTime = 0
        self.isRecording = true

        LogStream.shared.log(
            "recording started → \(url.path)",
            level: .info,
            source: .render
        )
        return true
    }

    /// Stop recording. Fires `completion` with the output URL on success or
    /// nil on failure. Safe to call when not recording (completion fires with
    /// nil).
    func stopRecording(completion: @escaping (URL?) -> Void) {
        guard isRecording,
              let writer = assetWriter,
              let input = writerInput else {
            completion(nil)
            return
        }

        // Capture values we need inside the finish callback before we tear
        // them down on the MainActor.
        let url = outputURL
        let writtenFrames = frameCount

        isRecording = false
        input.markAsFinished()

        // Capture the completion in a Sendable-safe shuttle so we can pass it
        // across the writer's queue and the MainActor hop. The closure type
        // `(URL?) -> Void` isn't formally Sendable, but the caller invokes us
        // from MainActor and we only call it again from MainActor, so the
        // unsafe wrapper is honest about that contract.
        nonisolated(unsafe) let completionShuttle: (URL?) -> Void = completion

        writer.finishWriting { [weak self] in
            // Pull everything we need off the writer on its own queue before
            // hopping; AVAssetWriter isn't Sendable so we mustn't capture it
            // into the Task block.
            let status = writer.status
            let errorDescription = writer.error?.localizedDescription
            let finalURL: URL? = (status == .completed) ? url : nil

            Task { @MainActor in
                guard let self = self else {
                    completionShuttle(finalURL)
                    return
                }
                self.assetWriter = nil
                self.writerInput = nil
                self.pixelBufferAdaptor = nil
                self.outputURL = nil
                self.stagingTexture = nil

                if let finalURL = finalURL {
                    LogStream.shared.log(
                        "recording stopped, wrote \(writtenFrames) frames — saved \(finalURL.lastPathComponent)",
                        level: .info,
                        source: .render
                    )
                } else {
                    LogStream.shared.log(
                        "recording stopped, writer failed: \(errorDescription ?? "unknown")",
                        level: .error,
                        source: .render
                    )
                }
                completionShuttle(finalURL)
            }
        }
    }

    // MARK: - Frame ingest

    /// Hook this into `Renderer.frameTap`. When not recording, returns
    /// immediately. When recording, synchronously blits the drawable into our
    /// staging texture, copies into a pool-issued CVPixelBuffer, and appends
    /// it to the asset writer.
    func writeFrame(texture: MTLTexture, time: CFTimeInterval) {
        guard isRecording,
              let input = writerInput,
              let adaptor = pixelBufferAdaptor,
              let staging = stagingTexture else {
            return
        }

        // Drawable pixel format guard — we keyed off `.bgra8Unorm` everywhere,
        // including the CVPixelBufferPool. If the drawable comes through with
        // anything else, the byte layout assumption is wrong; bail instead of
        // writing garbage.
        guard texture.pixelFormat == .bgra8Unorm else {
            logDroppedFrame(reason: "non-bgra drawable")
            return
        }

        // Dimensions must match the writer's configured size. If the window
        // resized mid-recording the staging texture won't match; drop the
        // frame rather than corrupt the output stride.
        guard texture.width == staging.width,
              texture.height == staging.height else {
            logDroppedFrame(reason: "size mismatch")
            return
        }

        if !input.isReadyForMoreMediaData {
            logDroppedFrame(reason: "writer not ready")
            return
        }

        // Synchronous blit → staging texture. The drawable's storage mode is
        // .private on macOS, so we cannot getBytes from it directly. ~1ms.
        guard let cmd = commandQueue.makeCommandBuffer(),
              let blit = cmd.makeBlitCommandEncoder() else {
            logDroppedFrame(reason: "no command buffer")
            return
        }
        blit.copy(from: texture, to: staging)
        blit.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()

        // Pull a pixel buffer out of the adaptor's pool. The pool reuses
        // buffers so this is cheap after the first few frames.
        guard let pool = adaptor.pixelBufferPool else {
            logDroppedFrame(reason: "no pool")
            return
        }
        var pixelBufferOut: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBufferOut)
        guard status == kCVReturnSuccess, let pixelBuffer = pixelBufferOut else {
            logDroppedFrame(reason: "pool exhausted (\(status))")
            return
        }

        // Copy staging texture bytes into the pixel buffer. We respect the
        // pixel buffer's bytesPerRow because Core Video commonly aligns rows
        // to 16/64 bytes, which won't match `width * 4` exactly.
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            logDroppedFrame(reason: "pixel buffer base nil")
            return
        }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let region = MTLRegionMake2D(0, 0, staging.width, staging.height)
        staging.getBytes(
            base,
            bytesPerRow: bytesPerRow,
            from: region,
            mipmapLevel: 0
        )

        let presentationTime = CMTime(
            seconds: max(0, time - recordStartTime),
            preferredTimescale: 600
        )

        if adaptor.append(pixelBuffer, withPresentationTime: presentationTime) {
            frameCount &+= 1
        } else {
            logDroppedFrame(reason: "append failed")
        }
    }

    // MARK: - Helpers

    /// Logs dropped frames at most once per second to avoid spamming the log
    /// buffer during sustained backpressure.
    private func logDroppedFrame(reason: String) {
        droppedSinceLastLog &+= 1
        let now = CACurrentMediaTime()
        if now - lastDropLogTime >= 1.0 {
            LogStream.shared.log(
                "dropped frame: \(reason) (×\(droppedSinceLastLog) in last second)",
                level: .warn,
                source: .render
            )
            lastDropLogTime = now
            droppedSinceLastLog = 0
        }
    }

    private static func makeOutputURL() -> URL {
        // Recorder is @MainActor so this call is safe.
        let dir = OutputLocations.recordingDirectory()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let stamp = formatter.string(from: Date())
        return dir.appendingPathComponent("VisionPOC-\(stamp).mov")
    }
}
