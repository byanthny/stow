import Foundation

/// A color for each repository, so pull request cards from different repositories are quick to tell apart.
public enum RepositoryColor {
    /// Hues from cyan to pink, clear of the red, amber, and green that statuses use.
    static let hues: [Double] = [190, 212, 236, 262, 290, 318]

    /// A `#RRGGBB` color for the reference's repository that reads at 4.5:1 or better on `surface`.
    public static func hex(for reference: PullRequestReference, onSurface surface: String) -> String {
        let name = "\(reference.owner)/\(reference.repository)".lowercased()
        let hue = hues[Int(name.stableHash % UInt64(hues.count))]
        let background = RGBColor(hex: surface) ?? RGBColor(hue: 0, saturation: 0, lightness: 0.1)
        // Below this luminance white contrasts more than black, so the color lightens; otherwise it darkens.
        let lightens = background.luminance < 0.179
        var lightness = lightens ? 0.6 : 0.42
        var color = RGBColor(hue: hue, saturation: 0.6, lightness: lightness)
        while color.contrast(with: background) < 4.5, (0.02...0.98).contains(lightness) {
            lightness += lightens ? 0.02 : -0.02
            color = RGBColor(hue: hue, saturation: 0.6, lightness: lightness)
        }
        return color.hex
    }
}
