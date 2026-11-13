import AppKit
import StowCore
import StowGitHub
import SwiftUI

struct SettingsView: View {
    @Bindable var store: AppStore
    /// The profile these settings belong to, for Settings → Profiles.
    let profile: ProfileHandle
    @Environment(\.stowTheme) private var theme
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                ProfilesSettingsView(store: store, profile: profile)
                Divider()
                AppearanceView(store: store)
                Divider()
                BoardSettingsView(store: store, profile: profile)
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Text("GitHub").font(theme.font(size: 14, weight: .semibold))
                    SettingsToggle(
                        "Show pull requests",
                        isOn: Binding(get: { store.state.githubEnabled }, set: { store.setGitHubEnabled($0) }))
                    Text("Uses your existing gh login. Notes work independently.").font(theme.font(size: 11))
                        .foregroundStyle(
                            .secondary)
                    HStack {
                        Text(store.state.ghExecutablePath ?? "Find gh automatically").font(theme.font(size: 11)).lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("Choose gh…") { chooseGH() }
                        if store.state.ghExecutablePath != nil { Button("Reset") { store.setExecutablePath(nil) } }
                    }
                    if let viewer = store.state.viewerLogin {
                        Text("Last connected as \(viewer)").font(theme.font(size: 11)).foregroundStyle(.secondary)
                    }
                }
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Text("Accessories").font(theme.font(size: 14, weight: .semibold))
                    SettingsToggle(
                        "Sample board accessory",
                        isOn: Binding(get: { store.sampleEnabled() }, set: { _ in store.toggleSample() }))
                    Text("A small bundled example. Once it’s on, each note’s ⋯ menu can add it to that note.")
                        .font(theme.font(size: 11)).foregroundStyle(.secondary)
                    ForEach(store.state.extensionInstances.filter { $0.moduleID != store.sampleID }) { instance in
                        HStack {
                            Text(instance.moduleID).font(theme.font(size: 11))
                            Spacer()
                            Text("Not installed; settings preserved").font(theme.font(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                }
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Text("Dismissed pull requests").font(theme.font(size: 14, weight: .semibold))
                    if store.state.dismissedIDs.isEmpty {
                        Text("Nothing dismissed.").font(theme.font(size: 11)).foregroundStyle(.secondary)
                    }
                    ForEach(store.state.dismissedIDs, id: \.self) { id in
                        HStack {
                            Text(store.state.pullRequests.first(where: { $0.id == id })?.title ?? id).font(
                                theme.font(size: 11)
                            )
                            .lineLimit(2)
                            Spacer()
                            Button("Restore") { store.restoreDismissal(id) }
                        }
                    }
                }
                Divider()
                DataTransferView(store: store)
                Divider()
                UpdateSettingsView(profile: profile)
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text("Local data").font(theme.font(size: 14, weight: .semibold))
                    Text("Notes, cached pull requests, and settings are stored on this Mac. No analytics or sync.")
                        .font(theme.font(size: 11)).foregroundStyle(.secondary)
                    Button("Show data folder") {
                        NSWorkspace.shared.selectFile(
                            store.stateURL.path,
                            inFileViewerRootedAtPath: store.stateURL.deletingLastPathComponent().path)
                    }
                }
            }.padding(22)
        }.frame(width: 520, height: 690)
            .background(.stowBackground)
            .foregroundStyle(.stowText)
            .font(theme.font())
            .preferredColorScheme(theme.colorScheme)
            .disabled(store.isRestoringBackup)
    }

    private func chooseGH() {
        let panel = NSOpenPanel()
        panel.title = "Choose the GitHub CLI executable"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard GHClient.isUsableExecutable(atPath: url.path, excluding: store.dataFolder) else {
            let alert = NSAlert()
            alert.messageText = "Stow can't use that file"
            alert.informativeText =
                "Choose the gh executable from a GitHub CLI installation, such as /opt/homebrew/bin/gh. It must be named gh, not setuid or setgid, not writable by its group or other users, and outside Stow's data folder."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }
        store.setExecutablePath(url.path)
    }
}

/// Board layout preferences, then how the profile keeps cards and notes. Each has a default; nothing here is
/// required.
private struct BoardSettingsView: View {
    @Bindable var store: AppStore
    let profile: ProfileHandle
    @Environment(\.stowTheme) private var theme
    private var layout: BoardLayout { store.state.boardLayout }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Board").font(theme.font(size: 14, weight: .semibold))
            SettingsToggle(
                "Show board title",
                isOn: Binding(get: { layout.showsTitle }, set: { store.setShowsBoardTitle($0) }))
            Text("Section order").font(theme.font(size: 11)).foregroundStyle(.secondary)
            ForEach(Array(layout.order.enumerated()), id: \.element) { index, section in
                HStack(spacing: 6) {
                    Text(section.title).font(theme.font(size: 12))
                    Spacer()
                    Button {
                        store.moveBoardSection(section, by: -1)
                    } label: {
                        Image(systemName: "chevron.up")
                    }.disabled(index == 0).accessibilityLabel("Move \(section.title) up")
                    Button {
                        store.moveBoardSection(section, by: 1)
                    } label: {
                        Image(systemName: "chevron.down")
                    }.disabled(index == layout.order.count - 1).accessibilityLabel("Move \(section.title) down")
                }
            }
            HStack {
                Text("Pull requests before Show more")
                Spacer()
                Picker(
                    "Pull requests before Show more",
                    selection: Binding(get: { layout.visiblePullRequests }, set: { store.setVisiblePullRequests($0) })
                ) {
                    ForEach([3, 5, 10], id: \.self) { count in Text(verbatim: "\(count)").tag(count) }
                    Text("All").tag(0)
                    if ![0, 3, 5, 10].contains(layout.visiblePullRequests) {
                        Text(verbatim: "\(layout.visiblePullRequests)").tag(layout.visiblePullRequests)
                    }
                }.pickerStyle(.segmented).labelsHidden().fixedSize()
            }.font(theme.font(size: 12))
            SettingsToggle(
                "Notes start collapsed",
                isOn: Binding(get: { layout.notesStartCollapsed }, set: { store.setNotesStartCollapsed($0) }))
            Text("Owners").font(theme.font(size: 11)).foregroundStyle(.secondary)
            SettingsToggle(
                "Group by owner", identifier: "board.groupByOwner",
                isOn: Binding(get: { layout.groupByOwner }, set: { store.setGroupByOwner($0) }))
            HStack {
                Text("Owner order")
                Spacer()
                Picker(
                    "Owner order", selection: Binding(get: { layout.ownerOrder }, set: { store.setOwnerOrder($0) })
                ) {
                    Text("A to Z").tag(BoardLayout.OwnerOrder.alphabetical)
                    Text("Most cards first").tag(BoardLayout.OwnerOrder.mostCards)
                }.pickerStyle(.segmented).labelsHidden().fixedSize().accessibilityIdentifier("board.ownerOrder")
            }.font(theme.font(size: 12))
            SettingsToggle(
                "Always show owner control", identifier: "board.alwaysShowOwnerControl",
                isOn: Binding(get: { layout.alwaysShowOwnerControl }, set: { store.setAlwaysShowOwnerControl($0) }))
            SettingsToggle(
                "Hide notes linked to hidden owners", identifier: "board.hidesNotesForHiddenOwners",
                isOn: Binding(
                    get: { layout.hidesNotesForHiddenOwners }, set: { store.setHidesNotesForHiddenOwners($0) }))
            HStack {
                Text(
                    "Defaults: title shown; Needs you, Notes, Waiting; 3 pull requests per section; notes start collapsed; owners A to Z and not grouped; the owner control shows only when needed; owner filters never hide notes."
                )
                .font(theme.font(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Reset") { store.resetBoardLayout() }.disabled(layout == BoardLayout())
            }
            SettingsToggle(
                "Keep only selected owners on disk", identifier: "board.keepsOnlySelectedOwners",
                isOn: Binding(
                    get: { store.state.keepsOnlySelectedOwners }, set: { store.setKeepsOnlySelectedOwners($0) }))
            Text("Leaves other owners’ pull requests out of this profile’s files and backups. Pins are kept.")
                .font(theme.font(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            // Only a profile among several can hide.
            if (profile.manager?.profiles.count ?? 1) > 1 {
                SettingsToggle(
                    "Keep always-on-top notes visible when hiding", identifier: "board.hideKeepsAlwaysOnTopNotes",
                    isOn: Binding(
                        get: { store.state.hideKeepsAlwaysOnTopNotes }, set: { store.setHideKeepsAlwaysOnTopNotes($0) }
                    ))
            }
        }
    }
}

/// Settings → Updates, which applies to every profile. Off until the person turns it on.
private struct UpdateSettingsView: View {
    let profile: ProfileHandle
    @Environment(\.stowTheme) private var theme

    var body: some View {
        let explanation =
            "Asks GitHub once a day whether a newer Stow is out, and again within the hour after a check fails. Nothing is downloaded."
        VStack(alignment: .leading, spacing: 10) {
            Text("Updates").font(theme.font(size: 14, weight: .semibold))
            SettingsToggle(
                "Check for updates", identifier: "updates.checksForUpdates",
                isOn: Binding(
                    get: { profile.manager?.updates.settings.checksForUpdates ?? false },
                    set: { checks in setChecksForUpdates(checks) }))
            Text((profile.manager?.profiles.count ?? 1) > 1 ? explanation + " Applies to every profile." : explanation)
                .font(theme.font(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let problem = profile.manager?.updates.problem {
                Text(problem).font(theme.font(size: 11)).foregroundStyle(.stowRed)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func setChecksForUpdates(_ checks: Bool) {
        guard let updates = profile.manager?.updates else { return }
        Task { try? await updates.setChecksForUpdates(checks) }
    }
}

/// A setting's label on the left with its checkbox on the right, in line with the other Settings controls.
struct SettingsToggle: View {
    let title: String
    /// The checkbox's identifier for UI automation, when it has one.
    let identifier: String?
    @Binding var isOn: Bool

    init(_ title: String, identifier: String? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.identifier = identifier
        self._isOn = isOn
    }

    var body: some View {
        HStack {
            // The checkbox carries the label for VoiceOver; the visible text is a click target only.
            Text(title).accessibilityHidden(true)
            Spacer()
            let checkbox = Toggle(title, isOn: $isOn).labelsHidden().toggleStyle(.checkbox)
            if let identifier { checkbox.accessibilityIdentifier(identifier) } else { checkbox }
        }
        .contentShape(Rectangle())
        .onTapGesture { isOn.toggle() }
    }
}
