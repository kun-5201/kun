// LyricsLiveActivityCover.swift — Album-color helper for the lyrics Live
// Activity (Dynamic Island / Lock Screen).
//
// Lives in KumoneCore so the app (which derives the lyric color from the
// cover) shares one definition with the widget extension.
//
// Cover delivery (#52): the ContentState carries the cover URL string and
// the extension downloads the thumbnail itself (URLSession + its own
// cache — see IslandCoverCache in LyricsLiveActivityBundle). The cover
// used to travel through the App Group shared container
// (group.sb.moe.kumone-ios), but re-signed builds have no App Group
// entitlement, so the container never opened and the island always fell
// back to ♪. The container path is gone — one path, no fallback to
// maintain. Only the album-derived color is still computed here, from the
// artwork image the app downloads for Now Playing.

#if os(iOS)
import CoreGraphics
import Foundation
import UIKit

/// Album-color helper for the lyrics Live Activity.
public enum LyricsIslandCover {
    /// Lyric color when there is no cover or color extraction fails: white.
    /// (The earlier gold/orange default from the screenshot was replaced by
    /// user request: no cover / extraction failure => white, never gold.)
    public static let fallbackLyricColorHex = "#FFFFFF"

    /// Cover URL size for the island: 200px is plenty for the 28pt pill
    /// thumbnail (and the 44pt expanded one) at 3x, and a small download
    /// for the extension to fetch on its own.
    public static let islandCoverSize = 200

    /// Derives the lyric color from the album cover: the most frequent
    /// saturated, mid-brightness color, brightness-clamped so it stays
    /// readable on the black Dynamic Island pill and the lock screen.
    /// Falls back to white when there is no usable color; never returns
    /// black / near-black.
    public static func dominantLyricColorHex(from image: UIImage) -> String {
        guard let cgImage = image.cgImage else { return fallbackLyricColorHex }
        let size = 16
        guard let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8,
            bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let data = context.data else { return fallbackLyricColorHex }
        context.interpolationQuality = .low
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: size, height: size))

        var buckets: [UInt32: Int] = [:]
        var totalR = 0, totalG = 0, totalB = 0, total = 0
        let pixels = data.assumingMemoryBound(to: UInt8.self)
        for i in 0..<(size * size) {
            let r = Int(pixels[i * 4]), g = Int(pixels[i * 4 + 1]), b = Int(pixels[i * 4 + 2])
            totalR += r; totalG += g; totalB += b; total += 1
            let mx = max(r, g, b), mn = min(r, g, b)
            let sat = mx == 0 ? 0 : Double(mx - mn) / Double(mx)
            let lum = (0.299 * Double(r) + 0.587 * Double(g) + 0.114 * Double(b)) / 255.0
            // Skip gray / near-black / near-white pixels: they carry no album color.
            guard sat > 0.25, lum > 0.12, lum < 0.92 else { continue }
            let key = UInt32((r / 32) << 10 | (g / 32) << 5 | (b / 32))
            buckets[key, default: 0] += 1
        }
        guard total > 0 else { return fallbackLyricColorHex }
        let picked: (r: Int, g: Int, b: Int)
        if let best = buckets.max(by: { $0.value < $1.value }) {
            let k = best.key
            picked = (Int((k >> 10) & 31) * 32 + 16, Int((k >> 5) & 31) * 32 + 16, Int(k & 31) * 32 + 16)
        } else {
            picked = (totalR / total, totalG / total, totalB / total)
        }
        // Clamp brightness so the text stays readable on black.
        var (r, g, b) = (Double(picked.r) / 255, Double(picked.g) / 255, Double(picked.b) / 255)
        let lum = 0.299 * r + 0.587 * g + 0.114 * b
        if lum < 0.35 {
            let f = 0.35 / max(lum, 0.01)
            r = min(1, r * f); g = min(1, g * f); b = min(1, b * f)
        }
        // Never black / near-black on the black pill.
        if r < 0.08, g < 0.08, b < 0.08 { return fallbackLyricColorHex }
        return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
    }
}
#endif
