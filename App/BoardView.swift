import AppKit
import StowCore
import SwiftUI

struct BoardView: View {
    @Bindable var store: AppStore
    let profile: ProfileHandle
    var showSettings: () -> Void
    @Environment(\.stowTheme) private var theme
    @Environment(\.windowChrome) private var chrome
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
                if store.showsOwnerControl { OwnerControl(store: store) }
                if store.isRefreshing {
                    ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 20)
                } else {
                    QuietIconButton(symbol: "arrow.clockwise", label: "Refresh GitHub") {
                        Task { await store.refresh() }
                    }
                }
                QuietIconButton(
                    symbol: store.state.boardAlwaysOnTop ? "pin.fill" : "pin",
                    label: store.state.boardAlwaysOnTop ? "Unpin board from top" : "Pin board on top", scale: .small
                ) { store.toggleBoardAlwaysOnTop() }
                .accessibilityValue(store.state.boardAlwaysOnTop ? "Pinned" : "Unpinned")
                .accessibilityIdentifier("board.alwaysOnTop")
                QuietIconButton(symbol: "plus", label: "New note") { store.addNote() }
                QuietIconButton(symbol: "slider.horizontal.3", label: "Settings") { showSettings() }
            }
            .windowHeaderRow(chrome, horizontal: 15, vertical: 8)
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
        let notes = store.visibleNotes
        let heading = NotesHeading(store: store)
        return pinnedSection(
            "Notes", count: heading.count, detail: heading.detail, id: BoardLayout.Section.notes.rawValue,
            collapsible: collapsible,
            summary: notes.first?.markdown.split(separator: "\n").first.map(String.init)
        ) {
            // Click and start typing; a started note that stays empty goes away again.
            if store.draftNoteID == nil {
                NoteComposerRow(isEmpty: store.state.notes.isEmpty) { store.startNote() }
            }
            ForEach(notes) { note in
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
        let listed = SectionCards(cards, layout: store.state.boardLayout, expanded: expanded)
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
            ForEach(listed.groups) { group in
                if let owner = group.owner { OwnerSubheading(owner: owner, count: group.count) }
                ForEach(group.cards) { pr in PRCard(store: store, pr: pr) }
            }
            if limited {
                Button(expanded ? "Show fewer" : "Show \(listed.moreCount) more") {
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
        _ title: String, count: Int, detail: String? = nil, id: String, collapsible: Bool, summary: String?,
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
                title: title, count: count, detail: detail, isCollapsed: isCollapsed, collapsible: collapsible,
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
    /// Words after the count, such as how many notes an owner filter hides.
    var detail: String?
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
                .accessibilityLabel(label)
                .accessibilityValue(isCollapsed ? "Collapsed" : "Expanded")
                .help("\(isCollapsed ? "Expand" : "Collapse") \(title)")
        } else {
            row.accessibilityElement(children: .ignore).accessibilityLabel(label)
                .accessibilityAddTraits(.isHeader)
        }
    }

    private var label: String { detail.map { "\(title), \(count), \($0)" } ?? "\(title), \(count)" }

    private var row: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.right").font(theme.font(size: 8, weight: .semibold))
                .rotationEffect(.degrees(isCollapsed ? 0 : 90)).frame(width: 9)
                .opacity(collapsible ? 1 : 0)
            Text(title).font(theme.font(size: 11, weight: .semibold))
            Text(verbatim: "\(count)").font(theme.font(size: 10)).foregroundStyle(.stowMuted)
            if let detail { Text(verbatim: "· \(detail)").font(theme.font(size: 10)).foregroundStyle(.stowMuted) }
            if needsAttention && isCollapsed { Circle().fill(.stowAmber).frame(width: 4, height: 4) }
            Spacer()
        }.padding(.vertical, 3).contentShape(Rectangle())
    }
}

/// What the Notes header counts: the notes the board lists, and how many linked notes an owner filter hides.
struct NotesHeading: Equatable {
    var count: Int
    var hiddenCount: Int
    /// What the header says after the count while notes are hidden.
    var detail: String? { hiddenCount > 0 ? "\(hiddenCount) hidden" : nil }
}

extension NotesHeading {
    @MainActor init(store: AppStore) {
        let listed = store.visibleNotes.count
        self.init(count: listed, hiddenCount: store.state.notes.count - listed)
    }
}

/// A pull-request section's cards as the board lists them: under owner subheadings when Settings → Board groups by
/// owner, and only as many as show before Show more, which still counts cards per section.
struct SectionCards {
    struct Group: Identifiable {
        /// The subheading, or nil while the board does not group by owner.
        let owner: String?
        /// The owner's cards in the section, counting those after Show more.
        let count: Int
        /// The cards that show, in the section's order.
        let cards: [PullRequestSnapshot]
        var id: String { owner?.lowercased() ?? "" }
    }

    /// Groups with at least one card showing; an owner whose cards all come after Show more waits for it.
    let groups: [Group]
    /// The cards after Show more.
    let moreCount: Int

    init(_ cards: [PullRequestSnapshot], layout: BoardLayout, expanded: Bool) {
        var remaining = layout.shownPullRequests(of: cards.count, expanded: expanded)
        moreCount = cards.count - remaining
        let owners: [(owner: String?, cards: [PullRequestSnapshot])] =
            layout.groupByOwner
            ? groupedByOwner(cards, order: layout.ownerOrder).map { ($0.owner, $0.cards) } : [(nil, cards)]
        var groups: [Group] = []
        for (owner, ownerCards) in owners where remaining > 0 {
            let shown = Array(ownerCards.prefix(remaining))
            remaining -= shown.count
            groups.append(Group(owner: owner, count: ownerCards.count, cards: shown))
        }
        self.groups = groups
    }
}

/// An owner's name and card count above its cards while the board groups pull requests by owner.
private struct OwnerSubheading: View {
    let owner: String
    let count: Int
    @Environment(\.stowTheme) private var theme

    var body: some View {
        HStack(spacing: 5) {
            Text(verbatim: owner).font(theme.font(size: 10, weight: .semibold)).lineLimit(1).truncationMode(.middle)
            Text(verbatim: "\(count)").font(theme.font(size: 10))
            Spacer(minLength: 0)
        }
        .foregroundStyle(.stowMuted).padding(.leading, 2).padding(.top, 2)
        .accessibilityElement(children: .ignore).accessibilityLabel(Text(verbatim: "\(owner), \(count)"))
        .accessibilityAddTraits(.isHeader)
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
