import AppKit
import StowGitHub
import SwiftUI

struct SettingsView: View {
    @Bindable var store: AppStore
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                AppearanceView(store: store)
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Text("GitHub").font(.stow(size: 14, weight: .semibold))
                    Toggle(
                        "Show pull requests",
                        isOn: Binding(get: { store.state.githubEnabled }, set: { store.setGitHubEnabled($0) }))
                    Text("Uses your existing gh login. Notes work independently.").font(.stow(size: 11))
                        .foregroundStyle(
                            .secondary)
                    HStack {
                        Text(store.state.ghExecutablePath ?? "Find gh automatically").font(.stow(size: 11)).lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("Choose gh…") { chooseGH() }
                        if store.state.ghExecutablePath != nil { Button("Reset") { store.setExecutablePath(nil) } }
                    }
                    if let viewer = store.state.viewerLogin {
                        Text("Last connected as \(viewer)").font(.stow(size: 11)).foregroundStyle(.secondary)
                    }
                }
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Text("Accessories").font(.stow(size: 14, weight: .semibold))
                    Toggle(
                        "Sample board accessory",
                        isOn: Binding(get: { store.sampleEnabled() }, set: { _ in store.toggleSample() }))
                    Text("A small bundled example. Note accessories can be enabled from each note’s actions menu.")
                        .font(.stow(size: 11)).foregroundStyle(.secondary)
                    ForEach(store.state.extensionInstances.filter { $0.moduleID != store.sampleID }) { instance in
                        HStack {
                            Text(instance.moduleID).font(.stow(size: 11))
                            Spacer()
                            Text("Not installed; settings preserved").font(.stow(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                }
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Text("Dismissed pull requests").font(.stow(size: 14, weight: .semibold))
                    if store.state.dismissedIDs.isEmpty {
                        Text("Nothing dismissed.").font(.stow(size: 11)).foregroundStyle(.secondary)
                    }
                    ForEach(store.state.dismissedIDs, id: \.self) { id in
                        HStack {
                            Text(store.state.pullRequests.first(where: { $0.id == id })?.title ?? id).font(
                                .stow(size: 11)
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
                    Text("Local data").font(.stow(size: 14, weight: .semibold))
                    Text("Notes, cached pull requests, and settings are stored on this Mac. No analytics or sync.")
                        .font(.stow(size: 11)).foregroundStyle(.secondary)
                    Button("Show data folder") {
                        NSWorkspace.shared.selectFile(
                            store.stateURL.path,
                            inFileViewerRootedAtPath: store.stateURL.deletingLastPathComponent().path)
                    }
                }
            }.padding(22)
        }.frame(width: 520, height: 690)
            .background(Color.stowBackground)
            .foregroundStyle(Color.stowText)
            .font(.stow())
            .preferredColorScheme(ThemeController.shared.colorScheme)
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
