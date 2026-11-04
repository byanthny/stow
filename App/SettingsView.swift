import AppKit
import StowCore
import StowGitHub
import SwiftUI

struct SettingsView: View {
    @Bindable var store: AppStore
    @Environment(\.stowTheme) private var theme
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                AppearanceView(store: store)
                Divider()
                BoardSettingsView(store: store)
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Text("GitHub").font(theme.font(size: 14, weight: .semibold))
                    Toggle(
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
                    Toggle(
                        "Sample board accessory",
                        isOn: Binding(get: { store.sampleEnabled() }, set: { _ in store.toggleSample() }))
                    Text("A small bundled example. Note accessories can be enabled from each note’s actions menu.")
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
        guard GHClient.isUsableExecutable(atPath: url.path) else {
            let alert = NSAlert()
            alert.messageText = "Stow can't use that file"
            alert.informativeText =
                "Choose the gh executable from a GitHub CLI installation, such as /opt/homebrew/bin/gh. It must be named gh and must not be writable by other users."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }
        store.setExecutablePath(url.path)
    }
}

/// Board layout preferences. Each has a default; nothing here is required.
private struct BoardSettingsView: View {
    @Bindable var store: AppStore
    @Environment(\.stowTheme) private var theme
    private var layout: BoardLayout { store.state.boardLayout }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Board").font(theme.font(size: 14, weight: .semibold))
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
            Picker(
                "Pull requests before Show more",
                selection: Binding(get: { layout.visiblePullRequests }, set: { store.setVisiblePullRequests($0) })
            ) {
                ForEach([3, 5, 10], id: \.self) { count in Text(verbatim: "\(count)").tag(count) }
                Text("All").tag(0)
                if ![0, 3, 5, 10].contains(layout.visiblePullRequests) {
                    Text(verbatim: "\(layout.visiblePullRequests)").tag(layout.visiblePullRequests)
                }
            }.font(theme.font(size: 12))
            Toggle(
                "Let Notes collapse",
                isOn: Binding(get: { layout.notesCanCollapse }, set: { store.setNotesCanCollapse($0) }))
            HStack {
                Text("Defaults: Needs you, Notes, Waiting; 3 pull requests per section; Notes always open.")
                    .font(theme.font(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Reset") { store.resetBoardLayout() }.disabled(layout == BoardLayout())
            }
        }
    }
}
