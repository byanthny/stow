import AppKit
import StowCore
import SwiftUI

/// Settings → Profiles: each profile's color, icon, name, and place in the list, with Delete…; New profile…; Reset
/// profile list while the index needs it; and the settings for showing and switching profiles. Changes go through
/// the profile manager, which saves them and reloads the list for every window.
struct ProfilesSettingsView: View {
    @Bindable var store: AppStore
    /// The profile whose Settings this is.
    let profile: ProfileHandle
    @Environment(\.stowTheme) private var theme
    @State private var problem: String?
    @State private var status: String?

    var body: some View {
        let manager = profile.manager
        let profiles = manager?.profiles ?? []
        let needsReset = manager?.indexNeedsReset == true
        VStack(alignment: .leading, spacing: 10) {
            Text("Profiles").font(theme.font(size: 14, weight: .semibold))
            ForEach(Array(profiles.enumerated()), id: \.element.id) { position, entry in
                ProfileRow(
                    entry: entry, position: position, count: profiles.count,
                    profile: ProfileHandle(id: entry.id, manager: manager), settingsID: profile.id
                ) { problem = $0 }
            }
            HStack {
                Button("New profile…") { profile.manager?.requestNewProfile(from: profile.id) }
                    .accessibilityIdentifier("profiles.new")
                if needsReset {
                    Button("Reset profile list") { resetProfileList() }.accessibilityIdentifier("profiles.reset")
                }
            }
            if needsReset {
                Text(
                    "Stow can’t read the profile list, so profile order and open windows aren’t saved and profiles can’t change. Reset it to start a new list; the old one is kept as a backup."
                )
                .font(theme.font(size: 11)).foregroundStyle(.stowAmber).fixedSize(horizontal: false, vertical: true)
            }
            SettingsToggle(
                "Always show profile name", identifier: "profiles.alwaysShowName",
                isOn: Binding(
                    get: { profile.manager?.alwaysShowsProfileName ?? false },
                    set: { shows in setAlwaysShowProfileName(shows) }))
            if profiles.count > 1 {
                SettingsToggle(
                    "Hide when switching away", identifier: "profiles.hidesWhenSwitchingAway",
                    isOn: Binding(
                        get: { store.state.hidesWhenSwitchingAway }, set: { store.setHidesWhenSwitchingAway($0) }))
            }
            Text(
                profiles.count > 1
                    ? "Always show profile name applies to every profile. Hide when switching away applies to this one."
                    : "Names and colors show once you have a second profile, or always with this setting."
            )
            .font(theme.font(size: 11)).foregroundStyle(.stowMuted).fixedSize(horizontal: false, vertical: true)
            if let problem {
                Text(problem).font(theme.font(size: 11)).foregroundStyle(.stowRed)
                    .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("profiles.problem")
            }
            if let status {
                Text(status).font(theme.font(size: 11)).foregroundStyle(.stowMuted)
                    .accessibilityIdentifier("profiles.status")
            }
        }
        .sheet(isPresented: showsNewProfile) {
            NewProfileSheet(profile: profile).environment(\.stowTheme, theme)
        }
    }

    /// The New profile sheet shows while the manager asks for it in this profile's Settings.
    private var showsNewProfile: Binding<Bool> {
        Binding(
            get: { profile.manager?.newProfileRequest == profile.id },
            set: { shown in
                guard !shown, let manager = profile.manager, manager.newProfileRequest == profile.id else { return }
                manager.newProfileRequest = nil
            })
    }

    private func setAlwaysShowProfileName(_ shows: Bool) {
        guard let manager = profile.manager else { return }
        Task {
            do {
                try await manager.setAlwaysShowProfileName(shows)
                problem = nil
            } catch {
                problem = profileProblem(error, name: "")
            }
        }
    }

    private func resetProfileList() {
        guard let manager = profile.manager else { return }
        Task {
            do {
                let backup = try await manager.resetIndex()
                problem = nil
                status = "The old profile list was kept as \(backup.lastPathComponent)."
            } catch {
                problem = profileProblem(error, name: "")
            }
        }
    }
}

/// One profile in Settings → Profiles: its color, icon, and name, then its place in the list and Delete…. With one
/// profile only the color, icon, and name show, since the rest would have nothing to do.
private struct ProfileRow: View {
    let entry: ProfileEntry
    let position: Int
    let count: Int
    /// This row's profile.
    let profile: ProfileHandle
    /// The profile whose Settings window shows this row.
    let settingsID: UUID
    /// Shows why a change failed, or clears the message when one succeeds.
    let report: (String?) -> Void
    @Environment(\.stowTheme) private var theme
    @State private var name = ""
    /// A color picked but not yet written, so the well follows the pick at once.
    @State private var pendingColor: String?
    @State private var colorWrite: Task<Void, Never>?
    @State private var isPickingIcon = false
    @FocusState private var isEditingName: Bool

    var body: some View {
        HStack(spacing: 6) {
            ColorPicker(selection: color, supportsOpacity: false) { Text(verbatim: "Color for \(entry.name)") }
                .labelsHidden().fixedSize().accessibilityIdentifier(identifier("color"))
            Button {
                isPickingIcon = true
            } label: {
                ProfileIconView(icon: entry.icon, placeholder: "circle.dashed")
                    .frame(width: 22, height: 22).contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(.stowMuted).help("Choose an icon")
            .accessibilityLabel("Icon for \(entry.name)")
            .accessibilityValue(entry.icon?.displayable.map(\.spokenName) ?? "None")
            .accessibilityIdentifier(identifier("icon"))
            .popover(isPresented: $isPickingIcon, arrowEdge: .bottom) {
                ProfileIconPicker(entry: entry) { icon in
                    isPickingIcon = false
                    run { try await $0.setIcon(entry.id, to: icon) }
                }
                .environment(\.stowTheme, theme)
            }
            TextField("Name of \(entry.name)", text: $name, prompt: Text("Name"))
                .labelsHidden().focused($isEditingName).onSubmit(rename)
                .accessibilityIdentifier(identifier("name"))
            if count > 1 {
                Button {
                    run { try await $0.move(entry.id, by: -1) }
                } label: {
                    Image(systemName: "chevron.up")
                }
                .disabled(position == 0).accessibilityLabel("Move \(entry.name) up")
                .accessibilityIdentifier(identifier("moveUp"))
                Button {
                    run { try await $0.move(entry.id, by: 1) }
                } label: {
                    Image(systemName: "chevron.down")
                }
                .disabled(position == count - 1).accessibilityLabel("Move \(entry.name) down")
                .accessibilityIdentifier(identifier("moveDown"))
                Button("Delete…", action: confirmDelete)
                    .accessibilityLabel("Delete \(entry.name)").accessibilityIdentifier(identifier("delete"))
            }
        }
        .font(theme.font(size: 12))
        .onAppear { name = entry.name }
        .onChange(of: entry.name) { _, current in
            if !isEditingName { name = current }
        }
        .onChange(of: isEditingName) { _, editing in
            if !editing { rename() }
        }
    }

    /// An identifier for one of this row's controls, ending in the profile's ID so UI automation can tell rows apart.
    private func identifier(_ control: String) -> String { "profiles.\(control).\(entry.id.uuidString)" }

    /// The well's color. The color panel reports every step of a drag, so the write waits until the pick settles.
    private var color: Binding<Color> {
        Binding(
            get: { Color(stowHex: pendingColor ?? entry.color) },
            set: { picked in
                let hex = picked.stowHex
                guard hex.caseInsensitiveCompare(pendingColor ?? entry.color) != .orderedSame else { return }
                pendingColor = hex
                colorWrite?.cancel()
                let id = entry.id
                let current = entry.name
                colorWrite = Task {
                    try? await Task.sleep(for: .milliseconds(300))
                    guard !Task.isCancelled, let manager = profile.manager else { return }
                    do {
                        try await manager.setColor(id, to: hex)
                        report(nil)
                    } catch {
                        report(profileProblem(error, name: current))
                    }
                    // A pick made while this wrote stays in the well until its own write.
                    if pendingColor == hex { pendingColor = nil }
                }
            })
    }

    /// Saves a changed name. One the manager refuses, such as an empty or duplicate name, goes back to the saved one.
    private func rename() {
        let draft = name
        guard ProfileIdentity.sanitizedName(draft) != entry.name else {
            name = entry.name
            return
        }
        let id = entry.id
        run({ try await $0.rename(id, to: draft) }, failed: { name = profile.entry?.name ?? entry.name })
    }

    private func confirmDelete() {
        let alert = NSAlert()
        alert.messageText = "Delete \(entry.name)?"
        alert.informativeText =
            "Stow closes the profile and moves its folder, with its notes and settings, to the Trash. You can put it back from the Trash until you empty it."
        alert.addButton(withTitle: "Move to Trash").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        // When this window closes with the profile, the manager says why a deletion failed instead.
        let settingsID = settingsID
        run { try await $0.delete(entry.id, askedFrom: settingsID) }
    }

    /// Runs a change through the profile manager and reports why it failed, if it did.
    private func run(
        _ change: @escaping @MainActor (ProfileManager) async throws -> Void, failed: (@MainActor () -> Void)? = nil
    ) {
        guard let manager = profile.manager else { return }
        let current = entry.name
        Task {
            do {
                try await change(manager)
                report(nil)
            } catch {
                report(profileProblem(error, name: current))
                failed?()
            }
        }
    }
}

/// Chooses a profile's icon: none, a common SF Symbol, any SF Symbol by name, or one emoji.
private struct ProfileIconPicker: View {
    let entry: ProfileEntry
    let choose: (ProfileIcon?) -> Void
    @Environment(\.stowTheme) private var theme
    @State private var symbolName = ""
    @State private var emoji = ""
    @State private var problem: String?

    /// A common symbol and the name VoiceOver reads for it.
    private struct Symbol: Identifiable {
        let id: String
        let label: String
    }

    /// Common symbols for kinds of work and life.
    private static let symbols = [
        Symbol(id: "briefcase", label: "Briefcase"), Symbol(id: "house", label: "House"),
        Symbol(id: "person", label: "Person"), Symbol(id: "star", label: "Star"), Symbol(id: "heart", label: "Heart"),
        Symbol(id: "bolt", label: "Bolt"), Symbol(id: "leaf", label: "Leaf"), Symbol(id: "book", label: "Book"),
        Symbol(id: "hammer", label: "Hammer"), Symbol(id: "paintbrush", label: "Paintbrush"),
        Symbol(id: "graduationcap", label: "Graduation cap"), Symbol(id: "globe", label: "Globe"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Icon for \(entry.name)").font(theme.font(size: 12, weight: .semibold))
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(28), spacing: 4), count: 6), spacing: 4) {
                ForEach(Self.symbols) { symbol in
                    let isChosen = entry.icon == .symbol(symbol.id)
                    Button {
                        choose(.symbol(symbol.id))
                    } label: {
                        Image(systemName: symbol.id).font(theme.font(size: 14)).frame(width: 28, height: 28)
                            .background(
                                isChosen ? AnyShapeStyle(.stowSurface) : AnyShapeStyle(Color.clear),
                                in: RoundedRectangle(cornerRadius: 6)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).help(symbol.label)
                    .accessibilityLabel(symbol.label).accessibilityAddTraits(isChosen ? .isSelected : [])
                    .accessibilityIdentifier("profiles.iconPicker.symbol.\(symbol.id)")
                }
            }
            Button("None") { choose(nil) }.accessibilityIdentifier("profiles.iconPicker.none")
            HStack {
                TextField("Symbol name", text: $symbolName).onSubmit(useSymbol)
                    .accessibilityIdentifier("profiles.iconPicker.symbolName")
                Button("Use", action: useSymbol).accessibilityLabel("Use symbol")
                    .accessibilityIdentifier("profiles.iconPicker.useSymbol")
                    .disabled(symbolName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            HStack {
                TextField("Emoji", text: $emoji).onSubmit(useEmoji)
                    .accessibilityIdentifier("profiles.iconPicker.emoji")
                Button("Use", action: useEmoji).accessibilityLabel("Use emoji")
                    .accessibilityIdentifier("profiles.iconPicker.useEmoji")
                    .disabled(emoji.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let problem {
                Text(problem).font(theme.font(size: 11)).foregroundStyle(.stowRed)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(theme.font(size: 12)).foregroundStyle(.stowText).padding(14).frame(width: 236)
    }

    /// Any SF Symbol by name, if this Mac has it.
    private func useSymbol() {
        let name = symbolName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let icon = ProfileIcon.validated(.symbol(name)), icon.displayable != nil else {
            problem = "There’s no SF Symbol named “\(name)”."
            return
        }
        choose(icon)
    }

    private func useEmoji() {
        let text = emoji.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let icon = ProfileIcon.validated(.emoji(text)) else {
            problem = "Enter a single emoji."
            return
        }
        choose(icon)
    }
}

/// New profile…: a name and a color. The profile is created empty, with GitHub off, and opens.
struct NewProfileSheet: View {
    let profile: ProfileHandle
    @Environment(\.stowTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var color: String
    @State private var problem: String?
    @State private var isCreating = false
    @FocusState private var isNameFocused: Bool

    init(profile: ProfileHandle) {
        self.profile = profile
        _color = State(initialValue: ProfilePalette.firstUnused(among: profile.manager?.profiles.map(\.color) ?? []))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New profile").font(theme.font(size: 14, weight: .semibold))
            TextField("Name", text: $name).focused($isNameFocused).onSubmit(create)
                .accessibilityIdentifier("newProfile.name")
            HStack {
                Text("Color")
                Spacer()
                ColorPicker(
                    "Color", selection: Binding(get: { Color(stowHex: color) }, set: { color = $0.stowHex }),
                    supportsOpacity: false
                )
                .labelsHidden().accessibilityIdentifier("newProfile.color")
            }
            Text("A new profile starts empty, with GitHub off until you turn it on.")
                .font(theme.font(size: 11)).foregroundStyle(.stowMuted).fixedSize(horizontal: false, vertical: true)
            if let problem {
                Text(problem).font(theme.font(size: 11)).foregroundStyle(.stowRed)
                    .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("newProfile.problem")
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("newProfile.cancel")
                Button("Create", action: create).keyboardShortcut(.defaultAction).disabled(isCreating)
                    .accessibilityIdentifier("newProfile.create")
            }
        }
        .padding(20).frame(width: 340)
        .font(theme.font()).foregroundStyle(.stowText).background(.stowBackground)
        .preferredColorScheme(theme.colorScheme)
        .onAppear { isNameFocused = true }
    }

    private func create() {
        guard !isCreating, let manager = profile.manager else { return }
        isCreating = true
        let name = name
        let color = color
        Task {
            defer { isCreating = false }
            do {
                let entry = try await manager.createProfile(name: name, color: color)
                dismiss()
                await manager.open(entry.id)
            } catch {
                problem = profileProblem(error, name: name)
            }
        }
    }
}

/// A profile's icon: an SF Symbol this Mac has, or an emoji. Without one it shows `placeholder`, if given.
struct ProfileIconView: View {
    let icon: ProfileIcon?
    var placeholder: String?

    var body: some View {
        switch icon?.displayable {
        case .symbol(let name)?: Image(systemName: name)
        case .emoji(let text)?: Text(verbatim: text)
        case nil: if let placeholder { Image(systemName: placeholder) }
        }
    }
}

/// The colors new profiles start with, so each starts distinct. Any color can be chosen afterwards.
enum ProfilePalette {
    static let colors = ["#0A84FF", "#30D158", "#FF9F0A", "#BF5AF2", "#FF375F", "#64D2FF", "#FFD60A", "#AC8E68"]

    /// The first color that no profile uses, ignoring case: the palette in order, then further hues spread around
    /// the color wheel, so a new profile's default always differs from the colors in use.
    static func firstUnused(among used: [String]) -> String {
        let taken = Set(used.map { $0.uppercased() })
        if let color = colors.first(where: { !taken.contains($0) }) { return color }
        // Hues 137 degrees apart reach every whole degree in 360 steps; each later round is paler or darker.
        for step in 0..<(360 * 9) {
            let round = step / 360
            let color = hex(
                hue: Double(step * 137 % 360) / 360, saturation: 0.7 - 0.15 * Double(round % 3),
                brightness: 0.9 - 0.15 * Double(round / 3))
            if !taken.contains(color) { return color }
        }
        // Only with thousands of profiles: the first color of all that no profile uses.
        return (0..<0x100_0000).lazy.map { String(format: "#%06X", $0) }.first { !taken.contains($0) } ?? colors[0]
    }

    /// `#RRGGBB` for a hue, saturation, and brightness, each from 0 to 1.
    private static func hex(hue: Double, saturation: Double, brightness: Double) -> String {
        let sector = hue * 6
        let fraction = sector - sector.rounded(.down)
        let low = brightness * (1 - saturation)
        let falling = brightness * (1 - saturation * fraction)
        let rising = brightness * (1 - saturation * (1 - fraction))
        let (red, green, blue) =
            switch Int(sector) % 6 {
            case 0: (brightness, rising, low)
            case 1: (falling, brightness, low)
            case 2: (low, brightness, rising)
            case 3: (low, falling, brightness)
            case 4: (rising, low, brightness)
            default: (brightness, low, falling)
            }
        let bytes = [red, green, blue].map { Int(($0 * 255).rounded()) }
        return String(format: "#%02X%02X%02X", bytes[0], bytes[1], bytes[2])
    }
}

extension ProfileIcon {
    /// The icon when this Mac can show it: nil for a symbol that macOS does not have, such as one from a newer
    /// release on a profile copied from another Mac.
    var displayable: ProfileIcon? {
        if case .symbol(let name) = self, NSImage(systemSymbolName: name, accessibilityDescription: nil) == nil {
            return nil
        }
        return self
    }

    /// What VoiceOver reads for the icon in Settings.
    var spokenName: String {
        switch self {
        case .symbol(let name): name
        case .emoji(let text): text
        }
    }
}

extension Color {
    /// The color as `#RRGGBB` in sRGB, the form profile identities keep.
    var stowHex: String {
        let color = NSColor(self).usingColorSpace(.sRGB) ?? NSColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        let bytes = [color.redComponent, color.greenComponent, color.blueComponent].map {
            Int((min(max($0, 0), 1) * 255).rounded())
        }
        return String(format: "#%02X%02X%02X", bytes[0], bytes[1], bytes[2])
    }
}

/// Why a change to profiles failed, as Settings and the deletion alert say it. Nil when there is nothing to say, as
/// when the person kept a profile open after its changes could not be saved.
func profileProblem(_ error: any Error, name: String) -> String? {
    if error is CancellationError { return nil }
    switch error as? ProfileError {
    case .emptyName?: return "Enter a name for the profile."
    case .duplicateName?: return "Another profile already uses that name."
    case .invalidColor?: return "Choose another color."
    case .invalidIcon?: return "Choose an SF Symbol or a single emoji."
    case .inUse?: return "\(name) is open in another copy of Stow. Quit it, then try again."
    case .lastProfile?: return "The last profile can’t be deleted."
    case .notFound?: return "\(name) is no longer in the profile list."
    case .indexNeedsReset?: return "Reset the profile list first."
    case .invalidIdentity?: return "\(name)’s identity file can’t be read, so Stow left it unchanged."
    case .newerIdentity?:
        return "A newer version of Stow saved \(name), so this version leaves its name, color, and icon unchanged."
    case .unwritable?:
        return "Stow couldn’t save the change. Check that the data folder can be written to and has space."
    case .invalidIndex?, .newerIndex?, nil: return "Stow couldn’t read the profile list."
    }
}
