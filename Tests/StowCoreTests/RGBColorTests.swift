import Foundation
import Testing

@testable import StowCore

struct RGBColorTests {
    /// The profile palette's own conversion before it moved here: channels and `#RRGGBB`.
    private func previousHSB(
        hue: Double, saturation: Double, brightness: Double
    ) -> (red: Double, green: Double, blue: Double, hex: String) {
        let sector = hue * 6
        let fraction = sector - sector.rounded(.down)
        let low = brightness * (1 - saturation)
        let falling = brightness * (1 - saturation * fraction)
        let rising = brightness * (1 - saturation * (1 - fraction))
        let (red, green, blue) =
            switch Int(sector) % 6 {
            case 0: (brightness, rising, low)
            case 1: (falling, brightness, low)
            case 2: (low, brightness, rising)
            case 3: (low, falling, brightness)
            case 4: (rising, low, brightness)
            default: (brightness, low, falling)
            }
        let bytes = [red, green, blue].map { Int(($0 * 255).rounded()) }
        return (red, green, blue, String(format: "#%02X%02X%02X", bytes[0], bytes[1], bytes[2]))
    }

    /// The theme's own `#RRGGBB` parsing before it used `RGBColor`.
    private func previousThemeChannels(_ value: String) -> (red: Double, green: Double, blue: Double) {
        let rgb = UInt32(value.dropFirst(), radix: 16) ?? 0
        return (Double((rgb >> 16) & 255) / 255, Double((rgb >> 8) & 255) / 255, Double(rgb & 255) / 255)
    }

    /// The color picker's own `#RRGGBB` formatting before it used `RGBColor`.
    private func previousPickerHex(_ red: Double, _ green: Double, _ blue: Double) -> String {
        String(
            format: "#%02X%02X%02X", Int((red * 255).rounded()), Int((green * 255).rounded()),
            Int((blue * 255).rounded()))
    }

    /// Every hue, saturation, and brightness the profile palette asks for after its fixed colors.
    private var paletteArguments: [(hue: Double, saturation: Double, brightness: Double)] {
        (0..<(360 * 9)).map { step in
            let round = step / 360
            return (
                Double(step * 137 % 360) / 360, 0.7 - 0.15 * Double(round % 3), 0.9 - 0.15 * Double(round / 3)
            )
        }
    }

    @Test func hsbMatchesThePreviousConversionBitForBit() {
        var arguments = paletteArguments
        for hue in 0...120 {
            for saturation in 0...20 {
                for brightness in 0...20 {
                    arguments.append((Double(hue) / 120, Double(saturation) / 20, Double(brightness) / 20))
                }
            }
        }
        for (hue, saturation, brightness) in arguments {
            let color = RGBColor(hue: hue, saturation: saturation, brightness: brightness)
            let previous = previousHSB(hue: hue, saturation: saturation, brightness: brightness)
            #expect(color.red.bitPattern == previous.red.bitPattern, "\(hue) \(saturation) \(brightness)")
            #expect(color.green.bitPattern == previous.green.bitPattern, "\(hue) \(saturation) \(brightness)")
            #expect(color.blue.bitPattern == previous.blue.bitPattern, "\(hue) \(saturation) \(brightness)")
            #expect(color.hex == previous.hex, "\(hue) \(saturation) \(brightness)")
        }
    }

    @Test func hexParsingMatchesThePreviousThemeConversionBitForBit() throws {
        var values = (0...255).map { String(format: "#%02X%02X%02X", $0, 255 - $0, $0 * 7 % 256) }
        values += values.map { $0.lowercased() }
        for theme in [AppearanceSettings.default, .graphite, .paper] {
            values += theme.colors.values + [theme.purple]
        }
        values += ProfilePalette.colors + ["#000000", "#FFFFFF", "#8E8E93"]
        for value in values {
            let color = try #require(RGBColor(hex: value))
            let previous = previousThemeChannels(value)
            #expect(color.red.bitPattern == previous.red.bitPattern, "\(value)")
            #expect(color.green.bitPattern == previous.green.bitPattern, "\(value)")
            #expect(color.blue.bitPattern == previous.blue.bitPattern, "\(value)")
        }
    }

    @Test func hexMatchesThePreviousPickerFormattingAndClampsOutOfRangeChannels() {
        for step in 0...1000 {
            let channel = Double(step) / 1000
            let mixed = (channel, 1 - channel, Double(step * 7 % 1001) / 1000)
            #expect(
                RGBColor(red: mixed.0, green: mixed.1, blue: mixed.2).hex
                    == previousPickerHex(mixed.0, mixed.1, mixed.2))
        }
        #expect(RGBColor(red: -0.2, green: 1.3, blue: 0.5).hex == "#00FF80")
    }

    @Test func paletteColorsRoundTripThroughHex() throws {
        var colors = ProfilePalette.colors
        for _ in 0..<40 { colors.append(ProfilePalette.firstUnused(among: colors)) }
        #expect(Set(colors).count == colors.count)
        for color in colors {
            let parsed = try #require(RGBColor(hex: color))
            #expect(parsed.hex == color)
            #expect(RGBColor(red: parsed.red, green: parsed.green, blue: parsed.blue).hex == color)
        }
        for (hue, saturation, brightness) in paletteArguments {
            let hex = RGBColor(hue: hue, saturation: saturation, brightness: brightness).hex
            #expect(RGBColor(hex: hex)?.hex == hex)
        }
    }
}
