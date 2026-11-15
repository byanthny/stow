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
                let owners = selected.joined(separator: ", ")
                PullDownMenu(
                    provider: menu, label: "Owners", identifier: "board.ownerMenu",
                    toolTip: owners.isEmpty ? "Owners" : "Owners: \(owners)", help: "Chooses whose pull requests show",
                    value: owners.isEmpty ? "All owners" : owners, covers: true
                ).frame(minWidth: 22, minHeight: 22)
            }
    }

    /// The menu as it is when it opens. Choosing an owner adds it to the selection or takes it out.
    private func menu() -> [[PullDownMenu.Item]] {
        let appearance = theme.appKitAppearance
        let owners = store.ownerSummaries.map { summary in
            PullDownMenu.Item(
                title: "\(summary.owner) (\(summary.cardCount))", state: summary.isSelected ? .on : .off
            ) { [store] in
                store.setOwnerSelection(store.base.ownerSelection.toggling(summary.owner))
            }
        }
        let sections: [[PullDownMenu.Item]] = [
            [
                PullDownMenu.Item(
                    title: "All owners", state: store.base.ownerSelection.isAll ? .on : .off
                ) { [store] in
                    store.setOwnerSelection(OwnerSelection())
                }
            ],
            owners,
            [
                PullDownMenu.Item(title: "Add owner…") { [store] in
                    guard let login = AddOwnerPrompt.run(appearance: appearance) else { return }
                    store.setOwnerSelection(store.base.ownerSelection.adding(login))
                }
            ],
        ]
        return sections.filter { !$0.isEmpty }
    }
}

/// Add owner…: asks for the GitHub login of an owner, such as one with no cards yet, and says why a login can't be
/// used.
enum AddOwnerPrompt {
    /// Asks until the person enters a GitHub login or cancels. A login that can't be used asks again, saying why
    /// and keeping what was typed. Returns nil when cancelled.
    @MainActor static func run(appearance: NSAppearance?) -> String? {
        var login = ""
        var problem: String?
        while true {
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
            field.stringValue = login
            field.placeholderString = "GitHub login"
            field.setAccessibilityLabel("GitHub login")
            field.setAccessibilityIdentifier("owners.addOwner.login")
            let choice = StowAlert.run(
                "Add owner", problem ?? "Enter the GitHub login of an organization or user.",
                buttons: ["Add", "Cancel"], accessory: field, appearance: appearance)
            guard choice == 0 else { return nil }
            login = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            problem = OwnerSelection.problem(with: login)
            if problem == nil { return login }
        }
    }
}
