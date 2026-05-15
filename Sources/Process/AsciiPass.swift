import AppKit
import CoreGraphics
import CoreText
import Metal
import simd

/// Builds a horizontal glyph atlas of monospaced ASCII characters at startup,
/// and exposes the uniforms used by `ascii_fragment`.
///
/// The atlas runs dark → bright left-to-right; the fragment shader picks a
/// glyph slot based on per-cell luma so the source image is quantized into a
/// grid of characters.
final class AsciiPass {
    /// Dark-to-bright ramp. Adjust to taste; keep monospaced glyphs only.
    static let palette: [Character] = Array(" .:-=+*#%@")

    let atlasTexture: MTLTexture
    let charCount: Int

    init?(device: MTLDevice) {
        let chars = AsciiPass.palette
        self.charCount = chars.count

        // Each glyph gets a square cell. The cell pixel size is generous so
        // we get clean sub-pixel sampling when the cells are stretched across
        // the pane.
        let cellPx: Int = 32
        let width = cellPx * chars.count
        let height = cellPx
        let bytesPerRow = width * 4

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue
                       | CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { return nil }

        context.setFillColor(red: 0, green: 0, blue: 0, alpha: 0)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // Flip into image-y-down so memory row 0 is the top of the rendered
        // glyphs (the shader compensates with a v-flip on its lookup).
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.setShouldAntialias(true)
        context.setShouldSmoothFonts(true)

        let font = Theme.Font.body(CGFloat(cellPx) * 0.9)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(calibratedRed: 1, green: 1, blue: 1, alpha: 1)
        ]

        for (i, ch) in chars.enumerated() {
            let s = NSAttributedString(string: String(ch), attributes: attrs)
            let line = CTLineCreateWithAttributedString(s)
            let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
            let cellX = CGFloat(i * cellPx)
            let glyphWidth = bounds.width
            let glyphHeight = bounds.height
            let drawX = cellX + (CGFloat(cellPx) - glyphWidth) * 0.5 - bounds.origin.x
            let drawY = (CGFloat(cellPx) - glyphHeight) * 0.5 - bounds.origin.y
            context.textPosition = CGPoint(x: drawX, y: drawY)
            CTLineDraw(line, context)
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared

        guard let tex = device.makeTexture(descriptor: descriptor),
              let data = context.data else { return nil }
        tex.replace(
            region: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0,
            withBytes: data,
            bytesPerRow: bytesPerRow
        )
        self.atlasTexture = tex
    }

    /// Build the uniform struct for the ASCII fragment. The vertical grid
    /// count is derived from the pane aspect ratio so glyph cells stay square.
    func uniforms(paneSize: CGSize) -> AsciiUniforms {
        let cols = max(8, Theme.Performance.asciiColumns)
        let cellPx = max(1, Int(paneSize.width) / cols)
        let rows = max(1, Int(paneSize.height) / cellPx)
        return AsciiUniforms(
            gridSize: SIMD2<Float>(Float(cols), Float(rows)),
            atlasCharCount: Float(charCount),
            pad0: 0,
            tintColor: Theme.Palette.cyan
        )
    }
}

/// Mirrors the MSL `AsciiUniforms` struct byte-for-byte.
struct AsciiUniforms {
    var gridSize: SIMD2<Float>
    var atlasCharCount: Float
    var pad0: Float
    var tintColor: SIMD4<Float>
}
