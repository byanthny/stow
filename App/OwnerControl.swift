import AppKit
import StowCore
import SwiftUI

/// The board header's owner control, separate from the profile menu: a filter icon whose menu lists All owners,
/// each known owner with its count, and Add owner…. The board shows it while `AppStore.showsOwnerControl` says so.
struct OwnerControl: View {
    let store: AppStore
    @Environment(\.stowTheme) private var theme

    var body: some View {
        // Empty while All owners is selected, since the selection then names no owner.
        let selected = store.ownerSummaries.filter(\.isSelected).map(\.owner)
        // The icon fills in while a selection hides other owners' cards.
        let symbol = selected.isEmpty ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill"
        // The icon is decorative; the menu button over it carries the name and the selection.
        Image(systemName: symbol).frame(width: 22, height: 22).foregroundStyle(.stowMuted).accessibilityHidden(true)
            .overlay {
                OwnerMenuButton(selectedOwners: selected) { menu() }.frame(minWidth: 22, minHeight: 22)
            }
    }

    /// The menu as it is when it opens. Choosing an owner adds it to the selection or takes it out.
    private func menu() -> [[OwnerMenuItem]] {
        let appearance = theme.appKitAppearance
        let owners = store.ownerSummaries.map { summary in
            OwnerMenuItem(title: "\(summary.owner) (\(summary.cardCount))", isChecked: summary.isSelected) { [store] in
                store.setOwnerSelection(store.state.ownerSelection.toggling(summary.owner))
            }
        }
        let sections: [[OwnerMenuItem]] = [
            [
                OwnerMenuItem(title: "All owners", isChecked: store.state.ownerSelection.isAll) { [store] in
                    store.setOwnerSelection(OwnerSelection())
                }
            ],
            owners,
            [
                OwnerMenuItem(title: "Add owner…") { [store] in
                    guard let login = AddOwnerPrompt.run(appearance: appearance) else { return }
                    store.setOwnerSelection(store.state.ownerSelection.adding(login))
                }
            ],
        ]
        return sections.filter { !$0.isEmpty }
    }
}

/// An item in the owner menu.
private struct OwnerMenuItem {
    let title: String
    var isChecked = false
    let action: @MainActor () -> Void
}

/// A transparent AppKit pull-down button over the owner control's icon, because SwiftUI's `Menu` gives assistive
/// apps no press action. Its label is "Owners" and its value says which owners show.
private struct OwnerMenuButton: NSViewRepresentable {
    /// The selected owners; none while All owners is selected.
    let selectedOwners: [String]
    let menu: @MainActor () -> [[OwnerMenuItem]]

    func makeNSView(context: Context) -> OwnerMenuButtonView {
        let button = OwnerMenuButtonView(frame: .zero, pullsDown: true)
        button.isBordered = false
        (button.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        // The first item of a pull-down menu is the button's empty face; the rest are built as the menu opens.
        let items = NSMenu()
        items.addItem(NSMenuItem(title: "", action: nil, keyEquivalent: ""))
        items.delegate = context.coordinator
        button.menu = items
        button.setAccessibilityLabel("Owners")
        button.setAccessibilityIdentifier("board.ownerMenu")
        button.setAccessibilityHelp("Chooses whose pull requests show")
        return button
    }

    /// Changes only what differs: each AppKit setter can post accessibility notifications to assistive apps.
    func updateNSView(_ button: OwnerMenuButtonView, context: Context) {
        context.coordinator.provider = menu
        let owners = selectedOwners.joined(separator: ", ")
        let value = owners.isEmpty ? "All owners" : owners
        if button.accessibilityValue() as? String != value { button.setAccessibilityValue(value) }
        let tip = owners.isEmpty ? "Owners" : "Owners: \(owners)"
        if button.toolTip != tip { button.toolTip = tip }
        if button.isEnabled != context.environment.isEnabled { button.isEnabled = context.environment.isEnabled }
    }

    /// Fills the space over the icon that SwiftUI offers.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView button: OwnerMenuButtonView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 22, height: 22))
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor final class Coordinator: NSObject, NSMenuDelegate {
        var provider: @MainActor () -> [[OwnerMenuItem]] = { [] }
        private var actions: [@MainActor () -> Void] = []

        /// Rebuilds the menu as it opens, so it lists the owners and their counts as they are now.
        func menuNeedsUpdate(_ menu: NSMenu) {
            while menu.items.count > 1 { menu.removeItem(at: 1) }
            actions = []
            for (number, section) in provider().enumerated() {
                if number > 0 { menu.addItem(.separator()) }
                for item in section {
                    let entry = NSMenuItem(title: item.title, action: #selector(choose(_:)), keyEquivalent: "")
                    entry.target = self
                    entry.tag = actions.count
                    entry.state = item.isChecked ? .on : .off
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

/// The owner menu button, without a pop-up button's usual insets, so it covers exactly the icon.
final class OwnerMenuButtonView: NSPopUpButton {
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets() }
}

/// Add owner…: asks for the GitHub login of an owner, such as one with no cards yet, and says why a login can't be
/// used.
enum AddOwnerPrompt {
    /// Why `login` can't be an owner, or nil when it is a GitHub login.
    static func problem(with login: String) -> String? {
        if OwnerSelection.isValidLogin(login) { return nil }
        if login.isEmpty { return "Enter the owner’s GitHub login." }
        let usesAllowedCharacters = login.unicodeScalars.allSatisfy {
            $0 == "-" || ($0.isASCII && CharacterSet.alphanumerics.contains($0))
        }
        if !usesAllowedCharacters { return "A GitHub login uses only letters from A to Z, numbers, and hyphens." }
        if login.count > 39 { return "A GitHub login has at most 39 characters." }
        return "A GitHub login can’t start or end with a hyphen or have two hyphens in a row."
    }

    /// Asks until the person enters a GitHub login or cancels. A login that can't be used asks again, saying why
    /// and keeping what was typed. Returns nil when cancelled.
    @MainActor static func run(appearance: NSAppearance?) -> String? {
        var login = ""
        var problem: String?
        while true {
            let alert = NSAlert()
            alert.messageText = "Add owner"
            alert.informativeText = problem ?? "Enter the GitHub login of an organization or user."
            alert.addButton(withTitle: "Add")
            alert.addButton(withTitle: "Cancel")
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
            field.stringValue = login
            field.placeholderString = "GitHub login"
            field.setAccessibilityLabel("GitHub login")
            field.setAccessibilityIdentifier("owners.addOwner.login")
            alert.accessoryView = field
            alert.window.initialFirstResponder = field
            alert.window.appearance = appearance
            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            login = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            problem = Self.problem(with: login)
            if problem == nil { return login }
        }
    }
}

extension OwnerSelection {
    /// The selection with `owner` added. An owner already selected, ignoring case, keeps its spelling.
    func adding(_ owner: String) -> OwnerSelection { OwnerSelection(owners + [owner]) }

    /// The selection with `owner` added, or taken out when it is selected. Taking out the last owner selects All
    /// owners.
    func toggling(_ owner: String) -> OwnerSelection {
        guard contains(owner) else { return adding(owner) }
        return OwnerSelection(owners.filter { $0.caseInsensitiveCompare(owner) != .orderedSame })
    }
}
