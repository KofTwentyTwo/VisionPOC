import Metal

final class Pipelines {
    let device: MTLDevice
    let live: MTLRenderPipelineState
    let jarvis: MTLRenderPipelineState
    let edges: MTLRenderPipelineState
    let boxes: MTLRenderPipelineState
    let hudText: MTLRenderPipelineState
    let ascii: MTLRenderPipelineState
    let lines: MTLRenderPipelineState

    init(device: MTLDevice, library: MTLLibrary) throws {
        self.device = device

        self.live = try Pipelines.makeImagePipeline(
            device: device, library: library,
            vertex: "quad_vertex", fragment: "live_fragment",
            label: "LivePipeline"
        )

        self.jarvis = try Pipelines.makeImagePipeline(
            device: device, library: library,
            vertex: "quad_vertex", fragment: "jarvis_fragment",
            label: "JarvisPipeline"
        )

        self.edges = try Pipelines.makeImagePipeline(
            device: device, library: library,
            vertex: "quad_vertex", fragment: "edges_fragment",
            label: "EdgesPipeline"
        )

        self.boxes = try Pipelines.makeBlendedPipeline(
            device: device, library: library,
            vertex: "box_vertex", fragment: "box_fragment",
            label: "BoxesPipeline"
        )

        self.hudText = try Pipelines.makeBlendedPipeline(
            device: device, library: library,
            vertex: "quad_vertex", fragment: "text_fragment",
            label: "HUDTextPipeline"
        )

        self.ascii = try Pipelines.makeImagePipeline(
            device: device, library: library,
            vertex: "quad_vertex", fragment: "ascii_fragment",
            label: "AsciiPipeline"
        )

        self.lines = try Pipelines.makeBlendedPipeline(
            device: device, library: library,
            vertex: "line_vertex", fragment: "line_fragment",
            label: "LinesPipeline"
        )
    }

    private static func makeImagePipeline(
        device: MTLDevice,
        library: MTLLibrary,
        vertex: String,
        fragment: String,
        label: String
    ) throws -> MTLRenderPipelineState {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = label
        descriptor.vertexFunction = library.makeFunction(name: vertex)
        descriptor.fragmentFunction = library.makeFunction(name: fragment)
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        descriptor.colorAttachments[0].isBlendingEnabled = false
        return try device.makeRenderPipelineState(descriptor: descriptor)
    }

    private static func makeBlendedPipeline(
        device: MTLDevice,
        library: MTLLibrary,
        vertex: String,
        fragment: String,
        label: String
    ) throws -> MTLRenderPipelineState {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = label
        descriptor.vertexFunction = library.makeFunction(name: vertex)
        descriptor.fragmentFunction = library.makeFunction(name: fragment)
        let attachment = descriptor.colorAttachments[0]!
        attachment.pixelFormat = .bgra8Unorm
        attachment.isBlendingEnabled = true
        attachment.rgbBlendOperation = .add
        attachment.alphaBlendOperation = .add
        attachment.sourceRGBBlendFactor = .sourceAlpha
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.sourceAlphaBlendFactor = .sourceAlpha
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        return try device.makeRenderPipelineState(descriptor: descriptor)
    }
}
