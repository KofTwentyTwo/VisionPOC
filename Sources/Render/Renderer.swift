import MetalKit
import AppKit
import simd
import os
import ImageIO
import UniformTypeIdentifiers

/// Camera textures coming from AVFoundation are stored origin-top-left. The MSL
/// `quad_vertex` shader emits UVs with `v = 1.0 - v` so image samples appear right-side-up
/// on screen. Vision boundingBoxes are normalized [0..1] with origin bottom-left,
/// matching Metal NDC y-up after the same flip — so detection rects line up with the
/// LIVE/JARVIS panes without further adjustment.
///
/// Shader-side contracts (must match Sources/Shaders/*.metal):
/// - `quad_vertex(vertex_id)` emits a fullscreen NDC quad with UVs that flip v.
/// - `box_vertex` reads BoxUniforms { float4 rect (NDC xy origin + zw size); float4 color }
///   at vertex buffer index 0 and emits 8 line vertices for vertex_ids 0..7 forming
///   a rectangle outline, OR 6 triangle vertices for vertex_ids 0..5 forming a filled quad.
///   We use the line interpretation here (drawPrimitives(.line, vertexCount: 8)) for boxes.
/// - `text_fragment` samples texture index 0 (BGRA premultiplied) and multiplies by
///   the tint at fragment buffer index 0 (single float4).
final class Renderer: NSObject, MTKViewDelegate {
    private struct BoxUniforms {
        var rect: SIMD4<Float>
        var color: SIMD4<Float>
        var params: SIMD4<Float>   // x = mode (0=hollow stroke, 1=solid fill), y/z/w reserved
    }

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let library: MTLLibrary
    private let pipelines: Pipelines

    private let capture: CameraCapture
    private let detector: ObjectDetector
    private let edgePass: EdgePass
    private let jarvisPass: JarvisStylePass
    private let asciiPass: AsciiPass

    private let textRasterizer: TextRasterizer
    private var labelTextureCache: [String: MTLTexture] = [:]
    /// Parallel array tracking access order for `labelTextureCache`. Head is
    /// LRU, tail is MRU. On cache hit, move-to-end. On cache miss with the
    /// cache at capacity, drop head before inserting.
    private var labelTextureCacheKeys: [String] = []
    private let labelTextureCacheCapacity = 128
    private let nearestSampler: MTLSamplerState
    private let linearSampler: MTLSamplerState

    /// Set by `snapshotPNG()` on a non-render thread. The next `draw(in:)`
    /// pass renders normally, then copies the drawable's texture into a
    /// CPU-readable MTLTexture, encodes it as PNG, fires this completion,
    /// and clears the flag.
    private var pendingSnapshotCompletion: ((Data?) -> Void)?
    /// Guards `pendingSnapshotCompletion` so the snapshot caller (background)
    /// and the render loop (MainActor) don't race on read/write.
    private var snapshotLock = os_unfair_lock_s()

    private let startTime: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    private var lastFrameTime: CFAbsoluteTime
    private var frameCounter: Int = 0
    private var smoothedFPS: Double = 60

    private var paneLabelTextures: [MTLTexture?] = [nil, nil, nil, nil]
    private var footerTexture: MTLTexture?
    private var statusTexture: MTLTexture?
    private var statusText: String = ""
    private var backingScale: CGFloat = 2.0

    init?(
        view: MTKView,
        device: MTLDevice,
        capture: CameraCapture,
        detector: ObjectDetector,
        edgePass: EdgePass,
        jarvisPass: JarvisStylePass,
        asciiPass: AsciiPass
    ) {
        guard let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary() else {
            return nil
        }
        do {
            self.pipelines = try Pipelines(device: device, library: library)
        } catch {
            NSLog("Failed to build pipelines: \(error)")
            return nil
        }
        self.device = device
        self.commandQueue = queue
        self.library = library
        self.capture = capture
        self.detector = detector
        self.edgePass = edgePass
        self.jarvisPass = jarvisPass
        self.asciiPass = asciiPass
        self.textRasterizer = TextRasterizer(device: device)
        self.lastFrameTime = CFAbsoluteTimeGetCurrent()

        let nearestDesc = MTLSamplerDescriptor()
        nearestDesc.minFilter = .nearest
        nearestDesc.magFilter = .nearest
        nearestDesc.sAddressMode = .clampToEdge
        nearestDesc.tAddressMode = .clampToEdge
        guard let nearest = device.makeSamplerState(descriptor: nearestDesc) else { return nil }
        self.nearestSampler = nearest

        let linearDesc = MTLSamplerDescriptor()
        linearDesc.minFilter = .linear
        linearDesc.magFilter = .linear
        linearDesc.sAddressMode = .clampToEdge
        linearDesc.tAddressMode = .clampToEdge
        guard let linear = device.makeSamplerState(descriptor: linearDesc) else { return nil }
        self.linearSampler = linear

        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // No-op: everything is normalized.
    }

    func draw(in view: MTKView) {
        let now = CFAbsoluteTimeGetCurrent()
        let deltaTime = Float(now - lastFrameTime)
        lastFrameTime = now
        let elapsed = Float(now - startTime)
        frameCounter &+= 1

        if deltaTime > 0 {
            let instant = 1.0 / Double(deltaTime)
            smoothedFPS = smoothedFPS * 0.92 + instant * 0.08
        }

        backingScale = view.window?.backingScaleFactor ?? 2.0
        let drawableSize = view.drawableSize

        guard let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            return
        }
        descriptor.colorAttachments[0].loadAction = .clear
        let bg = Theme.Palette.background
        descriptor.colorAttachments[0].clearColor = MTLClearColor(
            red: Double(bg.x), green: Double(bg.y), blue: Double(bg.z), alpha: Double(bg.w)
        )

        guard let source = capture.latestTexture() else {
            drawStatusOnly(
                commandBuffer: commandBuffer,
                descriptor: descriptor,
                drawableSize: drawableSize
            )
            commandBuffer.present(drawable)
            commandBuffer.commit()
            return
        }

        if let pb = capture.latestPixelBuffer() {
            detector.submit(pixelBuffer: pb)
        }

        let edgesTexture = edgePass.encode(source: source, commandBuffer: commandBuffer)

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            commandBuffer.commit()
            return
        }

        let panes = Theme.Layout.panes
        let detections = detector.currentDetections()
        let sourceAspect: CGFloat = {
            let w = max(1, capture.width)
            let h = max(1, capture.height)
            return CGFloat(w) / CGFloat(h)
        }()

        // Per-pane aspect-fit inner rect. Letterboxes the video content so the
        // image keeps its source aspect ratio even when the pane is a
        // different shape; brackets and detection overlays follow the inner
        // rect so the HUD frames the video itself, not the bounding cell.
        var innerRects: [CGRect] = []
        innerRects.reserveCapacity(panes.count)

        for index in 0..<panes.count {
            let paneRect = pixelRect(panes[index], in: drawableSize)
            let inner = aspectFitRect(into: paneRect, sourceAspect: sourceAspect)
            innerRects.append(inner)
            setViewport(encoder: encoder, rect: inner)

            switch index {
            case 0:
                drawImage(encoder: encoder, pipeline: pipelines.live, texture: source, sampler: linearSampler)
            case 1:
                drawJarvis(encoder: encoder, texture: source, time: elapsed, paneSize: inner.size)
                drawDetections(encoder: encoder, detections: detections)
                drawDetectionLabels(encoder: encoder, detections: detections, paneRect: inner)
                let texts = detector.currentTextDetections()
                drawTextDetections(encoder: encoder, texts: texts, paneRect: inner)
                let poses = detector.currentPoses()
                drawPoses(encoder: encoder, poses: poses, paneRect: inner)
            case 2:
                drawImage(encoder: encoder, pipeline: pipelines.edges, texture: edgesTexture, sampler: nearestSampler)
            case 3:
                drawAscii(encoder: encoder, texture: source, paneSize: inner.size)
            default:
                break
            }
        }

        drawCornerBrackets(encoder: encoder, drawableSize: drawableSize, innerRects: innerRects)
        drawPaneLabels(encoder: encoder, drawableSize: drawableSize, innerRects: innerRects)
        drawFooter(encoder: encoder, drawableSize: drawableSize)

        encoder.endEncoding()

        // Snapshot path — piggyback on this frame's command buffer. We blit
        // the drawable's texture into a CPU-readable shared-storage texture,
        // then synchronously wait for the GPU to finish before reading back
        // and encoding as PNG. ~10-30ms typical (dominated by waitUntilCompleted).
        let snapshotCompletion = takePendingSnapshotCompletion()
        if let completion = snapshotCompletion {
            let readback = makeReadbackTexture(matching: drawable.texture)
            if let readback,
               let blit = commandBuffer.makeBlitCommandEncoder() {
                blit.copy(from: drawable.texture, to: readback)
                blit.endEncoding()
                commandBuffer.present(drawable)
                commandBuffer.commit()
                commandBuffer.waitUntilCompleted()
                let data = encodePNG(from: readback)
                completion(data)
            } else {
                // Couldn't allocate readback; fail gracefully.
                commandBuffer.present(drawable)
                commandBuffer.commit()
                completion(nil)
            }
        } else {
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }

    // MARK: - Snapshot

    /// Public synchronous API. Sets the pending-completion flag, waits via a
    /// semaphore for the next render loop to fulfill it, returns the PNG
    /// data (or nil on failure). Safe to call off the MainActor; the wait is
    /// at most ~30ms per shot.
    func snapshotPNG() -> Data? {
        let semaphore = DispatchSemaphore(value: 0)
        // Capture into a class-level Sendable box so the completion can write
        // it from whatever thread fires the completion.
        let box = SnapshotBox()
        let completion: (Data?) -> Void = { data in
            box.data = data
            semaphore.signal()
        }
        os_unfair_lock_lock(&snapshotLock)
        // If a previous snapshot is still in flight, fail this one rather
        // than stomp on it. The caller can retry.
        if pendingSnapshotCompletion != nil {
            os_unfair_lock_unlock(&snapshotLock)
            return nil
        }
        pendingSnapshotCompletion = completion
        os_unfair_lock_unlock(&snapshotLock)

        // 1 second is generous; if the render loop is stalled for longer than
        // that, returning nil and letting the user retry is better than
        // hanging the menu thread forever.
        let result = semaphore.wait(timeout: .now() + .seconds(1))
        if result == .timedOut {
            os_unfair_lock_lock(&snapshotLock)
            pendingSnapshotCompletion = nil
            os_unfair_lock_unlock(&snapshotLock)
            return nil
        }
        return box.data
    }

    private final class SnapshotBox: @unchecked Sendable {
        var data: Data?
    }

    private func takePendingSnapshotCompletion() -> ((Data?) -> Void)? {
        os_unfair_lock_lock(&snapshotLock)
        let c = pendingSnapshotCompletion
        pendingSnapshotCompletion = nil
        os_unfair_lock_unlock(&snapshotLock)
        return c
    }

    /// Allocates a shared-storage texture matching the given drawable texture's
    /// dimensions and pixel format, so its bytes are CPU-addressable after the
    /// blit completes. The drawable's own texture has private storage and
    /// cannot be read back directly.
    private func makeReadbackTexture(matching source: MTLTexture) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: source.pixelFormat,
            width: source.width,
            height: source.height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        return device.makeTexture(descriptor: descriptor)
    }

    private func encodePNG(from texture: MTLTexture) -> Data? {
        let width = texture.width
        let height = texture.height
        let bytesPerRow = width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        let region = MTLRegionMake2D(0, 0, width, height)
        bytes.withUnsafeMutableBytes { ptr in
            if let base = ptr.baseAddress {
                texture.getBytes(base, bytesPerRow: bytesPerRow, from: region, mipmapLevel: 0)
            }
        }

        // Drawable is bgra8Unorm. CGBitmapContext wants the byte order spelled
        // out via CGBitmapInfo: byteOrder32Little + premultipliedFirst means
        // memory layout BGRA, which matches the texture exactly — no swizzle.
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo: CGBitmapInfo = [
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue),
            .byteOrder32Little
        ]
        guard let context = bytes.withUnsafeMutableBytes({ ptr -> CGContext? in
            CGContext(
                data: ptr.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: bitmapInfo.rawValue
            )
        }) else {
            return nil
        }
        guard let cgImage = context.makeImage() else { return nil }

        let nsData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            nsData as CFMutableData,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return nsData as Data
    }

    // MARK: - No-source path

    private func drawStatusOnly(
        commandBuffer: MTLCommandBuffer,
        descriptor: MTLRenderPassDescriptor,
        drawableSize: CGSize
    ) {
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }

        let message = capture.permissionDenied
            ? "CAMERA PERMISSION DENIED — grant access in System Settings › Privacy & Security › Camera"
            : "WAITING FOR CAMERA…"

        if statusTexture == nil || message != statusText {
            statusText = message
            statusTexture = makeLabelTexture(message, font: Theme.Font.body(Theme.Font.paneLabelSize), wide: true)
        }

        if let texture = statusTexture {
            let widthPx = CGFloat(texture.width) / backingScale * backingScale
            let heightPx = CGFloat(texture.height) / backingScale * backingScale
            let rect = CGRect(
                x: (drawableSize.width - widthPx) * 0.5,
                y: (drawableSize.height - heightPx) * 0.5,
                width: widthPx,
                height: heightPx
            )
            setViewport(encoder: encoder, rect: rect)
            drawTextQuad(encoder: encoder, texture: texture, tint: Theme.Palette.label)
        }

        encoder.endEncoding()
    }

    // MARK: - Drawing helpers

    /// Returns the largest rect that fits inside `pane` while preserving
    /// `sourceAspect`. Centers the result horizontally and vertically so the
    /// letterbox bars are symmetric. Used to keep camera video square with the
    /// source even when the pane cell isn't.
    private func aspectFitRect(into pane: CGRect, sourceAspect: CGFloat) -> CGRect {
        guard pane.width > 0, pane.height > 0, sourceAspect > 0 else { return pane }
        let paneAspect = pane.width / pane.height
        if abs(paneAspect - sourceAspect) < 0.001 {
            return pane
        }
        var width = pane.width
        var height = pane.height
        if paneAspect > sourceAspect {
            // Pane is wider than the source — shrink width, keep height.
            width = pane.height * sourceAspect
        } else {
            // Pane is taller than the source — shrink height, keep width.
            height = pane.width / sourceAspect
        }
        let originX = pane.origin.x + (pane.width - width) * 0.5
        let originY = pane.origin.y + (pane.height - height) * 0.5
        return CGRect(x: originX, y: originY, width: width, height: height)
    }

    private func pixelRect(_ normalized: CGRect, in size: CGSize) -> CGRect {
        // Theme rects are origin bottom-left. MTLViewport originY is top-left in pixels.
        let originX = normalized.origin.x * size.width
        let originY = (1.0 - normalized.origin.y - normalized.height) * size.height
        return CGRect(
            x: originX,
            y: originY,
            width: normalized.width * size.width,
            height: normalized.height * size.height
        )
    }

    private func setViewport(encoder: MTLRenderCommandEncoder, rect: CGRect) {
        let viewport = MTLViewport(
            originX: Double(rect.origin.x),
            originY: Double(rect.origin.y),
            width: Double(rect.width),
            height: Double(rect.height),
            znear: 0, zfar: 1
        )
        encoder.setViewport(viewport)
    }

    private func drawImage(
        encoder: MTLRenderCommandEncoder,
        pipeline: MTLRenderPipelineState,
        texture: MTLTexture,
        sampler: MTLSamplerState
    ) {
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }

    private func drawJarvis(
        encoder: MTLRenderCommandEncoder,
        texture: MTLTexture,
        time: Float,
        paneSize: CGSize
    ) {
        encoder.setRenderPipelineState(pipelines.jarvis)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentSamplerState(linearSampler, index: 0)
        var uniforms = jarvisPass.uniforms(time: time, viewportSize: paneSize)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<JarvisUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }

    private func drawDetections(encoder: MTLRenderCommandEncoder, detections: [Detection]) {
        encoder.setRenderPipelineState(pipelines.boxes)
        for detection in detections {
            // Vision boundingBox: normalized [0..1] origin bottom-left.
            // Viewport NDC: origin bottom-left of the viewport, range [-1..1].
            let r = detection.rect
            let originNDC = SIMD2<Float>(Float(r.origin.x) * 2 - 1, Float(r.origin.y) * 2 - 1)
            let sizeNDC = SIMD2<Float>(Float(r.width) * 2, Float(r.height) * 2)
            var uniforms = BoxUniforms(
                rect: SIMD4<Float>(originNDC.x, originNDC.y, sizeNDC.x, sizeNDC.y),
                color: boxColor(for: detection),
                params: SIMD4<Float>(0, 0, 0, 0)   // mode 0 = hollow stroke
            )
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<BoxUniforms>.stride, index: 0)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<BoxUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }
    }

    /// Cyan for face/identity labels, per-track hue for everything else.
    /// Face labels are recognizable enough on their own that a stable cyan
    /// makes the UI feel less chaotic than randomized hues.
    private func boxColor(for detection: Detection) -> SIMD4<Float> {
        if isFaceLabel(detection.label) {
            return Theme.Palette.boxStroke
        }
        return ColorHash.colorFor(trackId: detection.trackId)
    }

    private func isFaceLabel(_ label: String) -> Bool {
        if label == "FACE" { return true }
        // FaceRegistry names are uppercased before being assigned as a label
        // (see ObjectDetector.detectAndBootstrap). Anything in the registry
        // should keep the cyan stroke. Falling back to "all caps single word"
        // would accidentally include YOLO labels like CUP; check the registry
        // instead. The enrolledNames() call is cheap (dictionary keys snapshot
        // behind a small lock); we run it at most once per detection per frame.
        let names = detector.faceRegistry.enrolledNames()
        return names.contains(where: { $0.uppercased() == label })
    }

    private func drawCornerBrackets(encoder: MTLRenderCommandEncoder, drawableSize: CGSize, innerRects: [CGRect]) {
        let bracketLen = Theme.HUD.cornerBracketLength * backingScale
        let thickness = Theme.HUD.cornerBracketThickness * backingScale
        let color = Theme.Palette.cyan

        encoder.setRenderPipelineState(pipelines.boxes)

        for paneIndex in 0..<innerRects.count {
            // Hug the aspect-fitted video rect instead of the outer pane cell
            // so the brackets visually frame the picture, not the letterbox.
            let rect = innerRects[paneIndex]
            let inset = Theme.HUD.paneFrameInset * backingScale
            let x0 = rect.origin.x + inset
            let y0 = rect.origin.y + inset
            let x1 = rect.origin.x + rect.width - inset
            let y1 = rect.origin.y + rect.height - inset

            // Bracket "L" segments — thin filled rectangles drawn via viewport + fullscreen quad.
            // We use the boxes pipeline because it can fill from NDC uniforms via vertex_ids 0..5
            // (the shader treats indices 0..5 as a triangle quad covering the uniform rect).
            // For pixel-perfect placement, switch to viewport-based draws instead:
            let segs: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
                (x0, y0, x0 + bracketLen, y0 + thickness),
                (x0, y0, x0 + thickness, y0 + bracketLen),
                (x1 - bracketLen, y0, x1, y0 + thickness),
                (x1 - thickness, y0, x1, y0 + bracketLen),
                (x0, y1 - thickness, x0 + bracketLen, y1),
                (x0, y1 - bracketLen, x0 + thickness, y1),
                (x1 - bracketLen, y1 - thickness, x1, y1),
                (x1 - thickness, y1 - bracketLen, x1, y1)
            ]
            for seg in segs {
                let segRect = CGRect(x: seg.0, y: seg.1, width: seg.2 - seg.0, height: seg.3 - seg.1)
                setViewport(encoder: encoder, rect: segRect)
                var uniforms = BoxUniforms(
                    rect: SIMD4<Float>(-1, -1, 2, 2),
                    color: color,
                    params: SIMD4<Float>(1, 0, 0, 0)   // mode 1 = solid fill
                )
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<BoxUniforms>.stride, index: 0)
                encoder.setFragmentBytes(&uniforms, length: MemoryLayout<BoxUniforms>.stride, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            }
        }
    }

    private func drawPaneLabels(encoder: MTLRenderCommandEncoder, drawableSize: CGSize, innerRects: [CGRect]) {
        let labels = Theme.Layout.paneLabels
        let inset = Theme.HUD.paneFrameInset * backingScale + 8 * backingScale
        let labelHeightPx: CGFloat = 24 * backingScale

        for index in 0..<min(labels.count, innerRects.count) {
            if paneLabelTextures[index] == nil {
                paneLabelTextures[index] = makeLabelTexture(
                    labels[index],
                    font: Theme.Font.title(Theme.Font.paneLabelSize)
                )
            }
            guard let texture = paneLabelTextures[index] else { continue }

            // Anchor labels to the inner (aspect-fit) rect so they sit inside
            // the visible video, not floating on a letterbox bar.
            let inner = innerRects[index]
            let widthPx = CGFloat(texture.width)
            let xPx = inner.origin.x + inset
            let yPx = inner.origin.y + inset

            let rect = CGRect(x: xPx, y: yPx, width: widthPx, height: labelHeightPx)
            setViewport(encoder: encoder, rect: rect)
            drawTextQuad(encoder: encoder, texture: texture, tint: Theme.Palette.label)
        }
    }

    private func drawFooter(encoder: MTLRenderCommandEncoder, drawableSize: CGSize) {
        if frameCounter % 10 == 0 || footerTexture == nil {
            let profile: String
            switch Theme.Performance.profile {
            case .balanced: profile = "BALANCED"
            case .quality:  profile = "QUALITY"
            }
            let mode = detector.lastDetectMode.rawValue
            let text = String(
                format: "VISIONPOC  ·  FPS %d  ·  DET %.1fms (%@)  ·  %@",
                Int(smoothedFPS.rounded()),
                detector.lastInferenceMs,
                mode,
                profile
            )
            footerTexture = makeLabelTexture(text, font: Theme.Font.body(Theme.Font.footerSize), wide: true)
        }
        guard let texture = footerTexture else { return }

        let widthPx = CGFloat(texture.width)
        let heightPx = Theme.HUD.footerHeight * backingScale
        let inset = (Theme.HUD.paneFrameInset + 4) * backingScale
        // Anchor the footer to the BOTTOM of the drawable. MTLViewport y is
        // measured from the top of the drawable, so larger y means lower on
        // screen — subtract the footer height + a small margin from the full
        // drawable height to sit just above the bottom edge.
        let rect = CGRect(
            x: inset,
            y: drawableSize.height - heightPx - 2 * backingScale,
            width: widthPx,
            height: heightPx
        )
        setViewport(encoder: encoder, rect: rect)
        drawTextQuad(encoder: encoder, texture: texture, tint: Theme.Palette.micro)
    }

    // MARK: - Detection labels & ASCII art

    /// LRU-bounded label texture cache. Capacity capped at
    /// `labelTextureCacheCapacity`. On hit, the key is moved to the tail
    /// (most-recently-used). On miss with the cache full, the head (LRU) is
    /// evicted before insertion.
    private func labelTexture(for text: String) -> MTLTexture? {
        if let cached = labelTextureCache[text] {
            // Move-to-end on hit. removeAll(where:) is O(n) for a 128-element
            // array; trivially fast and avoids pulling in a real LRU library.
            labelTextureCacheKeys.removeAll(where: { $0 == text })
            labelTextureCacheKeys.append(text)
            return cached
        }
        guard let tex = makeLabelTexture(text, font: Theme.Font.body(Theme.Font.boxLabelSize)) else {
            return nil
        }
        if labelTextureCacheKeys.count >= labelTextureCacheCapacity,
           let oldest = labelTextureCacheKeys.first {
            labelTextureCacheKeys.removeFirst()
            labelTextureCache.removeValue(forKey: oldest)
        }
        labelTextureCache[text] = tex
        labelTextureCacheKeys.append(text)
        return tex
    }

    private func drawDetectionLabels(
        encoder: MTLRenderCommandEncoder,
        detections: [Detection],
        paneRect: CGRect
    ) {
        let labelHeight: CGFloat = 18 * backingScale
        let inset: CGFloat = 4 * backingScale
        for det in detections {
            // Confidence quantized to 10% buckets to keep label cache small.
            // A CUP at 80% and a CUP at 90% get separate cached textures,
            // but two CUPs at 85% share one (both round to 90%).
            let bucket = Int((det.confidence * 10).rounded()) * 10
            let displayed = "\(det.label) \(bucket)%"
            guard let texture = labelTexture(for: displayed) else { continue }
            let r = det.rect
            let boxLeftPx = paneRect.origin.x + CGFloat(r.origin.x) * paneRect.width
            // Box top edge in screen pixels (y-down). Vision y is origin
            // bottom-left, so the top edge of the box in image-y-down is
            // `1 - (y + h)`.
            let boxTopPx = paneRect.origin.y
                + (1.0 - (CGFloat(r.origin.y) + CGFloat(r.height))) * paneRect.height
            let labelWidth = CGFloat(texture.width)
            // Clamp to pane edges so the label doesn't extend past the
            // drawable when a box is hugging the right or top edge.
            let rawX = boxLeftPx + inset
            let rawY = boxTopPx + inset
            let clampedX = min(rawX, paneRect.maxX - labelWidth - inset)
            let clampedY = max(rawY, paneRect.minY + inset)
            let rect = CGRect(
                x: clampedX,
                y: clampedY,
                width: labelWidth,
                height: labelHeight
            )
            setViewport(encoder: encoder, rect: rect)
            drawTextQuad(encoder: encoder, texture: texture, tint: boxColor(for: det))
        }
    }

    // MARK: - OCR overlay

    private func drawTextDetections(
        encoder: MTLRenderCommandEncoder,
        texts: [TextDetection],
        paneRect: CGRect
    ) {
        guard !texts.isEmpty else { return }

        // Hollow magenta box per recognized text region.
        encoder.setRenderPipelineState(pipelines.boxes)
        for t in texts {
            let r = t.rect
            let originNDC = SIMD2<Float>(Float(r.origin.x) * 2 - 1, Float(r.origin.y) * 2 - 1)
            let sizeNDC = SIMD2<Float>(Float(r.width) * 2, Float(r.height) * 2)
            var uniforms = BoxUniforms(
                rect: SIMD4<Float>(originNDC.x, originNDC.y, sizeNDC.x, sizeNDC.y),
                color: Theme.Palette.textStroke,
                params: SIMD4<Float>(0, 0, 0, 0)
            )
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<BoxUniforms>.stride, index: 0)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<BoxUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }

        // Magenta label INSIDE the top-left of each text rect, clamped to pane.
        let labelHeight: CGFloat = 18 * backingScale
        let inset: CGFloat = 4 * backingScale
        for t in texts {
            // OCR strings can be arbitrarily long; truncate to a sane prefix
            // before caching so cache key cardinality stays bounded. The LRU
            // cap also kicks in here.
            let key = t.text.count > 32
                ? String(t.text.prefix(32))
                : t.text
            guard let texture = labelTexture(for: key) else { continue }
            let r = t.rect
            let boxLeftPx = paneRect.origin.x + CGFloat(r.origin.x) * paneRect.width
            let boxTopPx = paneRect.origin.y
                + (1.0 - (CGFloat(r.origin.y) + CGFloat(r.height))) * paneRect.height
            let labelWidth = CGFloat(texture.width)
            let rawX = boxLeftPx + inset
            let rawY = boxTopPx + inset
            let clampedX = min(rawX, paneRect.maxX - labelWidth - inset)
            let clampedY = max(rawY, paneRect.minY + inset)
            let rect = CGRect(
                x: clampedX,
                y: clampedY,
                width: labelWidth,
                height: labelHeight
            )
            setViewport(encoder: encoder, rect: rect)
            drawTextQuad(encoder: encoder, texture: texture, tint: Theme.Palette.textStroke)
        }
    }

    // MARK: - Pose overlay

    private func drawPoses(
        encoder: MTLRenderCommandEncoder,
        poses: [PoseDetection],
        paneRect: CGRect
    ) {
        guard !poses.isEmpty else { return }
        encoder.setRenderPipelineState(pipelines.boxes)

        for pose in poses {
            let color: SIMD4<Float>
            switch pose.kind {
            case .body: color = Theme.Palette.bodyPose
            case .hand: color = Theme.Palette.handPose
            }

            // Segments — Option A: draw each as the axis-aligned bounding rect
            // of its endpoints. Blocky for diagonals but a single draw call per
            // segment and matches the existing shader contract exactly. A v2
            // could subdivide into mini-rects for smoother diagonals.
            for seg in pose.segments {
                let minX = Float(min(seg.start.x, seg.end.x))
                let maxX = Float(max(seg.start.x, seg.end.x))
                let minY = Float(min(seg.start.y, seg.end.y))
                let maxY = Float(max(seg.start.y, seg.end.y))
                // Give zero-extent (perfectly horizontal/vertical) segments a
                // visible thickness — without this they'd render as a 0-pixel
                // strip and vanish.
                let thicknessNorm: Float = 0.003
                let w = max(maxX - minX, thicknessNorm)
                let h = max(maxY - minY, thicknessNorm)
                let originNDC = SIMD2<Float>(minX * 2 - 1, minY * 2 - 1)
                let sizeNDC = SIMD2<Float>(w * 2, h * 2)
                var uniforms = BoxUniforms(
                    rect: SIMD4<Float>(originNDC.x, originNDC.y, sizeNDC.x, sizeNDC.y),
                    color: color,
                    params: SIMD4<Float>(1, 0, 0, 0)   // solid fill
                )
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<BoxUniforms>.stride, index: 0)
                encoder.setFragmentBytes(&uniforms, length: MemoryLayout<BoxUniforms>.stride, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            }

            // Joint dots — 3 px squares. Convert 3 px to normalized image
            // coords using the pane size so the dots stay roughly the same
            // visual size regardless of pane.
            let dotPx: CGFloat = 3 * backingScale
            let dotNormX = Float(dotPx / max(paneRect.width, 1))
            let dotNormY = Float(dotPx / max(paneRect.height, 1))
            for p in pose.points {
                let px = Float(p.x) - dotNormX * 0.5
                let py = Float(p.y) - dotNormY * 0.5
                let originNDC = SIMD2<Float>(px * 2 - 1, py * 2 - 1)
                let sizeNDC = SIMD2<Float>(dotNormX * 2, dotNormY * 2)
                var uniforms = BoxUniforms(
                    rect: SIMD4<Float>(originNDC.x, originNDC.y, sizeNDC.x, sizeNDC.y),
                    color: color,
                    params: SIMD4<Float>(1, 0, 0, 0)
                )
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<BoxUniforms>.stride, index: 0)
                encoder.setFragmentBytes(&uniforms, length: MemoryLayout<BoxUniforms>.stride, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            }
        }
    }

    private func drawAscii(
        encoder: MTLRenderCommandEncoder,
        texture: MTLTexture,
        paneSize: CGSize
    ) {
        encoder.setRenderPipelineState(pipelines.ascii)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentTexture(asciiPass.atlasTexture, index: 1)
        encoder.setFragmentSamplerState(linearSampler, index: 0)
        var uniforms = asciiPass.uniforms(paneSize: paneSize)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<AsciiUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }

    private func drawTextQuad(
        encoder: MTLRenderCommandEncoder,
        texture: MTLTexture,
        tint: SIMD4<Float>
    ) {
        encoder.setRenderPipelineState(pipelines.hudText)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentSamplerState(linearSampler, index: 0)
        var color = tint
        encoder.setFragmentBytes(&color, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }

    private func makeLabelTexture(_ text: String, font: NSFont, wide: Bool = false) -> MTLTexture? {
        let maxWidth: CGFloat = wide ? 800 : 220
        let maxHeight: CGFloat = 30
        let color = NSColor(
            deviceRed: CGFloat(Theme.Palette.label.x),
            green: CGFloat(Theme.Palette.label.y),
            blue: CGFloat(Theme.Palette.label.z),
            alpha: CGFloat(Theme.Palette.label.w)
        )
        return textRasterizer.rasterize(
            text,
            font: font,
            color: color,
            maxSize: CGSize(width: maxWidth, height: maxHeight),
            scale: backingScale
        )
    }
}
