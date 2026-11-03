import CoreGraphics
import Foundation
import ImageIO
import Observation
import SwiftUI

struct AmbientColor: Equatable, Sendable {
    var red: Double
    var green: Double
    var blue: Double

    var color: Color { Color(red: red, green: green, blue: blue) }
}

struct AmbientPalette: Equatable, Sendable {
    var primary: AmbientColor
    var secondary: AmbientColor?
}

/// Finds the color a cover reads as: the strongest hue, not the average, which is nearly always
/// mud. Monochrome covers have no such color, and then there's no glow rather than a grey one.
enum ArtworkPalette {
    private static let thumbnailSize = 32
    private static let hueBins = 24
    private static let minimumSaturation = 0.18
    private static let minimumBrightness = 0.12
    /// Below this share of the image, a color is an accent and not what the cover looks like.
    private static let minimumCoverage = 0.04
    /// In bins, so about 60 degrees: anything closer is the same color to the eye.
    private static let minimumHueDistance = 4

    static func palette(in data: Data) -> AmbientPalette? {
        guard let pixels = pixels(of: data) else { return nil }
        return palette(rgba: pixels)
    }

    static func dominantColor(in data: Data) -> AmbientColor? {
        palette(in: data)?.primary
    }

    private static func pixels(of data: Data) -> [UInt8]? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: thumbnailSize,
              ] as CFDictionary) else { return nil }

        var pixels = [UInt8](repeating: 0, count: thumbnailSize * thumbnailSize * 4)
        let drew = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: thumbnailSize, height: thumbnailSize,
                                          bitsPerComponent: 8, bytesPerRow: thumbnailSize * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: thumbnailSize, height: thumbnailSize))
            return true
        }
        return drew ? pixels : nil
    }

    static func dominantColor(rgba pixels: [UInt8]) -> AmbientColor? {
        palette(rgba: pixels)?.primary
    }

    /// The strongest hue, and the next one far enough around the wheel to read as a second color.
    static func palette(rgba pixels: [UInt8]) -> AmbientPalette? {
        var weights = [Double](repeating: 0, count: hueBins)
        var totals = [(red: Double, green: Double, blue: Double)](repeating: (0, 0, 0), count: hueBins)
        var counted = [Int](repeating: 0, count: hueBins)
        let pixelCount = pixels.count / 4
        guard pixelCount > 0 else { return nil }

        for index in 0..<pixelCount {
            let red = Double(pixels[index * 4]) / 255
            let green = Double(pixels[index * 4 + 1]) / 255
            let blue = Double(pixels[index * 4 + 2]) / 255
            let (hue, saturation, brightness) = hsb(red, green, blue)
            guard saturation >= minimumSaturation, brightness >= minimumBrightness else { continue }
            let bin = min(Int(hue * Double(hueBins)), hueBins - 1)
            let weight = saturation * saturation * brightness
            weights[bin] += weight
            totals[bin].red += red * weight
            totals[bin].green += green * weight
            totals[bin].blue += blue * weight
            counted[bin] += 1
        }

        guard let best = weights.indices.max(by: { weights[$0] < weights[$1] }), weights[best] > 0,
              Double(counted[best]) / Double(pixelCount) >= minimumCoverage else { return nil }

        func color(_ bin: Int) -> AmbientColor {
            let (hue, saturation, brightness) = hsb(totals[bin].red / weights[bin],
                                                    totals[bin].green / weights[bin],
                                                    totals[bin].blue / weights[bin])
            // Held to a calm range, so a loud cover can't turn into neon against the black.
            return rgb(hue, min(saturation, 0.7), min(max(brightness, 0.6), 0.85))
        }
        let others = weights.indices.filter { bin in
            let distance = abs(bin - best)
            return min(distance, hueBins - distance) >= minimumHueDistance && weights[bin] > 0
                && Double(counted[bin]) / Double(pixelCount) >= minimumCoverage
        }
        return AmbientPalette(primary: color(best), secondary: others.max { weights[$0] < weights[$1] }.map(color))
    }

    private static func hsb(_ red: Double, _ green: Double, _ blue: Double) -> (Double, Double, Double) {
        let high = max(red, green, blue)
        let low = min(red, green, blue)
        let delta = high - low
        guard delta > 0 else { return (0, 0, high) }
        var hue: Double
        if high == red {
            hue = (green - blue) / delta
        } else if high == green {
            hue = (blue - red) / delta + 2
        } else {
            hue = (red - green) / delta + 4
        }
        hue /= 6
        if hue < 0 { hue += 1 }
        return (hue, delta / high, high)
    }

    private static func rgb(_ hue: Double, _ saturation: Double, _ brightness: Double) -> AmbientColor {
        let sector = hue * 6
        let chroma = brightness * saturation
        let second = chroma * (1 - abs(sector.truncatingRemainder(dividingBy: 2) - 1))
        let offset = brightness - chroma
        let (red, green, blue): (Double, Double, Double) = switch Int(sector) {
        case 0: (chroma, second, 0)
        case 1: (second, chroma, 0)
        case 2: (0, chroma, second)
        case 3: (0, second, chroma)
        case 4: (second, 0, chroma)
        default: (chroma, 0, second)
        }
        return AmbientColor(red: red + offset, green: green + offset, blue: blue + offset)
    }
}

/// Analyzes each cover once, off the main thread, and remembers the result per track.
@MainActor
@Observable
final class AmbientColorService {
    private static let cacheLimit = 40

    private(set) var palette: AmbientPalette?
    var color: AmbientColor? { palette?.primary }

    @ObservationIgnored private var cache: [String: AmbientPalette?] = [:]
    @ObservationIgnored private var cacheOrder: [String] = []
    @ObservationIgnored private var currentKey: String?

    func update(key: String?, artwork: Data?) {
        guard let key, let artwork else {
            currentKey = nil
            palette = nil
            return
        }
        guard key != currentKey else { return }
        currentKey = key

        if let cached = cache[key] {
            palette = cached
            return
        }
        Task { [weak self] in
            let result = await Task.detached(priority: .utility) { ArtworkPalette.palette(in: artwork) }.value
            self?.store(result, key: key)
        }
    }

    private func store(_ result: AmbientPalette?, key: String) {
        cache[key] = .some(result)
        cacheOrder.append(key)
        if cacheOrder.count > Self.cacheLimit { cache[cacheOrder.removeFirst()] = nil }
        if key == currentKey { palette = result }
    }
}
