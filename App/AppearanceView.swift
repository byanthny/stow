import AppKit
import StowCore
import SwiftUI
import UniformTypeIdentifiers

struct AppearanceView: View {
    @Bindable var store: AppStore
    @State private var importError: String?
    private var settings: AppearanceSettings { store.state.appearance }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Appearance").font(.stow(size: 14, weight: .semibold))
                Spacer()
                Menu {
                    Button("Stow · dark") { preset(.default) }
                    Button("Graphite · dark") { preset(.graphite) }
                    Button("Paper · light") { preset(.paper) }
                } label: {
                    Text(settings.name)
                }
                .fixedSize().accessibilityLabel("Theme preset")
            }
            Text("Make Stow feel at home. Changes apply to the board and every open note.")
                .font(.stow(size: 11)).foregroundStyle(Color.stowMuted)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    Text("Interface")
                    AppearanceFontPicker(selection: binding(\.interfaceFontName), label: "Interface font")
                    sizeStepper(binding(\.interfaceFontSize), range: 10...22, label: "Interface font size")
                }
                GridRow {
                    Text("Notes")
                    AppearanceFontPicker(selection: binding(\.editorFontName), label: "Note font")
                    sizeStepper(binding(\.editorFontSize), range: 10...32, label: "Note font size")
                }
                GridRow {
                    Text("Line height")
                    Slider(value: binding(\.editorLineHeight), in: 1...2, step: 0.05)
                        .accessibilityLabel("Note line height")
                    Text(settings.editorLineHeight, format: .number.precision(.fractionLength(2)))
                        .monospacedDigit().foregroundStyle(Color.stowMuted)
                }
            }.font(.stow(size: 12))
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("Background opacity")
                    Spacer()
                    Text(settings.backgroundOpacity, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit().foregroundStyle(Color.stowMuted)
                }
                Slider(value: binding(\.backgroundOpacity), in: 0.2...1, step: 0.01)
                    .accessibilityLabel("Background opacity")
                Text(
                    ThemeController.shared.reduceTransparency
                        ? "Reduce Transparency is on in macOS. Your opacity preference is saved and backgrounds stay solid."
                        : "Only backgrounds become transparent; text stays clear."
                )
                .font(.stow(size: 10)).foregroundStyle(Color.stowMuted)
            }.font(.stow(size: 12))
            DisclosureGroup("Colors") {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 10) {
                    colorPicker("Background", \.background)
                    colorPicker("Surface", \.surface)
                    colorPicker("Note", \.note)
                    colorPicker("Text", \.text)
                    colorPicker("Muted", \.muted)
                    colorPicker("Attention", \.amber)
                    colorPicker("Failure", \.red)
                    colorPicker("Ready", \.green)
                }.padding(.top, 8)
            }.font(.stow(size: 12))
            HStack(spacing: 10) {
                Button("Import theme…") { importTheme() }.accessibilityIdentifier("appearance.import")
                Button("Export theme…") { exportTheme() }.accessibilityIdentifier("appearance.export")
                Spacer()
                Button("Reset") { store.applyAppearance(.default) }.help("Restore all default appearance settings")
            }.font(.stow(size: 11))
            Text("Themes are small JSON files containing only colors, fonts, sizes, and opacity.")
                .font(.stow(size: 10)).foregroundStyle(Color.stowMuted)
        }
        .alert("Theme error", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } }))
        {
            Button("OK") { importError = nil }
        } message: {
            Text(importError ?? "The theme could not be read.")
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<AppearanceSettings, Value>) -> Binding<Value> {
        Binding(
            get: { store.state.appearance[keyPath: keyPath] },
            set: { value in
                var updated = store.state.appearance
                updated[keyPath: keyPath] = value
                store.applyAppearance(updated)
            })
    }

    private func sizeStepper(_ value: Binding<Double>, range: ClosedRange<Double>, label: String) -> some View {
        Stepper(value: value, in: range, step: 1) {
            Text(value.wrappedValue, format: .number.precision(.fractionLength(0)))
                .monospacedDigit().frame(minWidth: 20, alignment: .trailing)
        }.fixedSize().accessibilityLabel(label)
    }

    private func colorPicker(_ label: String, _ keyPath: WritableKeyPath<AppearanceColors, String>) -> some View {
        ColorPicker(
            label,
            selection: Binding(
                get: {
                    Color.stowHex(settings.colors[keyPath: keyPath])
                },
                set: { color in
                    guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
                    var updated = store.state.appearance
                    updated.colors[keyPath: keyPath] = String(
                        format: "#%02X%02X%02X", Int((rgb.redComponent * 255).rounded()),
                        Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
                    updated.name = "Custom"
                    store.applyAppearance(updated)
                }), supportsOpacity: false)
    }

    private func preset(_ theme: AppearanceSettings) {
        var updated = settings
        updated.name = theme.name
        updated.colors = theme.colors
        updated.colorScheme = theme.colorScheme
        store.applyAppearance(updated)
    }

    private func importTheme() {
        let panel = NSOpenPanel()
        panel.title = "Import Stow theme"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 1_048_576 else { throw AppearanceError.invalidValue("file size (maximum 1 MB)") }
            let imported = try AppearanceSettings.decodeTheme(Data(contentsOf: url))
            store.applyAppearance(imported)
        } catch {
            importError = "Your current appearance has been kept. \(error.localizedDescription)"
        }
    }

    private func exportTheme() {
        let panel = NSSavePanel()
        panel.title = "Export Stow theme"
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "stow-theme.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try settings.encodedTheme().write(to: url, options: .atomic) } catch {
            importError = "The theme could not be saved. \(error.localizedDescription)"
        }
    }
}

private struct AppearanceFontPicker: View {
    @Binding var selection: String?
    let label: String
    @State private var showing = false
    @State private var search = ""
    private var selectedName: String {
        guard let selection else { return "System font" }
        return NSFont(name: selection, size: 13)?.displayName ?? "\(selection) (unavailable)"
    }
    private var filteredFonts: [String] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return Self.fonts.filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }
    }
    private static let fonts = NSFontManager.shared.availableFonts.filter { !$0.hasPrefix(".") }.sorted {
        $0.localizedStandardCompare($1) == .orderedAscending
    }

    var body: some View {
        Button {
            showing.toggle()
        } label: {
            HStack {
                Text(selectedName).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8))
            }.frame(maxWidth: .infinity)
        }
        .accessibilityLabel(label).accessibilityValue(selectedName)
        .popover(isPresented: $showing) {
            VStack(spacing: 8) {
                TextField("Search installed fonts", text: $search).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Search installed fonts")
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        fontRow("System font", value: nil)
                        ForEach(filteredFonts, id: \.self) { font in fontRow(font, value: font) }
                        if filteredFonts.isEmpty { Text("No matching fonts").foregroundStyle(.secondary).padding(8) }
                    }
                }
            }.padding(12).frame(width: 300, height: 320)
                .font(.stow(size: 12))
                .preferredColorScheme(ThemeController.shared.colorScheme)
        }
    }

    private func fontRow(_ title: String, value: String?) -> some View {
        Button {
            selection = value
            showing = false
            search = ""
        } label: {
            HStack {
                Text(title).lineLimit(1)
                Spacer()
                if selection == value { Image(systemName: "checkmark") }
            }.padding(.horizontal, 6).padding(.vertical, 5).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(title)
    }
}
