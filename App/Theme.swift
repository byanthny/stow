import AppKit
import Observation
import StowCore
import SwiftUI

@MainActor @Observable final class ThemeController {
    static let shared = ThemeController()
    private(set) var settings = AppearanceSettings.default
    private(set) var reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    @ObservationIgnored private var accessibilityObserver: NSObjectProtocol?

    private init() {
        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
            }
        }
    }

    var colorScheme: ColorScheme { settings.colorScheme == .dark ? .dark : .light }
    var effectiveBackgroundOpacity: Double { reduceTransparency ? 1 : settings.backgroundOpacity }
    var editorFont: NSFont {
        settings.editorFontName.flatMap { NSFont(name: $0, size: settings.editorFontSize) }
            ?? .systemFont(ofSize: settings.editorFontSize)
    }

    func apply(_ settings: AppearanceSettings) {
        guard (try? settings.validated()) != nil else { return }
        self.settings = settings
    }
}

extension Color {
    @MainActor static var stowBackground: Color {
        themeColor(ThemeController.shared.settings.colors.background, background: true)
    }
    @MainActor static var stowSurface: Color {
        themeColor(ThemeController.shared.settings.colors.surface, background: true)
    }
    @MainActor static var stowNote: Color { themeColor(ThemeController.shared.settings.colors.note, background: true) }
    @MainActor static var stowText: Color { themeColor(ThemeController.shared.settings.colors.text) }
    @MainActor static var stowMuted: Color { themeColor(ThemeController.shared.settings.colors.muted) }
    @MainActor static var stowAmber: Color { themeColor(ThemeController.shared.settings.colors.amber) }
    @MainActor static var stowRed: Color { themeColor(ThemeController.shared.settings.colors.red) }
    @MainActor static var stowGreen: Color { themeColor(ThemeController.shared.settings.colors.green) }

    static func stowHex(_ value: String) -> Color {
        let rgb = UInt32(value.dropFirst(), radix: 16) ?? 0
        return Color(
            .sRGB, red: Double((rgb >> 16) & 255) / 255,
            green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255, opacity: 1)
    }

    @MainActor private static func themeColor(_ hex: String, background: Bool = false) -> Color {
        stowHex(hex).opacity(background ? ThemeController.shared.effectiveBackgroundOpacity : 1)
    }
}

extension Font {
    @MainActor static func stow(size: CGFloat = 13, weight: Font.Weight = .regular) -> Font {
        let settings = ThemeController.shared.settings
        let adjustedSize = max(8, size + settings.interfaceFontSize - 13)
        if let name = settings.interfaceFontName, NSFont(name: name, size: adjustedSize) != nil {
            return .custom(name, fixedSize: adjustedSize).weight(weight)
        }
        return .system(size: adjustedSize, weight: weight)
    }
}

extension NSFont {
    /// The AppKit counterpart of `Font.stow`, for AppKit controls inside SwiftUI views.
    @MainActor static func stow(size: CGFloat = 13) -> NSFont {
        let settings = ThemeController.shared.settings
        let adjustedSize = max(8, size + settings.interfaceFontSize - 13)
        return settings.interfaceFontName.flatMap { NSFont(name: $0, size: adjustedSize) }
            ?? .systemFont(ofSize: adjustedSize)
    }
}

struct QuietIconButton: View {
    let symbol: String
    let label: String
    var action: () -> Void
    var body: some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 22, height: 22).contentShape(Rectangle()) }
            .buttonStyle(.plain).foregroundStyle(Color.stowMuted)
            .help(label).accessibilityLabel(label)
    }
}
