import StowCore
import SwiftUI

struct BoardView: View {
    @Bindable var store: AppStore
    var showSettings: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "tray").font(.stow(size: 16, weight: .medium)).foregroundStyle(Color.stowMuted)
                Text("Stow").font(.stow(size: 14, weight: .semibold))
                Spacer()
                if store.isRefreshing {
                    ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 20)
                } else {
                    QuietIconButton(symbol: "arrow.clockwise", label: "Refresh GitHub") {
                        Task { await store.refresh() }
                    }
                }
                QuietIconButton(symbol: "plus", label: "New note") { store.addNote() }
                QuietIconButton(symbol: "slider.horizontal.3", label: "Settings") { showSettings() }
            }.padding(.horizontal, 15).padding(.vertical, 8)
            Divider().overlay(.white.opacity(0.025))
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        if let error = store.saveError {
                            VStack(alignment: .leading, spacing: 6) {
                                Label(error, systemImage: "exclamationmark.triangle").font(.stow(size: 11))
                                Button(store.storageNeedsRecovery ? "Recover saved data…" : "Retry saving") {
                                    if store.storageNeedsRecovery {
                                        confirmRecovery()
                                    } else {
                                        Task { _ = await store.flush() }
                                    }
                                }.buttonStyle(.link).font(.stow(size: 11))
                            }.foregroundStyle(Color.stowAmber)
                        }
                        if store.state.githubEnabled {
                            prSection("Needs you", section: .needsYou)
                            prSection("Waiting", section: .waiting)
                            if let message = store.githubMessage {
                                Label(message, systemImage: "wifi.exclamationmark")
                                    .font(.stow(size: 10)).foregroundStyle(Color.stowMuted)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        CollapsibleBoardSection(
                            title: "Notes", count: store.state.notes.count,
                            isCollapsed: store.sectionIsCollapsed("notes"),
                            summary: store.state.notes.first?.markdown.split(separator: "\n").first.map(String.init),
                            toggle: { store.toggleSection("notes") }
                        ) {
                            if store.state.notes.isEmpty {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("A little room to think.").font(.stow(size: 13, weight: .medium))
                                    Text("Start a note, or paste a pull request link here.")
                                        .font(.stow(size: 11)).foregroundStyle(Color.stowMuted)
                                    Button("New note") { store.addNote() }.controlSize(.small)
                                }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color.stowSurface, in: RoundedRectangle(cornerRadius: 9))
                            }
                            ForEach(store.state.notes) { note in
                                Group {
                                    if note.isDetached {
                                        DetachedNoteLauncher(note: note) { store.detachNote(note.id) }
                                    } else {
                                        NoteView(store: store, noteID: note.id)
                                    }
                                }.id(note.id)
                            }
                        }
                        AccessoryViews(store: store)
                    }.padding(14)
                }
                .onChange(of: store.focusRequestID) { _, _ in
                    guard let id = store.focusNoteID else { return }
                    Task { @MainActor in
                        await Task.yield()
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                }
            }
            HStack(spacing: 5) {
                Circle().fill(store.githubMessage == nil ? Color.stowGreen.opacity(0.75) : Color.stowAmber)
                    .frame(width: 4, height: 4)
                if !store.state.githubEnabled {
                    Text("Notes only")
                } else if let refreshed = store.state.lastRefreshAt {
                    Text("Updated \(refreshed, style: .relative) ago")
                } else {
                    Text("Notes are saved on this Mac")
                }
                Spacer()
            }.font(.stow(size: 9)).foregroundStyle(Color.stowMuted).padding(.horizontal, 15).padding(.bottom, 9)
        }
        .foregroundStyle(Color.stowText).background(Color.stowBackground)
        .preferredColorScheme(ThemeController.shared.colorScheme)
        .frame(minWidth: 320, minHeight: 320)
    }

    private func prSection(_ title: String, section: AttentionSection) -> some View {
        let cards = store.cards(in: section)
        return CollapsibleBoardSection(
            title: title, count: cards.count, isCollapsed: store.sectionIsCollapsed(section.rawValue),
            summary: cards.prefix(2).map(\.title).joined(separator: " · "),
            needsAttention: section == .needsYou && !cards.isEmpty,
            toggle: { store.toggleSection(section.rawValue) },
            content: {
                if cards.isEmpty {
                    Text(section == .needsYou ? "Nothing needs you right now." : "No pull requests waiting.")
                        .font(.stow(size: 11)).foregroundStyle(Color.stowMuted).padding(.vertical, 3)
                }
                ForEach(cards) { pr in PRCard(store: store, pr: pr) }
            })
    }

    private func confirmRecovery() {
        let alert = NSAlert()
        alert.messageText = "Back up saved data and start recovery?"
        alert.informativeText =
            "The existing file will be kept beside state.json as a backup. Notes currently in memory will be saved as the new state."
        alert.addButton(withTitle: "Back up and recover")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { Task { await store.recoverState() } }
    }
}

private struct CollapsibleBoardSection<Content: View>: View {
    let title: String
    let count: Int
    let isCollapsed: Bool
    var summary: String?
    var needsAttention = false
    var toggle: () -> Void
    @ViewBuilder var content: () -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) { toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right").font(.stow(size: 8, weight: .semibold))
                        .rotationEffect(.degrees(isCollapsed ? 0 : 90)).frame(width: 9)
                    Text(title).font(.stow(size: 11, weight: .semibold))
                    Text("\(count)").font(.stow(size: 10)).foregroundStyle(Color.stowMuted)
                    if needsAttention && isCollapsed { Circle().fill(Color.stowAmber).frame(width: 4, height: 4) }
                    Spacer()
                }.padding(.vertical, 3).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityLabel("\(title), \(count)")
                .accessibilityValue(isCollapsed ? "Collapsed" : "Expanded")
                .help("\(isCollapsed ? "Expand" : "Collapse") \(title)")
            if isCollapsed {
                if let summary, !summary.isEmpty {
                    Text(summary).font(.stow(size: 10)).foregroundStyle(Color.stowMuted)
                        .lineLimit(1).padding(.leading, 15)
                }
            } else {
                content()
            }
        }
    }
}
