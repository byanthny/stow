import Foundation
import StowCore
import Testing

struct AppearanceConfigTests {
    @Test func copiedMinimalConfigAppliesOnlyItsOverrides() throws {
        let text = """
            font-family = JetBrains Mono
            font-size = 14
            background-opacity = 0.85
            """
        var expected = AppearanceSettings.default
        expected.editorFontName = "JetBrains Mono"
        expected.editorFontSize = 14
        expected.backgroundOpacity = 0.85
        #expect(try AppearanceSettings.decodeConfig(text) == expected)
    }

    @Test func writtenConfigsHaveNoPurpleSoOlderVersionsReadThem() throws {
        var lightStow = AppearanceSettings.default
        lightStow.colorScheme = .light
        for theme in [AppearanceSettings.default, .graphite, .paper, lightStow] {
            let config = try theme.encodedConfig()
            #expect(!config.contains("purple"), "\(config)")
            #expect(try AppearanceSettings.decodeConfig(config) == theme)
        }
        #expect(throws: AppearanceConfigError.self) { try AppearanceSettings.decodeConfig("purple = #6E4FA3") }
    }

    @Test func presetOrderDoesNotChangeTheResult() throws {
        let first = try AppearanceSettings.decodeConfig("preset = paper\nfont-size = 16\nbackground = #FFFFFF")
        let last = try AppearanceSettings.decodeConfig("background = #FFFFFF\nfont-size = 16\npreset = paper")
        #expect(first == last)
        #expect(first.colors.surface == AppearanceSettings.paper.colors.surface)
        #expect(first.colorScheme == .light)
        #expect(first.editorFontSize == 16)
    }

    @Test func commentsHexColorsSpacesAndEqualsAreLiteral() throws {
        let text = """
            # comments occupy their own line

              # leading spaces before a comment are fine
            preset = graphite
            name = quiet = useful
            font-family = Synthetic Mono # One
            ui-font-family = Synthetic Sans
            background = #aBc123
            """
        let result = try AppearanceSettings.decodeConfig(text)
        #expect(result.name == "quiet = useful")
        #expect(result.editorFontName == "Synthetic Mono # One")
        #expect(result.interfaceFontName == "Synthetic Sans")
        #expect(result.colors.background == "#aBc123")
        #expect(try AppearanceSettings.decodeConfig("\n # comment\r\n\n") == .default)
    }

    @Test func optionalJsonQuotesAndSystemFontAreUnambiguous() throws {
        let text = #"""
            name = "\"Quiet\" theme"
            font-family = "system"
            ui-font-family = system
            """#
        let result = try AppearanceSettings.decodeConfig(text)
        #expect(result.name == "\"Quiet\" theme")
        #expect(result.editorFontName == "system")
        #expect(result.interfaceFontName == nil)
        #expect(try AppearanceSettings.decodeConfig("font-family = system").editorFontName == nil)
    }

    @Test func shortExportUsesPresetAndOnlyOverrides() throws {
        #expect(try AppearanceSettings.default.encodedConfig() == "preset = stow\n")
        #expect(try AppearanceSettings.paper.encodedConfig() == "preset = paper\n")
        var settings = AppearanceSettings.graphite
        settings.editorFontName = "Synthetic Mono"
        settings.backgroundOpacity = 0.85
        let exported = try settings.encodedConfig()
        #expect(exported == "preset = graphite\nfont-family = Synthetic Mono\nbackground-opacity = 0.85\n")
        #expect(try AppearanceSettings.decodeConfig(exported) == settings)
    }

    @Test func exportedCustomAppearanceRoundTripsEverySetting() throws {
        for base in [AppearanceSettings.default, .graphite, .paper] {
            var settings = base
            settings.name = "  \"Synthetic\" = theme  "
            settings.colorScheme = base.colorScheme == .dark ? .light : .dark
            settings.editorFontName = "system"
            settings.interfaceFontName = "  Synthetic Sans  "
            settings.editorFontSize = 17.5
            settings.interfaceFontSize = 14
            settings.editorLineHeight = 1.65
            settings.backgroundOpacity = 0.79
            settings.colors.background = "#010203"
            settings.colors.surface = "#040506"
            settings.colors.note = "#070809"
            settings.colors.text = "#F0F1F2"
            settings.colors.muted = "#A0A1A2"
            settings.colors.amber = "#B0B1B2"
            settings.colors.red = "#C0C1C2"
            settings.colors.green = "#D0D1D2"
            let exported = try settings.encodedConfig()
            #expect(try AppearanceSettings.decodeConfig(exported) == settings)
            #expect(try settings.encodedConfig() == exported)
        }
    }

    @Test func failuresIdentifyThePhysicalLineIncludingCrLf() throws {
        for (text, expectedLine) in [
            ("# comment\r\n\r\nunknown = value", 3),
            ("preset = stow\nfont-size 14", 2),
            ("font-size = 14\nfont-size = 15", 2),
            ("preset = stow\npreset = stow", 2),
            ("\nbackground-opacity = 9", 2),
        ] {
            do {
                _ = try AppearanceSettings.decodeConfig(text)
                Issue.record("Expected config to fail")
            } catch let error as AppearanceConfigError {
                guard case .invalidLine(let line, _) = error else {
                    Issue.record("Expected a line-specific error")
                    continue
                }
                #expect(line == expectedLine)
                #expect(error.localizedDescription.hasPrefix("Line \(expectedLine):"))
            }
        }
    }

    @Test func malformedAndInvalidValuesRejectTheEntireConfig() {
        for line in [
            "preset = unknown", "color-scheme = system", "font-size = nine", "font-size = 9",
            "font-size = NaN", "font-size = inf", "ui-font-size = 23", "line-height = 0.9",
            "background-opacity = 0.1", "background-opacity = 1.01", "background = #xyzxyz",
            "font-family =", "name = \" \"", "font-family = \"Unfinished", "schema-version = 2",
            "schemaVersion = 1", " = value", "font-family = \"Synthetic\\nMono\"",
            "background-opacity = 0.8 # inline comments are not supported",
        ] {
            #expect(throws: AppearanceConfigError.self) {
                try AppearanceSettings.decodeConfig("preset = graphite\n\(line)")
            }
        }
    }

    @Test func sizeLimitCountsUtf8Bytes() throws {
        let exactLimit = "#" + String(repeating: "a", count: 1_048_575)
        #expect(try AppearanceSettings.decodeConfig(exactLimit) == .default)
        #expect(throws: AppearanceConfigError.self) { try AppearanceSettings.decodeConfig(exactLimit + "a") }
        #expect(throws: AppearanceConfigError.self) {
            try AppearanceSettings.decodeConfig("#" + String(repeating: "é", count: 600_000))
        }
    }

    @Test func localImportBoundsAndEncodingMatchPastedConfigValidation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "StowThemeConfigTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("synthetic-theme.conf")
        let config = try AppearanceSettings.graphite.encodedConfig()
        try Data(config.utf8).write(to: url)
        #expect(try ThemeConfigTransfer.decode(ThemeConfigTransfer.read(url)) == .graphite)
        #expect(throws: AppearanceError.invalidValue("text encoding; use UTF-8")) {
            try ThemeConfigTransfer.decode(Data([0xFF, 0xFE, 0xFF]))
        }
        let oversized = Data(repeating: 0x20, count: ThemeConfigTransfer.maximumBytes + 1)
        #expect(throws: AppearanceError.invalidValue("config size (maximum 1 MB)")) {
            try ThemeConfigTransfer.decode(oversized)
        }
        try oversized.write(to: url)
        #expect(throws: AppearanceError.invalidValue("file size (maximum 1 MB)")) { try ThemeConfigTransfer.read(url) }
        try oversized.dropLast().write(to: url)
        #expect(try ThemeConfigTransfer.read(url).count == ThemeConfigTransfer.maximumBytes)
    }

    @Test func transferDecodesConfigsAndLegacyJSONThemes() throws {
        var custom = AppearanceSettings.paper
        custom.name = "Synthetic message theme"
        custom.editorFontSize = 18
        custom.colors.text = "#E1E2E3"
        #expect(try ThemeConfigTransfer.decode(Data(custom.encodedConfig().utf8)) == custom)
        let legacy = Data(" \n\t".utf8) + (try custom.encodedTheme())
        #expect(try ThemeConfigTransfer.decode(legacy) == custom)
        #expect(throws: AppearanceConfigError.self) {
            try ThemeConfigTransfer.decode(Data("unknown-setting = should fail".utf8))
        }
    }

    @Test func invalidCanonicalSettingsCannotExport() {
        var settings = AppearanceSettings()
        settings.schemaVersion = 2
        #expect(throws: AppearanceError.self) { try settings.encodedConfig() }
    }

    @Test func originalJsonFormatRemainsCompatible() throws {
        var settings = AppearanceSettings.paper
        settings.editorFontName = "Synthetic Mono"
        settings.backgroundOpacity = 0.8
        let json = try settings.encodedTheme()
        #expect(try AppearanceSettings.decodeTheme(json) == settings)
        #expect(try AppearanceSettings.decodeConfig(settings.encodedConfig()) == settings)
    }
}
