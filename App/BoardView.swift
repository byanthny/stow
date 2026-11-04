import AppKit
import StowCore
import SwiftUI

struct BoardView: View {
    @Bindable var store: AppStore
    let profile: ProfileHandle
    var showSettings: () -> Void
    @Environment(\.stowTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Sections showing every card this session; the configured count applies again after relaunch.
    @State private var expandedSections: Set<AttentionSection> = []

    var body: some View {
        let header = BoardHeader(profile: profile, layout: store.state.boardLayout)
        let iconStyle = header.tint.map { AnyShapeStyle(Color(stowHex: $0)) } ?? AnyShapeStyle(.stowMuted)
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                // The icon is decorative; the profile menu button over it carries the profile's name.
                ProfileIconView(icon: header.icon, placeholder: "tray").font(theme.font(size: 16, weight: .medium))
                    .foregroundStyle(iconStyle).accessibilityHidden(true)
                    .overlay {
                        ProfileSwitcher(header: header) { profile.manager?.profileMenu(for: profile.id) ?? [] }
                            .frame(minWidth: 22, minHeight: 22)
                    }
                if let title = header.title {
                    // VoiceOver reads the name from the profile menu button.
                    Text(verbatim: title).font(theme.font(size: 14, weight: .semibold)).lineLimit(1)
                        .accessibilityHidden(true)
                }
                Spacer()
                if store.isRefreshing {
                    ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 20)
                } else {
                    QuietIconButton(symbol: "arrow.clockwise", label: "Refresh GitHub") {
                        Task { await store.refresh() }
                    }
                }
                QuietIconButton(
                    symbol: store.state.boardAlwaysOnTop ? "pin.fill" : "pin",
                    label: store.state.boardAlwaysOnTop ? "Unpin board from top" : "Pin board on top"
                ) { store.toggleBoardAlwaysOnTop() }
                .accessibilityValue(store.state.boardAlwaysOnTop ? "Pinned" : "Unpinned")
                .accessibilityIdentifier("board.alwaysOnTop")
                QuietIconButton(symbol: "plus", label: "New note") { store.addNote() }
                QuietIconButton(symbol: "slider.horizontal.3", label: "Settings") { showSettings() }
            }.padding(.horizontal, 15).padding(.vertical, 8)
            Divider().overlay(.white.opacity(0.025))
            ScrollViewReader { proxy in
                ScrollView {
                    // Section headers stay pinned so a long list still shows which section it is in.
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        banners.padding(.horizontal, 14).padding(.top, 14)
                        ForEach(store.state.boardLayout.order, id: \.self) { section in
                            boardSection(section)
                        }
                        if store.state.githubEnabled, let message = store.githubMessage {
                            Label(message, systemImage: "wifi.exclamationmark")
                                .font(theme.font(size: 10)).foregroundStyle(.stowMuted)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 14).padding(.bottom, 14)
                        }
                        AccessoryViews(store: store)
                    }.accessibilityElement(children: .contain).accessibilityLabel("Board contents").padding(.bottom, 14)
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
                Circle()
                    .fill(
                        store.githubMessage == nil
                            ? AnyShapeStyle(StowColor(role: .green).opacity(0.75)) : AnyShapeStyle(.stowAmber)
                    )
                    .frame(width: 4, height: 4)
                if !store.state.githubEnabled {
                    Text("Notes only")
                } else if let refreshed = store.state.lastRefreshAt {
                    Text("Updated \(refreshed, style: .relative) ago")
                } else {
                    Text("Notes are saved on this Mac")
                }
                Spacer()
            }.font(theme.font(size: 9)).foregroundStyle(.stowMuted).padding(.horizontal, 15).padding(.bottom, 9)
        }
        .foregroundStyle(.stowText).background(.stowBackground)
        .preferredColorScheme(theme.colorScheme)
        .frame(minWidth: 320, minHeight: 320)
        .disabled(store.isRestoringBackup)
    }

    @ViewBuilder private var banners: some View {
        VStack(alignment: .leading, spacing: 12) {
            if store.offersGitHubSetup { githubSetup }
            if let actual = store.accountMismatch { accountMismatchBanner(actual: actual) }
            if let error = store.saveError {
                VStack(alignment: .leading, spacing: 6) {
                    Label(error, systemImage: "exclamationmark.triangle").font(theme.font(size: 11))
                    Button(store.storageNeedsRecovery ? "Recover saved data…" : "Retry saving") {
                        if store.storageNeedsRecovery {
                            confirmRecovery()
                        } else {
                            Task { _ = await store.flush() }
                        }
                    }.buttonStyle(.link).font(theme.font(size: 11))
                }.foregroundStyle(.stowAmber)
            }
            if let message = store.noteFileMessage {
                Label(message, systemImage: "doc.on.doc")
                    .font(theme.font(size: 11)).foregroundStyle(.stowAmber)
            }
        }
    }

    private func accountMismatchBanner(actual: String) -> some View {
        let message = "GitHub is signed in as \(actual). This profile uses \(store.state.viewerLogin ?? "another account")."
        return VStack(alignment: .leading, spacing: 6) {
            Label(message, systemImage: "person.crop.circle.badge.exclamationmark").font(theme.font(size: 11))
            Button("Use \(actual) here") { Task { await store.useCurrentAccount() } }
                .buttonStyle(.link).font(theme.font(size: 11))
                .accessibilityLabel("Use \(actual) here for this profile")
                .accessibilityIdentifier("github.useCurrentAccount")
        }.foregroundStyle(.stowAmber)
            .accessibilityElement(children: .contain).accessibilityIdentifier("github.accountMismatch")
    }

    @ViewBuilder private func boardSection(_ section: BoardLayout.Section) -> some View {
        switch section {
        case .needsYou: if store.state.githubEnabled { prSection("Needs you", section: .needsYou) }
        case .waiting: if store.state.githubEnabled { prSection("Waiting", section: .waiting) }
        case .notes: notesSection
        }
    }

    private var githubSetup: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Show your pull requests?").font(theme.font(size: 13, weight: .medium))
            Text(
                "Stow can use your existing GitHub CLI login for github.com. Pull request titles and status are stored on this Mac. Notes work either way."
            )
            .font(theme.font(size: 11)).foregroundStyle(.stowMuted).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Use GitHub") { store.answerGitHubSetup(useGitHub: true) }
                    .controlSize(.small).accessibilityIdentifier("github.setup.use")
                Button("Not now") { store.answerGitHubSetup(useGitHub: false) }
                    .controlSize(.small).accessibilityIdentifier("github.setup.dismiss")
            }
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(.stowSurface, in: RoundedRectangle(cornerRadius: 9))
            .accessibilityElement(children: .contain).accessibilityIdentifier("github.setup")
    }

    private var notesSection: some View {
        let collapsible = store.state.boardLayout.notesCanCollapse
        return pinnedSection(
            "Notes", count: store.state.notes.count, id: BoardLayout.Section.notes.rawValue,
            collapsible: collapsible,
            summary: store.state.notes.first?.markdown.split(separator: "\n").first.map(String.init)
        ) {
            if store.state.notes.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("A little room to think.").font(theme.font(size: 13, weight: .medium))
                    Text("Start a note, or paste a pull request link here.")
                        .font(theme.font(size: 11)).foregroundStyle(.stowMuted)
                    Button("New note") { store.addNote() }.controlSize(.small)
                }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.stowSurface, in: RoundedRectangle(cornerRadius: 9))
            }
            ForEach(store.state.notes) { note in
                Group {
                    if note.isDetached {
                        DetachedNoteLauncher(note: note) { store.detachNote(note.id) }
                    } else if store.isNoteExpanded(note.id) {
                        NoteView(store: store, noteID: note.id) { store.toggleNoteExpanded(note.id) }
                    } else {
                        CollapsedNoteRow(store: store, note: note)
                    }
                }.id(note.id)
            }
        }
    }

    private func prSection(_ title: String, section: AttentionSection) -> some View {
        let cards = store.cards(in: section)
        let expanded = expandedSections.contains(section)
        let shown = store.state.boardLayout.shownPullRequests(of: cards.count, expanded: expanded)
        let limited = store.state.boardLayout.shownPullRequests(of: cards.count, expanded: false) < cards.count
        return pinnedSection(
            title, count: cards.count, id: section.rawValue, collapsible: true,
            summary: cards.prefix(2).map { "\($0.reference.repository): \($0.title)" }.joined(separator: " · "),
            needsAttention: section == .needsYou && !cards.isEmpty
        ) {
            if cards.isEmpty {
                Text(section == .needsYou ? "Nothing needs you right now." : "No pull requests waiting.")
                    .font(theme.font(size: 11)).foregroundStyle(.stowMuted).padding(.vertical, 3)
            }
            ForEach(cards.prefix(shown)) { pr in PRCard(store: store, pr: pr) }
            if limited {
                Button(expanded ? "Show fewer" : "Show \(cards.count - shown) more") {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) {
                        if expanded { expandedSections.remove(section) } else { expandedSections.insert(section) }
                    }
                }
                .buttonStyle(.plain).font(theme.font(size: 10, weight: .medium)).foregroundStyle(.stowMuted)
                .padding(.leading, 2)
            }
        }
    }

    private func pinnedSection<Content: View>(
        _ title: String, count: Int, id: String, collapsible: Bool, summary: String?,
        needsAttention: Bool = false, @ViewBuilder content: () -> Content
    ) -> some View {
        let isCollapsed = collapsible && store.sectionIsCollapsed(id)
        return Section {
            VStack(alignment: .leading, spacing: 9) {
                if isCollapsed {
                    if let summary, !summary.isEmpty {
                        Text(summary).font(theme.font(size: 10)).foregroundStyle(.stowMuted)
                            .lineLimit(1).padding(.leading, 15)
                    }
                } else {
                    content()
                }
            }
            .padding(.horizontal, 14).padding(.top, 4).padding(.bottom, 18)
        } header: {
            BoardSectionHeader(
                title: title, count: count, isCollapsed: isCollapsed, collapsible: collapsible,
                needsAttention: needsAttention
            ) { store.toggleSection(id) }
            .padding(.horizontal, 14).padding(.vertical, 4)
            // A pinned header covers cards scrolling beneath it, even on a translucent board.
            .background { Rectangle().fill(.ultraThinMaterial).overlay(.stowBackground) }
        }
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

extension BoardLayout.Section {
    var title: String {
        switch self {
        case .needsYou: "Needs you"
        case .notes: "Notes"
        case .waiting: "Waiting"
        }
    }
}

private struct BoardSectionHeader: View {
    let title: String
    let count: Int
    let isCollapsed: Bool
    let collapsible: Bool
    @Environment(\.stowTheme) private var theme
    var needsAttention = false
    var toggle: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if collapsible {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) { toggle() }
            } label: {
                row
            }.buttonStyle(.plain)
                .accessibilityLabel("\(title), \(count)")
                .accessibilityValue(isCollapsed ? "Collapsed" : "Expanded")
                .help("\(isCollapsed ? "Expand" : "Collapse") \(title)")
        } else {
            row.accessibilityElement(children: .ignore).accessibilityLabel("\(title), \(count)")
                .accessibilityAddTraits(.isHeader)
        }
    }

    private var row: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.right").font(theme.font(size: 8, weight: .semibold))
                .rotationEffect(.degrees(isCollapsed ? 0 : 90)).frame(width: 9)
                .opacity(collapsible ? 1 : 0)
            Text(title).font(theme.font(size: 11, weight: .semibold))
            Text(verbatim: "\(count)").font(theme.font(size: 10)).foregroundStyle(.stowMuted)
            if needsAttention && isCollapsed { Circle().fill(.stowAmber).frame(width: 4, height: 4) }
            Spacer()
        }.padding(.vertical, 3).contentShape(Rectangle())
    }
}

/// What the board header shows for its profile.
struct BoardHeader: Equatable {
    /// The profile's name, which labels the profile menu button.
    var name: String
    /// The title beside the icon: the profile's name, unless Settings → Board → Show board title is off.
    var title: String?
    /// The profile's icon when this Mac can show it; nil shows the tray.
    var icon: ProfileIcon?
    /// The profile's color for the icon once colors show; nil keeps the muted tray color.
    var tint: String?

    @MainActor
    init(profile: ProfileHandle, layout: BoardLayout) {
        let entry = profile.entry
        name = entry?.name ?? "Stow"
        title = layout.showsTitle ? name : nil
        icon = entry?.icon?.displayable
        tint = profile.showsIdentity ? entry?.color : nil
    }
}

/// The board header's profile menu: other profiles to switch to, Hide, Close, New profile…, and Profile settings….
/// A transparent AppKit pull-down button over the header's icon, because SwiftUI's `Menu` gives assistive apps no
/// press action. Its label is the profile's name.
struct ProfileSwitcher: NSViewRepresentable {
    let header: BoardHeader
    let menu: @MainActor () -> [[ProfileMenuItem]]

    func makeNSView(context: Context) -> ProfileSwitcherButton {
        let button = ProfileSwitcherButton(frame: .zero, pullsDown: true)
        button.isBordered = false
        (button.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        // The first item of a pull-down menu is the button's empty face; the rest are built as the menu opens.
        let items = NSMenu()
        items.addItem(NSMenuItem(title: "", action: nil, keyEquivalent: ""))
        items.delegate = context.coordinator
        button.menu = items
        button.toolTip = "Profiles"
        button.setAccessibilityIdentifier("board.profileMenu")
        button.setAccessibilityHelp("Switches profiles and opens profile settings")
        return button
    }

    /// Changes only what differs: each AppKit setter can post accessibility notifications to assistive apps.
    func updateNSView(_ button: ProfileSwitcherButton, context: Context) {
        context.coordinator.provider = menu
        if button.accessibilityLabel() != header.name { button.setAccessibilityLabel(header.name) }
        if button.isEnabled != context.environment.isEnabled { button.isEnabled = context.environment.isEnabled }
    }

    /// Fills the space over the icon that SwiftUI offers.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView button: ProfileSwitcherButton, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 22, height: 22))
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor final class Coordinator: NSObject, NSMenuDelegate {
        var provider: @MainActor () -> [[ProfileMenuItem]] = { [] }
        private var actions: [@MainActor () -> Void] = []

        /// Rebuilds the menu as it opens, so it lists the profiles and their states as they are now.
        func menuNeedsUpdate(_ menu: NSMenu) {
            while menu.items.count > 1 { menu.removeItem(at: 1) }
            actions = []
            for (number, section) in provider().enumerated() {
                if number > 0 { menu.addItem(.separator()) }
                for item in section {
                    let entry = NSMenuItem(title: item.title, action: #selector(choose(_:)), keyEquivalent: "")
                    entry.target = self
                    entry.tag = actions.count
                    entry.state = item.state
                    actions.append(item.action)
                    menu.addItem(entry)
                }
            }
        }

        /// The menu has no key equivalents, so key presses never need it rebuilt.
        func menuHasKeyEquivalent(
            _ menu: NSMenu, for event: NSEvent, target: AutoreleasingUnsafeMutablePointer<AnyObject?>,
            action: UnsafeMutablePointer<Selector?>
        ) -> Bool { false }

        @objc func choose(_ sender: NSMenuItem) {
            guard actions.indices.contains(sender.tag) else { return }
            actions[sender.tag]()
        }
    }
}

/// The profile menu button, without a pop-up button's usual insets, so it covers exactly the space SwiftUI gives it.
final class ProfileSwitcherButton: NSPopUpButton {
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets() }
}
