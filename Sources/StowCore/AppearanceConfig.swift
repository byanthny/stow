import Foundation

public enum AppearanceConfigError: LocalizedError, Equatable, Sendable {
    case tooLarge
    case invalidLine(Int, String)

    public var errorDescription: String? {
        switch self {
        case .tooLarge: "The theme config is larger than 1 MB."
        case .invalidLine(let line, let message): "Line \(line): \(message)"
        }
    }
}

extension AppearanceSettings {
    /// Applies partial overrides to a deterministic built-in preset, never the current app state.
    /// Values may be unquoted, or JSON strings when leading/trailing spaces or quotes must be preserved.
    public static func decodeConfig(_ text: String) throws -> AppearanceSettings {
        guard text.utf8.count <= 1_048_576 else { throw AppearanceConfigError.tooLarge }
        var entries: [ConfigEntry] = []
        var seen: Set<String> = []
        for (offset, rawLine) in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated()
        {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let number = offset + 1
            guard let separator = line.firstIndex(of: "=") else {
                throw AppearanceConfigError.invalidLine(number, "Use key = value.")
            }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces)
            guard ConfigEntry.keys.contains(key) else {
                throw AppearanceConfigError.invalidLine(number, "Unknown setting ‘\(key.prefix(80))’.")
            }
            guard seen.insert(key).inserted else {
                throw AppearanceConfigError.invalidLine(number, "‘\(key)’ appears more than once.")
            }
            let rawValue = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            guard !rawValue.isEmpty else {
                throw AppearanceConfigError.invalidLine(number, "‘\(key)’ needs a value.")
            }
            let quoted = rawValue.hasPrefix("\"")
            let value: String
            if quoted {
                do { value = try JSONDecoder().decode(String.self, from: Data(rawValue.utf8)) } catch {
                    throw AppearanceConfigError.invalidLine(number, "Use a complete JSON-quoted string.")
                }
            } else {
                value = rawValue
            }
            entries.append(ConfigEntry(key: key, value: value, line: number, quoted: quoted))
        }

        var result = AppearanceSettings.default
        if let preset = entries.first(where: { $0.key == "preset" }) {
            guard let theme = ConfigEntry.presets.first(where: { $0.key == preset.value })?.settings else {
                throw AppearanceConfigError.invalidLine(preset.line, "Preset must be stow, graphite, or paper.")
            }
            result = theme
        }
        for entry in entries where entry.key != "preset" {
            switch entry.key {
            case "name": result.name = entry.value
            case "color-scheme":
                guard let scheme = AppearanceColorScheme(rawValue: entry.value) else {
                    throw AppearanceConfigError.invalidLine(entry.line, "Color scheme must be dark or light.")
                }
                result.colorScheme = scheme
            case "font-family": result.editorFontName = entry.fontName
            case "font-size": result.editorFontSize = try entry.number()
            case "ui-font-family": result.interfaceFontName = entry.fontName
            case "ui-font-size": result.interfaceFontSize = try entry.number()
            case "line-height": result.editorLineHeight = try entry.number()
            case "background-opacity": result.backgroundOpacity = try entry.number()
            case "background": result.colors.background = entry.value
            case "surface": result.colors.surface = entry.value
            case "note": result.colors.note = entry.value
            case "text": result.colors.text = entry.value
            case "muted": result.colors.muted = entry.value
            case "amber": result.colors.amber = entry.value
            case "red": result.colors.red = entry.value
            case "green": result.colors.green = entry.value
            case "purple": result.colors.purple = entry.value
            default: preconditionFailure("Config keys are checked before applying overrides")
            }
            do { try result.validated() } catch {
                throw AppearanceConfigError.invalidLine(entry.line, error.localizedDescription)
            }
        }
        return try result.validated()
    }

    /// Emits only differences from the closest built-in preset, in a stable order.
    /// Ties prefer Stow, then Graphite, then Paper. No local paths or other app data are included.
    public func encodedConfig() throws -> String {
        try validated()
        var best: [String] = []
        for preset in ConfigEntry.presets {
            let lines = try configLines(preset: preset.key, base: preset.settings)
            if best.isEmpty || lines.count < best.count { best = lines }
        }
        return best.joined(separator: "\n") + "\n"
    }

    private func configLines(preset: String, base: AppearanceSettings) throws -> [String] {
        var lines = ["preset = \(preset)"]
        if name != base.name { lines.append("name = \(try ConfigEntry.string(name))") }
        if colorScheme != base.colorScheme { lines.append("color-scheme = \(colorScheme.rawValue)") }
        if editorFontName != base.editorFontName {
            lines.append("font-family = \(try editorFontName.map(ConfigEntry.string) ?? "system")")
        }
        if editorFontSize != base.editorFontSize { lines.append("font-size = \(ConfigEntry.number(editorFontSize))") }
        if interfaceFontName != base.interfaceFontName {
            lines.append("ui-font-family = \(try interfaceFontName.map(ConfigEntry.string) ?? "system")")
        }
        if interfaceFontSize != base.interfaceFontSize {
            lines.append("ui-font-size = \(ConfigEntry.number(interfaceFontSize))")
        }
        if editorLineHeight != base.editorLineHeight {
            lines.append("line-height = \(ConfigEntry.number(editorLineHeight))")
        }
        if backgroundOpacity != base.backgroundOpacity {
            lines.append("background-opacity = \(ConfigEntry.number(backgroundOpacity))")
        }
        for (key, value, original) in [
            ("background", colors.background, base.colors.background),
            ("surface", colors.surface, base.colors.surface),
            ("note", colors.note, base.colors.note),
            ("text", colors.text, base.colors.text),
            ("muted", colors.muted, base.colors.muted),
            ("amber", colors.amber, base.colors.amber),
            ("red", colors.red, base.colors.red),
            ("green", colors.green, base.colors.green),
            ("purple", colors.purple, base.colors.purple),
        ] where value != original {
            lines.append("\(key) = \(value)")
        }
        return lines
    }
}

private struct ConfigEntry {
    let key: String
    let value: String
    let line: Int
    let quoted: Bool

    static let keys: Set<String> = [
        "preset", "name", "color-scheme", "font-family", "font-size", "ui-font-family", "ui-font-size",
        "line-height", "background-opacity", "background", "surface", "note", "text", "muted", "amber", "red", "green",
        "purple",
    ]
    static let presets: [(key: String, settings: AppearanceSettings)] = [
        ("stow", .default), ("graphite", .graphite), ("paper", .paper),
    ]

    var fontName: String? { !quoted && value == "system" ? nil : value }

    func number() throws -> Double {
        guard let number = Double(value), number.isFinite else {
            throw AppearanceConfigError.invalidLine(line, "‘\(key)’ needs a finite number.")
        }
        return number
    }

    static func number(_ value: Double) -> String {
        value.rounded(.towardZero) == value ? String(Int(value)) : String(value)
    }

    static func string(_ value: String) throws -> String {
        guard
            value.hasPrefix("\"") || value == "system"
                || value.trimmingCharacters(in: .whitespacesAndNewlines) != value
        else { return value }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}
