import Metal
import MetalPerformanceShaders

final class EdgePass {
    private let device: MTLDevice
    private let sobel: MPSImageSobel
    private let thresholdPipeline: MTLComputePipelineState?

    private var sobelOutput: MTLTexture?
    private var thresholdOutput: MTLTexture?
    private var lastSize: (width: Int, height: Int) = (0, 0)

    init(device: MTLDevice) {
        self.device = device
        self.sobel = MPSImageSobel(device: device)

        if let library = device.makeDefaultLibrary(),
           let function = library.makeFunction(name: "edge_threshold") {
            self.thresholdPipeline = try? device.makeComputePipelineState(function: function)
        } else {
            self.thresholdPipeline = nil
        }
    }

    /// Encodes Sobel + threshold into `commandBuffer`. Returns the texture the renderer
    /// should sample. Output is reused across frames; resized only on dimension change.
    func encode(source: MTLTexture, commandBuffer: MTLCommandBuffer) -> MTLTexture {
        ensureOutputs(width: source.width, height: source.height)

        let sobelTex = sobelOutput ?? source
        sobel.encode(commandBuffer: commandBuffer, sourceTexture: source, destinationTexture: sobelTex)

        guard let pipeline = thresholdPipeline,
              let thresholdTex = thresholdOutput,
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return sobelTex
        }

        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(sobelTex, index: 0)
        encoder.setTexture(thresholdTex, index: 1)

        let w = pipeline.threadExecutionWidth
        let h = max(1, pipeline.maxTotalThreadsPerThreadgroup / w)
        let threadsPerGroup = MTLSize(width: w, height: h, depth: 1)
        let threadgroups = MTLSize(
            width: (thresholdTex.width + w - 1) / w,
            height: (thresholdTex.height + h - 1) / h,
            depth: 1
        )
        encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerGroup)
        encoder.endEncoding()

        return thresholdTex
    }

    private func ensureOutputs(width: Int, height: Int) {
        if lastSize.width == width && lastSize.height == height && sobelOutput != nil {
            return
        }

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.usage = [.shaderRead, .shaderWrite]
        desc.storageMode = .private
        sobelOutput = device.makeTexture(descriptor: desc)

        let descT = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descT.usage = [.shaderRead, .shaderWrite]
        descT.storageMode = .private
        thresholdOutput = device.makeTexture(descriptor: descT)

        lastSize = (width, height)
    }
}
