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
        // Below this luminance, white contrasts more than black.
        let lightens = background.luminance < 0.179
        let steps = lightens ? stride(from: 0.6, through: 1, by: 0.02) : stride(from: 0.42, through: 0, by: -0.02)
        for lightness in steps {
            let color = RGBColor(hue: hue, saturation: 0.6, lightness: lightness).rounded
            if color.contrast(with: background) >= 4.5 { return color.hex }
        }
        return lightens ? "#FFFFFF" : "#000000"
    }
}
