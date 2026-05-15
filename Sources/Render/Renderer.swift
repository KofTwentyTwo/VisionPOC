import MetalKit
import AppKit
import simd

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
    private let nearestSampler: MTLSamplerState
    private let linearSampler: MTLSamplerState

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

        for index in 0..<panes.count {
            let paneRect = pixelRect(panes[index], in: drawableSize)
            setViewport(encoder: encoder, rect: paneRect)

            switch index {
            case 0:
                drawImage(encoder: encoder, pipeline: pipelines.live, texture: source, sampler: linearSampler)
            case 1:
                drawJarvis(encoder: encoder, texture: source, time: elapsed, paneSize: paneRect.size)
                drawDetections(encoder: encoder, detections: detections)
                drawDetectionLabels(encoder: encoder, detections: detections, paneRect: paneRect)
            case 2:
                drawImage(encoder: encoder, pipeline: pipelines.edges, texture: edgesTexture, sampler: nearestSampler)
            case 3:
                drawAscii(encoder: encoder, texture: source, paneSize: paneRect.size)
            default:
                break
            }
        }

        drawCornerBrackets(encoder: encoder, drawableSize: drawableSize)
        drawPaneLabels(encoder: encoder, drawableSize: drawableSize)
        drawFooter(encoder: encoder, drawableSize: drawableSize)

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
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
                color: Theme.Palette.boxStroke,
                params: SIMD4<Float>(0, 0, 0, 0)   // mode 0 = hollow stroke
            )
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<BoxUniforms>.stride, index: 0)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<BoxUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }
    }

    private func drawCornerBrackets(encoder: MTLRenderCommandEncoder, drawableSize: CGSize) {
        let panes = Theme.Layout.panes
        let bracketLen = Theme.HUD.cornerBracketLength * backingScale
        let thickness = Theme.HUD.cornerBracketThickness * backingScale
        let color = Theme.Palette.cyan

        encoder.setRenderPipelineState(pipelines.boxes)

        for paneIndex in 0..<panes.count {
            let rect = pixelRect(panes[paneIndex], in: drawableSize)
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

    private func drawPaneLabels(encoder: MTLRenderCommandEncoder, drawableSize: CGSize) {
        let labels = Theme.Layout.paneLabels
        let panes = Theme.Layout.panes
        let inset = Theme.HUD.paneFrameInset * backingScale + 8 * backingScale
        let labelHeightPx: CGFloat = 24 * backingScale

        for index in 0..<min(labels.count, panes.count) {
            if paneLabelTextures[index] == nil {
                paneLabelTextures[index] = makeLabelTexture(
                    labels[index],
                    font: Theme.Font.title(Theme.Font.paneLabelSize)
                )
            }
            guard let texture = paneLabelTextures[index] else { continue }

            let paneRect = pixelRect(panes[index], in: drawableSize)
            let widthPx = CGFloat(texture.width)
            let xPx = paneRect.origin.x + inset
            let yPx = paneRect.origin.y + inset

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
            let text = String(
                format: "VISIONPOC  ·  FPS %d  ·  DET %.1fms  ·  %@",
                Int(smoothedFPS.rounded()),
                detector.lastInferenceMs,
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

    private func labelTexture(for text: String) -> MTLTexture? {
        if let cached = labelTextureCache[text] { return cached }
        let tex = makeLabelTexture(text, font: Theme.Font.body(Theme.Font.boxLabelSize))
        if let tex { labelTextureCache[text] = tex }
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
            guard let texture = labelTexture(for: det.label) else { continue }
            let r = det.rect
            let boxLeftPx = paneRect.origin.x + CGFloat(r.origin.x) * paneRect.width
            // Box top edge in screen pixels (y-down). Vision y is origin
            // bottom-left, so the top edge of the box in image-y-down is
            // `1 - (y + h)`.
            let boxTopPx = paneRect.origin.y
                + (1.0 - (CGFloat(r.origin.y) + CGFloat(r.height))) * paneRect.height
            let labelWidth = CGFloat(texture.width)
            let rect = CGRect(
                x: boxLeftPx + inset,
                y: boxTopPx + inset,
                width: labelWidth,
                height: labelHeight
            )
            setViewport(encoder: encoder, rect: rect)
            drawTextQuad(encoder: encoder, texture: texture, tint: Theme.Palette.boxStroke)
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
