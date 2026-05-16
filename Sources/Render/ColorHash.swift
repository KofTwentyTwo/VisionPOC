import Foundation
import simd

/// Deterministic per-trackId color generator. Hashes a UUID into a hue value
/// in [0, 1) and converts HSV(hue, 0.8, 1.0) to RGB. Used to give each tracked
/// object a stable, visually-distinct box + label color so it's clear which
/// label belongs to which box when several boxes overlap.
///
/// Uniqueness caveat: with hue alone covering ~32 buckets of human-discernible
/// difference, ~6 simultaneous tracks of the same hue family will start to look
/// similar. For the POC's typical 3-8 tracks this is fine; if track count
/// regularly exceeds ~12 a second axis (saturation or value) would help.
enum ColorHash {
    /// Returns a stable RGBA color for the given track id.
    /// Saturation 0.8, value 1.0, alpha 1.0.
    static func colorFor(trackId: UUID) -> SIMD4<Float> {
        // Spread the UUID's bytes across the hash so adjacent UUIDs (which the
        // standard library doesn't actually generate adjacently, but be safe)
        // map to far-apart hues. Mix several bytes from the uuid tuple.
        let bytes = trackId.uuid
        // Combine bytes 0, 3, 7, 11 with a multiplicative hash. The constant
        // 2654435769 is Knuth's golden-ratio hash multiplier — distributes
        // small input differences across the full 32-bit output range.
        var h: UInt32 = UInt32(bytes.0)
        h = h &* 2654435769 &+ UInt32(bytes.3)
        h = h &* 2654435769 &+ UInt32(bytes.7)
        h = h &* 2654435769 &+ UInt32(bytes.11)
        let hue = Float(h % 360) / 360.0
        return hsvToRGB(h: hue, s: 0.8, v: 1.0)
    }

    /// HSV → RGB, standard formula. Hue is in [0,1), s and v in [0,1].
    private static func hsvToRGB(h: Float, s: Float, v: Float) -> SIMD4<Float> {
        let hh = (h - floor(h)) * 6.0
        let i = Int(floor(hh))
        let f = hh - Float(i)
        let p = v * (1 - s)
        let q = v * (1 - s * f)
        let t = v * (1 - s * (1 - f))
        let r: Float
        let g: Float
        let b: Float
        switch i % 6 {
        case 0: r = v; g = t; b = p
        case 1: r = q; g = v; b = p
        case 2: r = p; g = v; b = t
        case 3: r = p; g = q; b = v
        case 4: r = t; g = p; b = v
        default: r = v; g = p; b = q
        }
        return SIMD4<Float>(r, g, b, 1.0)
    }
}
