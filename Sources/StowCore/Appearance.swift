import Foundation

public enum AppearanceColorScheme: String, Codable, CaseIterable, Sendable {
    case dark, light
}

/// Portable theme data. Font names are resolved on the host and never execute code.
public struct AppearanceColors: Codable, Equatable, Sendable {
    public var background = "#0E0F11"
    public var surface = "#1B1C1F"
    public var note = "#1F2022"
    public var text = "#E8E8E6"
    public var muted = "#91969E"
    public var amber = "#D9A659"
    public var red = "#E0736E"
    public var green = "#7DB38F"

    public init() {}

    public static func isValidHex(_ value: String) -> Bool {
        value.count == 7 && value.first == "#"
            && value.dropFirst().unicodeScalars.allSatisfy {
                (48...57).contains($0.value) || (65...70).contains($0.value) || (97...102).contains($0.value)
            }
    }

    var values: [String] { [background, surface, note, text, muted, amber, red, green] }
}

public enum AppearanceError: LocalizedError, Equatable {
    case unsupportedVersion(Int)
    case invalidValue(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version): "Theme version \(version) is not supported. Stow supports version 1."
        case .invalidValue(let field): "The theme has an invalid \(field). See the theme format for accepted values."
        }
    }
}

public struct AppearanceSettings: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var name = "Stow"
    public var colorScheme = AppearanceColorScheme.dark
    public var colors = AppearanceColors()
    /// nil selects the macOS system font. Stored names may be unavailable on another Mac.
    public var interfaceFontName: String?
    public var editorFontName: String?
    public var interfaceFontSize = 13.0
    public var editorFontSize = 13.0
    public var editorLineHeight = 1.3
    public var backgroundOpacity = 1.0

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, name, colorScheme, colors, interfaceFontName, editorFontName
        case interfaceFontSize, editorFontSize, editorLineHeight, backgroundOpacity
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        name = try container.decode(String.self, forKey: .name)
        colorScheme = try container.decode(AppearanceColorScheme.self, forKey: .colorScheme)
        colors = try container.decode(AppearanceColors.self, forKey: .colors)
        interfaceFontName = try container.decodeIfPresent(String.self, forKey: .interfaceFontName)
        editorFontName = try container.decodeIfPresent(String.self, forKey: .editorFontName)
        interfaceFontSize = try container.decode(Double.self, forKey: .interfaceFontSize)
        editorFontSize = try container.decode(Double.self, forKey: .editorFontSize)
        editorLineHeight = try container.decode(Double.self, forKey: .editorLineHeight)
        backgroundOpacity = try container.decode(Double.self, forKey: .backgroundOpacity)
        try validated()
    }

    public static let `default` = AppearanceSettings()

    public static var graphite: AppearanceSettings {
        var theme = AppearanceSettings()
        theme.name = "Graphite"
        theme.colors.background = "#17191D"
        theme.colors.surface = "#24272E"
        theme.colors.note = "#2A2E36"
        theme.colors.text = "#E1E5EC"
        theme.colors.muted = "#9CA6B5"
        theme.colors.amber = "#DDBA75"
        theme.colors.red = "#ED8A93"
        theme.colors.green = "#96C5A5"
        return theme
    }

    public static var paper: AppearanceSettings {
        var theme = AppearanceSettings()
        theme.name = "Paper"
        theme.colorScheme = .light
        theme.colors.background = "#EDEBE5"
        theme.colors.surface = "#F7F5F0"
        theme.colors.note = "#FFFDFA"
        theme.colors.text = "#282B30"
        theme.colors.muted = "#666A73"
        theme.colors.amber = "#8C611C"
        theme.colors.red = "#AD3E39"
        theme.colors.green = "#356C47"
        return theme
    }

    /// Rejects invalid imports as a whole, before anything is applied or saved.
    @discardableResult public func validated() throws -> AppearanceSettings {
        guard schemaVersion == 1 else { throw AppearanceError.unsupportedVersion(schemaVersion) }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 80,
            !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { throw AppearanceError.invalidValue("name") }
        guard colors.values.allSatisfy(AppearanceColors.isValidHex) else {
            throw AppearanceError.invalidValue("color; use #RRGGBB")
        }
        for (name, value, range) in [
            ("interface font size", interfaceFontSize, 10.0...22.0),
            ("editor font size", editorFontSize, 10.0...32.0),
            ("editor line height", editorLineHeight, 1.0...2.0),
            ("background opacity", backgroundOpacity, 0.2...1.0),
        ] {
            guard value.isFinite, range.contains(value) else { throw AppearanceError.invalidValue(name) }
        }
        for font in [interfaceFontName, editorFontName].compactMap({ $0 }) {
            guard !font.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, font.count <= 200,
                !font.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            else { throw AppearanceError.invalidValue("font name") }
        }
        return self
    }

    public static func decodeTheme(_ data: Data) throws -> AppearanceSettings {
        try JSONDecoder().decode(Self.self, from: data).validated()
    }

    public func encodedTheme() throws -> Data {
        try validated()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}
