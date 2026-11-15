import Foundation

/// A color as red, green, and blue from 0 to 1.
public struct RGBColor: Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// A `#RRGGBB` color, or nil when the text isn't one.
    public init?(hex: String) {
        guard AppearanceColors.isValidHex(hex), let value = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        red = Double((value >> 16) & 0xFF) / 255
        green = Double((value >> 8) & 0xFF) / 255
        blue = Double(value & 0xFF) / 255
    }

    /// A color from hue in degrees (0 to 360, unlike the 0 to 1 hue of the HSB initializer), and saturation and
    /// lightness from 0 to 1.
    init(hue: Double, saturation: Double, lightness: Double) {
        let chroma = (1 - abs(2 * lightness - 1)) * saturation
        let sector = hue.truncatingRemainder(dividingBy: 360) / 60
        let second = chroma * (1 - abs(sector.truncatingRemainder(dividingBy: 2) - 1))
        let (r, g, b): (Double, Double, Double) =
            switch Int(sector) {
            case 0: (chroma, second, 0)
            case 1: (second, chroma, 0)
            case 2: (0, chroma, second)
            case 3: (0, second, chroma)
            case 4: (second, 0, chroma)
            default: (chroma, 0, second)
            }
        let match = lightness - chroma / 2
        red = r + match
        green = g + match
        blue = b + match
    }

    /// A color from hue, saturation, and brightness, each from 0 to 1 as AppKit takes them.
    public init(hue: Double, saturation: Double, brightness: Double) {
        let sector = hue * 6
        let fraction = sector - sector.rounded(.down)
        let low = brightness * (1 - saturation)
        let falling = brightness * (1 - saturation * fraction)
        let rising = brightness * (1 - saturation * (1 - fraction))
        (red, green, blue) =
            switch Int(sector) % 6 {
            case 0: (brightness, rising, low)
            case 1: (falling, brightness, low)
            case 2: (low, brightness, rising)
            case 3: (low, falling, brightness)
            case 4: (rising, low, brightness)
            default: (brightness, low, falling)
            }
    }

    /// The color as `#RRGGBB`, each channel clamped to 0...1 and rounded to a whole byte.
    public var hex: String {
        String(format: "#%02X%02X%02X", Int(Self.byte(red)), Int(Self.byte(green)), Int(Self.byte(blue)))
    }

    /// The color as `hex` writes it, each channel rounded to a whole byte.
    var rounded: RGBColor {
        var color = self
        (color.red, color.green, color.blue) = (Self.byte(red) / 255, Self.byte(green) / 255, Self.byte(blue) / 255)
        return color
    }

    /// A channel from 0 to 1 as a byte value from 0 to 255.
    private static func byte(_ channel: Double) -> Double { (min(max(channel, 0), 1) * 255).rounded() }

    /// Relative luminance, as WCAG defines it.
    var luminance: Double {
        func linear(_ channel: Double) -> Double {
            channel <= 0.039_28 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// The WCAG contrast ratio between two colors, from 1 to 21.
    func contrast(with other: RGBColor) -> Double {
        let (lighter, darker) = (max(luminance, other.luminance), min(luminance, other.luminance))
        return (lighter + 0.05) / (darker + 0.05)
    }
}
