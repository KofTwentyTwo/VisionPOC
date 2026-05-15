import Foundation
import CoreGraphics
import simd

struct JarvisUniforms {
    var time: Float
    var resolution: SIMD2<Float>
    var scanlineDensity: Float
    var hexGridScale: Float
    var beamPhase: Float
    var tintColor: SIMD4<Float>
}

final class JarvisStylePass {
    init() {}

    func uniforms(time: Float, viewportSize: CGSize) -> JarvisUniforms {
        let period = Float(Theme.Tick.scanningBeamPeriod)
        let phase = period > 0 ? (time / period).truncatingRemainder(dividingBy: 1.0) : 0
        return JarvisUniforms(
            time: time,
            resolution: SIMD2<Float>(Float(viewportSize.width), Float(viewportSize.height)),
            scanlineDensity: Theme.Tick.scanlineDensity,
            hexGridScale: Theme.Tick.hexGridScale,
            beamPhase: phase,
            tintColor: Theme.Palette.cyan
        )
    }
}
