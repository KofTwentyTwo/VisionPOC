import Metal
import CoreText
import CoreGraphics
import AppKit

final class TextRasterizer {
    private let device: MTLDevice
    private let colorSpace: CGColorSpace

    init(device: MTLDevice) {
        self.device = device
        self.colorSpace = CGColorSpaceCreateDeviceRGB()
    }

    /// Rasterize `string` at `scale` (backing factor) within `maxSize` (points). Returns a
    /// BGRA8 premultiplied `MTLTexture` sized to `ceil(maxSize * scale)` pixels.
    func rasterize(
        _ string: NSAttributedString,
        maxSize: CGSize,
        scale: CGFloat
    ) -> MTLTexture? {
        let pixelWidth  = max(Int((maxSize.width  * scale).rounded(.up)), 1)
        let pixelHeight = max(Int((maxSize.height * scale).rounded(.up)), 1)
        let bytesPerRow = pixelWidth * 4

        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue
                       | CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { return nil }

        context.scaleBy(x: scale, y: scale)
        context.setShouldAntialias(true)
        context.setShouldSmoothFonts(true)

        // Inset the text region so glyphs sit clearly inside the widget's chamfered
        // frame (10% chamfer at TL + BR). Inset is 10% of the smaller widget dimension,
        // clamped to [4, 40] pt — gives breathing room without crowding small widgets.
        let dim = min(maxSize.width, maxSize.height)
        let inset = max(4.0, min(40.0, dim * 0.10))
        let framesetter = CTFramesetterCreateWithAttributedString(string)
        let path = CGPath(
            rect: CGRect(
                x: inset, y: inset,
                width: max(maxSize.width - 2 * inset, 1),
                height: max(maxSize.height - 2 * inset, 1)
            ),
            transform: nil
        )
        let frame = CTFramesetterCreateFrame(framesetter, CFRangeMake(0, 0), path, nil)
        // CoreText draws in a y-up coordinate system. The CGContext defaults to y-up too
        // after we've set no extra transforms, but we need to ensure the frame draws into
        // the visible area starting from the top — flip the y axis here.
        context.translateBy(x: 0, y: maxSize.height)
        context.scaleBy(x: 1, y: -1)
        CTFrameDraw(frame, context)
        // Undo the flip so future drawing isn't surprised.
        context.scaleBy(x: 1, y: -1)
        context.translateBy(x: 0, y: -maxSize.height)

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: pixelWidth,
            height: pixelHeight,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared

        guard let texture = device.makeTexture(descriptor: descriptor),
              let data = context.data else { return nil }

        texture.replace(
            region: MTLRegionMake2D(0, 0, pixelWidth, pixelHeight),
            mipmapLevel: 0,
            withBytes: data,
            bytesPerRow: bytesPerRow
        )
        return texture
    }

    /// Rasterize `string` then call `extraDraw(ctx, maxSize)` into the same CGContext before
    /// uploading to a Metal texture. Use for overlaying sparklines or other CG graphics.
    func rasterize(
        _ string: NSAttributedString,
        maxSize: CGSize,
        scale: CGFloat,
        extraDraw: (CGContext, CGSize) -> Void
    ) -> MTLTexture? {
        let pixelWidth  = max(Int((maxSize.width  * scale).rounded(.up)), 1)
        let pixelHeight = max(Int((maxSize.height * scale).rounded(.up)), 1)
        let bytesPerRow = pixelWidth * 4

        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue
                       | CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { return nil }

        context.scaleBy(x: scale, y: scale)
        context.setShouldAntialias(true)
        context.setShouldSmoothFonts(true)

        // Inset the text region so glyphs sit clearly inside the widget's chamfered
        // frame (10% chamfer at TL + BR). Inset is 10% of the smaller widget dimension,
        // clamped to [4, 40] pt — gives breathing room without crowding small widgets.
        let dim = min(maxSize.width, maxSize.height)
        let inset = max(4.0, min(40.0, dim * 0.10))
        let framesetter = CTFramesetterCreateWithAttributedString(string)
        let path = CGPath(
            rect: CGRect(
                x: inset, y: inset,
                width: max(maxSize.width - 2 * inset, 1),
                height: max(maxSize.height - 2 * inset, 1)
            ),
            transform: nil
        )
        let frame = CTFramesetterCreateFrame(framesetter, CFRangeMake(0, 0), path, nil)
        context.translateBy(x: 0, y: maxSize.height)
        context.scaleBy(x: 1, y: -1)
        CTFrameDraw(frame, context)
        context.scaleBy(x: 1, y: -1)
        context.translateBy(x: 0, y: -maxSize.height)

        // Run extra drawing (e.g. sparklines) into the same CGContext.
        extraDraw(context, maxSize)

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: pixelWidth,
            height: pixelHeight,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared

        guard let texture = device.makeTexture(descriptor: descriptor),
              let data = context.data else { return nil }

        texture.replace(
            region: MTLRegionMake2D(0, 0, pixelWidth, pixelHeight),
            mipmapLevel: 0,
            withBytes: data,
            bytesPerRow: bytesPerRow
        )
        return texture
    }

    /// Convenience: rasterize a plain `String` with the supplied font and color.
    func rasterize(
        _ text: String,
        font: NSFont,
        color: NSColor,
        maxSize: CGSize,
        scale: CGFloat
    ) -> MTLTexture? {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        return rasterize(attributed, maxSize: maxSize, scale: scale)
    }
}
