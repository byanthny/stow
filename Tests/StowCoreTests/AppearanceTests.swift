import Foundation
import Testing

@testable import StowCore

struct AppearanceTests {
    @Test func defaultThemeRoundTrips() throws {
        let settings = AppearanceSettings()
        #expect(try AppearanceSettings.decodeTheme(settings.encodedTheme()) == settings)
    }

    @Test func customThemeRoundTripsWithoutLosingFontNames() throws {
        var settings = AppearanceSettings.graphite
        settings.interfaceFontName = "Synthetic Sans"
        settings.editorFontName = "Synthetic Mono"
        settings.interfaceFontSize = 16
        settings.editorFontSize = 18
        settings.editorLineHeight = 1.5
        settings.backgroundOpacity = 0.75
        #expect(try AppearanceSettings.decodeTheme(settings.encodedTheme()) == settings)
    }

    @Test func purpleOutlinesReadInEveryBuiltInTheme() throws {
        for theme in [AppearanceSettings.default, .graphite, .paper] {
            let purple = try #require(RGBColor(hex: theme.colors.purple))
            #expect(theme.colors.purple == AppearanceColors.purple(for: theme.colorScheme), "\(theme.name)")
            for (name, hex) in [("background", theme.colors.background), ("surface", theme.colors.surface)] {
                let contrast = purple.contrast(with: try #require(RGBColor(hex: hex)))
                #expect(contrast >= 4.5, "\(theme.name) purple on \(name): \(contrast)")
            }
        }
    }

    @Test func themesWithoutAValidPurpleTakeTheirColorSchemes() throws {
        for theme in [AppearanceSettings.default, .graphite, .paper] {
            let saved = try #require(JSONSerialization.jsonObject(with: theme.encodedTheme()) as? [String: Any])
            var colors = try #require(saved["colors"] as? [String: Any])
            #expect(colors["purple"] as? String == theme.colors.purple)
            let damaged: [Any?] = [nil, "violet", "#12", 5, NSNull(), ["#A98BD9"]]
            for value in damaged {
                colors["purple"] = value
                var older = saved
                older["colors"] = colors
                let decoded = try AppearanceSettings.decodeTheme(JSONSerialization.data(withJSONObject: older))
                #expect(decoded == theme, "\(theme.name) with purple \(String(describing: value))")
            }
        }
        var custom = AppearanceSettings.paper
        custom.colors.purple = "#5A3E8C"
        #expect(try AppearanceSettings.decodeTheme(custom.encodedTheme()) == custom)
        custom.colors.purple = "violet"
        #expect(throws: AppearanceError.self) { try custom.validated() }
    }

    @Test func allPresetsValidate() throws {
        for theme in [AppearanceSettings.default, .graphite, .paper] { try theme.validated() }
    }

    @Test func invalidNumericValuesAreRejected() {
        for value in [-1.0, 0, 9, 23, .infinity, .nan] {
            var theme = AppearanceSettings()
            theme.interfaceFontSize = value
            #expect(throws: AppearanceError.self) { try theme.validated() }
        }
        var theme = AppearanceSettings()
        theme.backgroundOpacity = 1.01
        #expect(throws: AppearanceError.self) { try theme.validated() }
        theme = AppearanceSettings()
        theme.editorLineHeight = 0.9
        #expect(throws: AppearanceError.self) { try theme.validated() }
        theme = AppearanceSettings()
        theme.editorFontSize = 33
        #expect(throws: AppearanceError.self) { try theme.validated() }
    }

    @Test func inclusiveRangeBoundariesAreValid() throws {
        var theme = AppearanceSettings()
        theme.interfaceFontSize = 10
        theme.editorFontSize = 32
        theme.editorLineHeight = 2
        theme.backgroundOpacity = 0.2
        try theme.validated()
        theme.interfaceFontSize = 22
        theme.editorFontSize = 10
        theme.editorLineHeight = 1
        theme.backgroundOpacity = 1
        try theme.validated()
    }

    @Test func colorsMustBeSixDigitHex() {
        for color in ["red", "#fff", "FFFFFF", "#GG0000", "#00000000", "#12345é"] {
            var theme = AppearanceSettings()
            theme.colors.text = color
            #expect(throws: AppearanceError.self) { try theme.validated() }
        }
        #expect(AppearanceColors.isValidHex("#aBc123"))
    }

    @Test func unknownVersionsAndMissingFieldsAreRejected() throws {
        var theme = AppearanceSettings()
        theme.schemaVersion = 2
        #expect(throws: AppearanceError.self) { try theme.validated() }
        let validData = try AppearanceSettings().encodedTheme()
        var json = try #require(JSONSerialization.jsonObject(with: validData) as? [String: Any])
        json["schemaVersion"] = 99
        #expect(throws: AppearanceError.self) {
            try AppearanceSettings.decodeTheme(JSONSerialization.data(withJSONObject: json))
        }
        json.removeValue(forKey: "colors")
        #expect(throws: DecodingError.self) {
            try AppearanceSettings.decodeTheme(JSONSerialization.data(withJSONObject: json))
        }
    }

    @Test func directStateDecodingAlsoRejectsInvalidAppearance() throws {
        let data = try AppearanceSettings().encodedTheme()
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["backgroundOpacity"] = 5
        let invalid = try JSONSerialization.data(withJSONObject: json)
        #expect(throws: AppearanceError.self) {
            try JSONDecoder().decode(AppearanceSettings.self, from: invalid)
        }
    }

    @Test func emptyNamesAndControlCharactersAreRejected() {
        var theme = AppearanceSettings()
        theme.name = "  "
        #expect(throws: AppearanceError.self) { try theme.validated() }
        theme = AppearanceSettings()
        theme.editorFontName = "Font\nName"
        #expect(throws: AppearanceError.self) { try theme.validated() }
    }
}
