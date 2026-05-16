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
    private var currentInput: AVCaptureDeviceInput?
    private var output: AVCaptureVideoDataOutput?

    private var lock = os_unfair_lock_s()
    private var latest: Frame?
    private var _permissionDenied = false
    private var _deviceDisconnected = false
    private var _width: Int = 1920
    private var _height: Int = 1080
    private var _activeDeviceUniqueID: String?

    init(device: MTLDevice) {
        self.device = device
        super.init()
        var cache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        if status != kCVReturnSuccess {
            NSLog("CVMetalTextureCacheCreate failed: \(status)")
        }
        self.textureCache = cache

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDeviceDisconnected(_:)),
            name: .AVCaptureDeviceWasDisconnected,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    var permissionDenied: Bool {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        // Treat disconnect as "permission denied" so renderer falls back to its
        // existing "WAITING FOR CAMERA…" status path without modification.
        return _permissionDenied || _deviceDisconnected
    }

    var deviceDisconnected: Bool {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return _deviceDisconnected
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

    var activeDeviceUniqueID: String? {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return _activeDeviceUniqueID
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
        LogStream.shared.log("camera permission denied — grant access in System Settings › Privacy & Security › Camera",
                             level: .error, source: .camera)
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
                deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
                mediaType: .video,
                position: .unspecified
            )
            let camera = discovery.devices.first(where: { $0.position == .front })
                ?? AVCaptureDevice.default(for: .video)
                ?? discovery.devices.first

            guard let camera else {
                self.session.commitConfiguration()
                LogStream.shared.log("no video capture device available", level: .error, source: .camera)
                return
            }

            LogStream.shared.log("using camera \"\(camera.localizedName)\" (position \(camera.position.rawValue))",
                                 level: .info, source: .camera)

            do {
                let input = try AVCaptureDeviceInput(device: camera)
                if self.session.canAddInput(input) {
                    self.session.addInput(input)
                    self.currentInput = input
                }
            } catch {
                self.session.commitConfiguration()
                LogStream.shared.log("failed to create AVCaptureDeviceInput: \(error)", level: .error, source: .camera)
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
            self.output = output

            os_unfair_lock_lock(&self.lock)
            self._activeDeviceUniqueID = camera.uniqueID
            os_unfair_lock_unlock(&self.lock)

            self.session.commitConfiguration()
            self.session.startRunning()
            LogStream.shared.log("session running, preset \(Theme.Performance.capturePreset.rawValue)",
                                 level: .info, source: .camera)
        }
    }

    /// Switch the running session over to a different camera device. Safe to call
    /// from the main thread — actual session reconfiguration happens on sessionQueue.
    func switchToDevice(_ device: AVCaptureDevice) {
        sessionQueue.async { [weak self] in
            guard let self else { return }

            if self.session.isRunning {
                self.session.stopRunning()
            }

            self.session.beginConfiguration()

            if let existing = self.currentInput {
                self.session.removeInput(existing)
                self.currentInput = nil
            }

            do {
                let input = try AVCaptureDeviceInput(device: device)
                if self.session.canAddInput(input) {
                    self.session.addInput(input)
                    self.currentInput = input
                } else {
                    self.session.commitConfiguration()
                    LogStream.shared.log("cannot add input for \(device.localizedName)", level: .error, source: .camera)
                    return
                }
            } catch {
                self.session.commitConfiguration()
                LogStream.shared.log("failed to create input for \(device.localizedName): \(error)",
                                     level: .error, source: .camera)
                return
            }

            // If the output got dropped (e.g., never created yet), re-add it.
            if self.output == nil {
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
                self.output = output
            }

            os_unfair_lock_lock(&self.lock)
            self._activeDeviceUniqueID = device.uniqueID
            self._deviceDisconnected = false
            // Best-effort default; real dimensions arrive with the first sample buffer.
            self._width = 1920
            self._height = 1080
            os_unfair_lock_unlock(&self.lock)

            self.session.commitConfiguration()
            self.session.startRunning()

            LogStream.shared.log("switched to \(device.localizedName)", level: .info, source: .camera)
        }
    }

    @objc private func handleDeviceDisconnected(_ note: Notification) {
        guard let disconnected = note.object as? AVCaptureDevice else { return }

        os_unfair_lock_lock(&lock)
        let activeID = _activeDeviceUniqueID
        os_unfair_lock_unlock(&lock)

        guard disconnected.uniqueID == activeID else { return }

        let name = disconnected.localizedName
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning {
                self.session.stopRunning()
            }
            os_unfair_lock_lock(&self.lock)
            self._deviceDisconnected = true
            self.latest = nil
            os_unfair_lock_unlock(&self.lock)
            LogStream.shared.log("camera \(name) disconnected", level: .warn, source: .camera)
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
