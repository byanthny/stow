import AppKit
import Observation
import StowCore
import SwiftUI
import UniformTypeIdentifiers

struct AppearanceView: View {
    @Bindable var store: AppStore
    @Environment(\.stowTheme) private var theme
    @State private var importError: String?
    @State private var showingConfig = false
    @State private var configDraft = ThemeConfigDraft()
    @State private var copiedConfig = false
    private var settings: AppearanceSettings { store.state.appearance }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Appearance").font(theme.font(size: 14, weight: .semibold))
                Spacer()
                PullDownMenu(
                    title: settings.name,
                    sections: [
                        [
                            .init(title: "Stow · dark") { preset(.default) },
                            .init(title: "Graphite · dark") { preset(.graphite) },
                            .init(title: "Paper · light") { preset(.paper) },
                        ]
                    ], label: "Theme preset", font: theme.nsFont()
                ).fixedSize()
            }
            Text("Make Stow feel at home. Changes apply to the board and every open note.")
                .font(theme.font(size: 11)).foregroundStyle(.stowMuted)
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
                        .monospacedDigit().foregroundStyle(.stowMuted)
                }
            }.font(theme.font(size: 12))
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("Background opacity")
                    Spacer()
                    Text(settings.backgroundOpacity, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit().foregroundStyle(.stowMuted)
                }
                Slider(value: binding(\.backgroundOpacity), in: 0.2...1, step: 0.01)
                    .accessibilityLabel("Background opacity")
                Text(
                    theme.reduceTransparency
                        ? "Reduce Transparency is on in macOS. Your opacity preference is saved and backgrounds stay solid."
                        : "Only backgrounds become transparent; text stays clear."
                )
                .font(theme.font(size: 10)).foregroundStyle(.stowMuted)
            }.font(theme.font(size: 12))
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
            }.font(theme.font(size: 12))
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Button("Copy config") { copyConfig() }.accessibilityIdentifier("appearance.copyConfig")
                    Button("Edit config…") {
                        configDraft.begin(settings)
                        showingConfig = true
                    }.accessibilityIdentifier("appearance.editConfig")
                    if copiedConfig {
                        Text("Copied").foregroundStyle(.stowMuted).accessibilityIdentifier("appearance.copied")
                    }
                }
                Text("Small key = value configs are easy to paste and share in messages.")
                    .font(theme.font(size: 10)).foregroundStyle(.stowMuted)
            }.font(theme.font(size: 11))
            HStack(spacing: 10) {
                Button("Import…") { importTheme() }.accessibilityIdentifier("appearance.import")
                Button("Export…") { exportTheme() }.accessibilityIdentifier("appearance.export")
                Spacer()
                Button("Reset") { store.applyAppearance(.default) }.help("Restore all default appearance settings")
            }.font(theme.font(size: 11))
            Text("Import and export .conf text files. Existing JSON themes can still be imported.")
                .font(theme.font(size: 10)).foregroundStyle(.stowMuted)
        }
        .sheet(isPresented: $showingConfig) {
            ThemeConfigEditor(draft: configDraft) {
                if configDraft.apply(to: store) {
                    showingConfig = false
                    copiedConfig = false
                }
            } cancel: {
                showingConfig = false
            }
        }
        .onChange(of: settings) { _, _ in copiedConfig = false }
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
                    Color(stowHex: settings.colors[keyPath: keyPath])
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
        panel.allowedContentTypes = [Self.configContentType, .plainText, .json]
        panel.allowsOtherFileTypes = true
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let imported = try ThemeConfigTransfer.decode(ThemeConfigTransfer.read(url))
            store.applyAppearance(imported)
        } catch {
            importError = "Your current appearance has been kept. \(error.localizedDescription)"
        }
    }

    private func exportTheme() {
        let panel = NSSavePanel()
        panel.title = "Export Stow theme"
        panel.allowedContentTypes = [Self.configContentType]
        panel.allowsOtherFileTypes = true
        panel.nameFieldStringValue = "stow-theme.conf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try settings.encodedConfig().write(to: url, atomically: true, encoding: .utf8) } catch {
            importError = "The theme could not be saved. \(error.localizedDescription)"
        }
    }

    private static var configContentType: UTType {
        UTType(filenameExtension: "conf", conformingTo: .plainText) ?? .plainText
    }

    private func copyConfig() {
        do {
            let source = try settings.encodedConfig()
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            guard pasteboard.setString(source, forType: .string) else {
                importError = "The config could not be copied. Try again."
                return
            }
            copiedConfig = true
        } catch {
            importError = "The config could not be copied. \(error.localizedDescription)"
        }
    }
}

/// One size-limited import path for pasted configs and local files, including legacy JSON.
enum ThemeConfigTransfer {
    static let maximumBytes = 1_048_576

    static func decode(_ data: Data) throws -> AppearanceSettings {
        guard data.count <= maximumBytes else {
            throw AppearanceError.invalidValue("config size (maximum 1 MB)")
        }
        guard let source = String(data: data, encoding: .utf8) else {
            throw AppearanceError.invalidValue("text encoding; use UTF-8")
        }
        if source.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") {
            return try AppearanceSettings.decodeTheme(data)
        }
        return try AppearanceSettings.decodeConfig(source)
    }

    static func read(_ url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        // Read at most one byte beyond the limit, even if a file grows after the panel opens.
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else {
            throw AppearanceError.invalidValue("file size (maximum 1 MB)")
        }
        return data
    }
}

@MainActor @Observable
final class ThemeConfigDraft {
    var source = ""
    private(set) var error: String?

    func begin(_ settings: AppearanceSettings) {
        do {
            source = try settings.encodedConfig()
            error = nil
        } catch {
            source = ""
            self.error = error.localizedDescription
        }
    }

    @discardableResult
    func apply(to store: AppStore) -> Bool {
        do {
            let settings = try ThemeConfigTransfer.decode(Data(source.utf8))
            guard store.applyAppearance(settings) else {
                throw AppearanceError.invalidValue("appearance settings")
            }
            error = nil
            return true
        } catch {
            self.error = "Your current appearance has been kept. \(error.localizedDescription)"
            return false
        }
    }
}

private struct ThemeConfigEditor: View {
    @Bindable var draft: ThemeConfigDraft
    @Environment(\.stowTheme) private var theme
    var apply: () -> Void
    var cancel: () -> Void
    @FocusState private var sourceFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Theme config").font(theme.font(size: 16, weight: .semibold))
            Text("Paste a config from a message, edit the values, then apply. Cancel keeps your current appearance.")
                .font(theme.font(size: 11)).foregroundStyle(.stowMuted)
            TextEditor(text: $draft.source)
                .font(.system(size: 12, design: .monospaced))
                .disableAutocorrection(true)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(.stowSurface, in: RoundedRectangle(cornerRadius: 8))
                .focused($sourceFocused)
                .accessibilityLabel("Theme config source")
                .accessibilityIdentifier("appearance.config.source")
            if let error = draft.error {
                Text(error).font(theme.font(size: 11)).foregroundStyle(.stowRed)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("appearance.config.error")
            }
            HStack {
                Text("UTF-8 text · maximum 1 MB").font(theme.font(size: 10)).foregroundStyle(.stowMuted)
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Apply", action: apply).keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("appearance.config.apply")
            }
        }
        .padding(20)
        .frame(
            minWidth: 520, idealWidth: 640, maxWidth: .infinity,
            minHeight: 420, idealHeight: 560, maxHeight: .infinity
        )
        .background(.stowBackground)
        .background(ResizableThemeSheet())
        .foregroundStyle(.stowText)
        .preferredColorScheme(theme.colorScheme)
        .onAppear { sourceFocused = true }
    }
}

private struct ResizableThemeSheet: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { SizingView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class SizingView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.styleMask.insert(.resizable)
            window?.contentMinSize = NSSize(width: 520, height: 420)
        }
    }
}

private struct AppearanceFontPicker: View {
    @Binding var selection: String?
    @Environment(\.stowTheme) private var theme
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
                .font(theme.font(size: 12))
                .preferredColorScheme(theme.colorScheme)
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
