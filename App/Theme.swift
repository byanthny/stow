import AppKit
import Observation
import StowCore
import SwiftUI

/// An immutable copy of one store's appearance. Views read it from the environment.
struct StowTheme: Equatable, Sendable {
    var settings: AppearanceSettings
    var reduceTransparency: Bool

    var colorScheme: ColorScheme { settings.colorScheme == .dark ? .dark : .light }
    var effectiveBackgroundOpacity: Double { reduceTransparency ? 1 : settings.backgroundOpacity }
    var isDark: Bool { settings.colorScheme == .dark }

    func font(size: CGFloat = 13, weight: Font.Weight = .regular) -> Font {
        let adjustedSize = max(8, size + settings.interfaceFontSize - 13)
        if let name = settings.interfaceFontName, NSFont(name: name, size: adjustedSize) != nil {
            return .custom(name, fixedSize: adjustedSize).weight(weight)
        }
        return .system(size: adjustedSize, weight: weight)
    }

    func color(_ role: StowColor.Role) -> Color {
        let colors = settings.colors
        switch role {
        case .background: return Color.stowHex(colors.background).opacity(effectiveBackgroundOpacity)
        case .surface: return Color.stowHex(colors.surface).opacity(effectiveBackgroundOpacity)
        case .note: return Color.stowHex(colors.note).opacity(effectiveBackgroundOpacity)
        case .text: return Color.stowHex(colors.text)
        case .muted: return Color.stowHex(colors.muted)
        case .amber: return Color.stowHex(colors.amber)
        case .red: return Color.stowHex(colors.red)
        case .green: return Color.stowHex(colors.green)
        }
    }

    var textNSColor: NSColor { NSColor(Color.stowHex(settings.colors.text)) }
    var appKitAppearance: NSAppearance? { NSAppearance(named: isDark ? .darkAqua : .aqua) }
}

extension EnvironmentValues {
    @Entry var stowTheme = StowTheme(settings: .default, reduceTransparency: false)
}

/// A theme color resolved from the environment of the view that uses it.
struct StowColor: ShapeStyle {
    enum Role: Sendable { case background, surface, note, text, muted, amber, red, green }
    let role: Role

    func resolve(in environment: EnvironmentValues) -> Color { environment.stowTheme.color(role) }
}

extension ShapeStyle where Self == StowColor {
    static var stowBackground: StowColor { StowColor(role: .background) }
    static var stowSurface: StowColor { StowColor(role: .surface) }
    static var stowNote: StowColor { StowColor(role: .note) }
    static var stowText: StowColor { StowColor(role: .text) }
    static var stowMuted: StowColor { StowColor(role: .muted) }
    static var stowAmber: StowColor { StowColor(role: .amber) }
    static var stowRed: StowColor { StowColor(role: .red) }
    static var stowGreen: StowColor { StowColor(role: .green) }
}

/// One per store: windows of different stores never share a theme.
@MainActor @Observable final class ThemeController {
    private(set) var settings = AppearanceSettings.default
    private(set) var reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    @ObservationIgnored nonisolated(unsafe) private var accessibilityObserver: NSObjectProtocol?

    init() {
        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
            }
        }
    }

    deinit {
        if let accessibilityObserver { NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver) }
    }

    var snapshot: StowTheme { StowTheme(settings: settings, reduceTransparency: reduceTransparency) }

    func apply(_ settings: AppearanceSettings) {
        guard (try? settings.validated()) != nil else { return }
        self.settings = settings
    }
}

/// Injects the store's current theme; reading `snapshot` here re-renders the window when it changes.
private struct ThemedBy: ViewModifier {
    let theme: ThemeController
    func body(content: Content) -> some View { content.environment(\.stowTheme, theme.snapshot) }
}

extension View {
    func themed(by theme: ThemeController) -> some View { modifier(ThemedBy(theme: theme)) }
}

extension Color {
    static func stowHex(_ value: String) -> Color {
        let rgb = UInt32(value.dropFirst(), radix: 16) ?? 0
        return Color(
            .sRGB, red: Double((rgb >> 16) & 255) / 255,
            green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255, opacity: 1)
    }
}

struct QuietIconButton: View {
    let symbol: String
    let label: String
    var action: () -> Void
    var body: some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 22, height: 22).contentShape(Rectangle()) }
            .buttonStyle(.plain).foregroundStyle(.stowMuted)
            .help(label).accessibilityLabel(label)
    }
}
