import AVFoundation
import CoreVideo
import Metal
import os

/// Owns the AVCaptureSession and vends the most recent frame as both an MTLTexture
/// (zero-copy via CVMetalTextureCache) and the originating CVPixelBuffer.
///
/// The latest texture and pixel buffer must be held together: the MTLTexture only
/// remains valid while its backing CVPixelBuffer is retained (otherwise the IOSurface
/// gets recycled).
final class CameraCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private struct Frame {
        let pixelBuffer: CVPixelBuffer
        let texture: MTLTexture
        let width: Int
        let height: Int
    }

    private let device: MTLDevice
    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.dmdbrands.VisionPOC.capture.session")
    private let sampleQueue = DispatchQueue(label: "com.dmdbrands.VisionPOC.capture.samples")
    private var textureCache: CVMetalTextureCache?

    private var lock = os_unfair_lock_s()
    private var latest: Frame?
    private var _permissionDenied = false
    private var _width: Int = 1920
    private var _height: Int = 1080

    init(device: MTLDevice) {
        self.device = device
        super.init()
        var cache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        if status != kCVReturnSuccess {
            NSLog("CVMetalTextureCacheCreate failed: \(status)")
        }
        self.textureCache = cache
    }

    var permissionDenied: Bool {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return _permissionDenied
    }

    var width: Int {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return _width
    }

    var height: Int {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return _height
    }

    func latestTexture() -> MTLTexture? {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return latest?.texture
    }

    func latestPixelBuffer() -> CVPixelBuffer? {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return latest?.pixelBuffer
    }

    func start() async {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            configureAndStart()
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            if granted {
                configureAndStart()
            } else {
                setPermissionDenied()
            }
        case .denied, .restricted:
            setPermissionDenied()
        @unknown default:
            setPermissionDenied()
        }
    }

    private func setPermissionDenied() {
        os_unfair_lock_lock(&lock)
        _permissionDenied = true
        os_unfair_lock_unlock(&lock)
    }

    private func configureAndStart() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.session.beginConfiguration()

            let preset = AVCaptureSession.Preset(rawValue: Theme.Performance.capturePreset.rawValue)
            if self.session.canSetSessionPreset(preset) {
                self.session.sessionPreset = preset
            }

            let discovery = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.builtInWideAngleCamera, .external],
                mediaType: .video,
                position: .unspecified
            )
            let camera = discovery.devices.first(where: { $0.position == .front })
                ?? AVCaptureDevice.default(for: .video)
                ?? discovery.devices.first

            guard let camera else {
                self.session.commitConfiguration()
                NSLog("No video capture device available.")
                return
            }

            do {
                let input = try AVCaptureDeviceInput(device: camera)
                if self.session.canAddInput(input) {
                    self.session.addInput(input)
                }
            } catch {
                self.session.commitConfiguration()
                NSLog("Failed to create AVCaptureDeviceInput: \(error)")
                return
            }

            let output = AVCaptureVideoDataOutput()
            output.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferMetalCompatibilityKey as String: true
            ]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: self.sampleQueue)
            if self.session.canAddOutput(output) {
                self.session.addOutput(output)
            }

            self.session.commitConfiguration()
            self.session.startRunning()
        }
    }

    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let cache = textureCache else { return }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        var cvTexture: CVMetalTexture?
        let result = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            cache,
            pixelBuffer,
            nil,
            .bgra8Unorm,
            width,
            height,
            0,
            &cvTexture
        )
        guard result == kCVReturnSuccess,
              let cvTexture,
              let metalTexture = CVMetalTextureGetTexture(cvTexture) else {
            return
        }

        let frame = Frame(pixelBuffer: pixelBuffer, texture: metalTexture, width: width, height: height)
        os_unfair_lock_lock(&lock)
        latest = frame
        _width = width
        _height = height
        os_unfair_lock_unlock(&lock)

        CVMetalTextureCacheFlush(cache, 0)
    }
}
