import AppKit
import SwiftUI

/// A pull-down menu button backed by `NSPopUpButton`.
///
/// SwiftUI's `Menu` gives assistive apps no press action, so the accessibility audit flags it. AppKit's pull-down
/// button supports both press and show-menu.
struct PullDownMenu: NSViewRepresentable {
    struct Item {
        let title: String
        let action: () -> Void
    }

    /// The button face: a title, or a symbol when `symbol` is set.
    var title = ""
    var symbol: String?
    /// Groups of items, separated by dividers.
    var sections: [[Item]]
    var label: String
    var identifier: String?
    var tint: Color?
    var font: NSFont?

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: true)
        button.isBordered = symbol == nil
        button.contentTintColor = tint.map(NSColor.init)
        context.coordinator.shownTint = tint
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.setAccessibilityIdentifier(identifier)
        return button
    }

    /// Changes only what differs: each AppKit setter can post accessibility notifications to assistive apps.
    func updateNSView(_ button: NSPopUpButton, context: Context) {
        let coordinator = context.coordinator
        coordinator.actions = sections.flatMap { $0.map(\.action) }
        let titles = [[title]] + sections.map { $0.map(\.title) }
        if coordinator.shownTitles != titles {
            coordinator.shownTitles = titles
            button.menu = menu(coordinator: coordinator)
        }
        if button.isEnabled != context.environment.isEnabled { button.isEnabled = context.environment.isEnabled }
        if let font, button.font != font { button.font = font }
        // The tint follows the profile's theme when its appearance changes.
        if coordinator.shownTint != tint {
            coordinator.shownTint = tint
            button.contentTintColor = tint.map(NSColor.init)
        }
    }

    private func menu(coordinator: Coordinator) -> NSMenu {
        let menu = NSMenu()
        // A pull-down button draws its first item as the face and leaves it out of the open menu.
        let face = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        face.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: label) }
        menu.addItem(face)
        var index = 0
        for (number, section) in sections.enumerated() {
            if number > 0 { menu.addItem(.separator()) }
            for item in section {
                let entry = NSMenuItem(title: item.title, action: #selector(Coordinator.runItem(_:)), keyEquivalent: "")
                entry.target = coordinator
                entry.tag = index
                index += 1
                menu.addItem(entry)
            }
        }
        return menu
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor final class Coordinator: NSObject {
        var actions: [() -> Void] = []
        var shownTitles: [[String]]?
        var shownTint: Color?

        /// Not `perform(_:)`: a selector by that name resolves to NSObject's `performSelector:`, which would treat
        /// the menu item as a selector and run nothing.
        @objc func runItem(_ sender: NSMenuItem) {
            guard actions.indices.contains(sender.tag) else { return }
            actions[sender.tag]()
        }
    }
}
