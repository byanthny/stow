import AppKit
import SwiftUI

/// The pull-down button, with insets removed when it covers a view beneath it.
final class PullDownButton: NSPopUpButton {
    var coversFrame = false
    override var alignmentRectInsets: NSEdgeInsets { coversFrame ? NSEdgeInsets() : super.alignmentRectInsets }
}

/// A pull-down menu button backed by `NSPopUpButton`.
///
/// SwiftUI's `Menu` gives assistive apps no press action, so the accessibility audit flags it. AppKit's pull-down
/// button supports both press and show-menu.
struct PullDownMenu: NSViewRepresentable {
    struct Item {
        let title: String
        /// Read when the menu is built.
        var state: NSControl.StateValue = .off
        let action: @MainActor () -> Void
    }

    /// The button face: a title, or a symbol when `symbol` is set.
    var title = ""
    var symbol: String?
    /// Groups of items, separated by dividers.
    var sections: [[Item]] = []
    /// Groups of items built each time the menu opens, in place of `sections`.
    var provider: (@MainActor () -> [[Item]])?
    var label: String
    var identifier: String?
    /// The tooltip, when it differs from `label`.
    var toolTip: String?
    var help: String?
    var value: String?
    var tint: Color?
    var font: NSFont?
    /// A symbol face's size and weight, so it matches the icon buttons beside it.
    var symbolSize: CGFloat = 13
    var symbolWeight: NSFont.Weight = .regular
    /// A transparent button that fills the space SwiftUI offers, to sit over an icon.
    var covers = false

    func makeNSView(context: Context) -> PullDownButton {
        let button = PullDownButton(frame: .zero, pullsDown: true)
        button.coversFrame = covers
        button.isBordered = symbol == nil && !covers
        // Symbol faces drop the pull-down arrow.
        if symbol != nil || covers { (button.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow }
        button.contentTintColor = tint.map(NSColor.init)
        context.coordinator.shownTint = tint
        button.toolTip = toolTip ?? label
        button.setAccessibilityLabel(label)
        button.setAccessibilityIdentifier(identifier)
        if let help { button.setAccessibilityHelp(help) }
        if let value { button.setAccessibilityValue(value) }
        return button
    }

    /// Changes only what differs: each AppKit setter can post accessibility notifications to assistive apps.
    func updateNSView(_ button: PullDownButton, context: Context) {
        let coordinator = context.coordinator
        coordinator.provider = provider
        if provider == nil { coordinator.actions = sections.flatMap { $0.map(\.action) } }
        let titles = [[title]] + sections.map { $0.map(\.title) }
        if coordinator.shownTitles != titles {
            coordinator.shownTitles = titles
            button.menu = menu(coordinator: coordinator)
        }
        if button.isEnabled != context.environment.isEnabled { button.isEnabled = context.environment.isEnabled }
        if let font, button.font != font { button.font = font }
        if button.accessibilityLabel() != label { button.setAccessibilityLabel(label) }
        if button.toolTip != (toolTip ?? label) { button.toolTip = toolTip ?? label }
        if let value, button.accessibilityValue() as? String != value { button.setAccessibilityValue(value) }
        // The tint follows the profile's theme when its appearance changes.
        if coordinator.shownTint != tint {
            coordinator.shownTint = tint
            button.contentTintColor = tint.map(NSColor.init)
        }
    }

    /// A covering button fills the space over the icon that SwiftUI offers.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView button: PullDownButton, context: Context) -> CGSize? {
        covers ? proposal.replacingUnspecifiedDimensions(by: CGSize(width: 22, height: 22)) : nil
    }

    private func menu(coordinator: Coordinator) -> NSMenu {
        let menu = NSMenu()
        // A pull-down button draws its first item as the face and leaves it out of the open menu.
        let face = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        face.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: label) }?
            .withSymbolConfiguration(.init(pointSize: symbolSize, weight: symbolWeight))
        menu.addItem(face)
        if provider == nil { coordinator.fill(menu, with: sections) } else { menu.delegate = coordinator }
        return menu
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor final class Coordinator: NSObject, NSMenuDelegate {
        var actions: [@MainActor () -> Void] = []
        var provider: (@MainActor () -> [[Item]])?
        var shownTitles: [[String]]?
        var shownTint: Color?

        /// Adds the sections' items after the face, with dividers between sections.
        func fill(_ menu: NSMenu, with sections: [[Item]]) {
            var index = 0
            for (number, section) in sections.enumerated() {
                if number > 0 { menu.addItem(.separator()) }
                for item in section {
                    let entry = NSMenuItem(title: item.title, action: #selector(runItem(_:)), keyEquivalent: "")
                    entry.target = self
                    entry.tag = index
                    entry.state = item.state
                    index += 1
                    menu.addItem(entry)
                }
            }
        }

        /// Rebuilds the menu as it opens, so it lists things as they are now.
        func menuNeedsUpdate(_ menu: NSMenu) {
            guard let provider else { return }
            while menu.items.count > 1 { menu.removeItem(at: 1) }
            let sections = provider()
            actions = sections.flatMap { $0.map(\.action) }
            fill(menu, with: sections)
        }

        /// The menu has no key equivalents, so key presses never need it rebuilt.
        func menuHasKeyEquivalent(
            _ menu: NSMenu, for event: NSEvent, target: AutoreleasingUnsafeMutablePointer<AnyObject?>,
            action: UnsafeMutablePointer<Selector?>
        ) -> Bool { false }

        /// Not `perform(_:)`: a selector by that name resolves to NSObject's `performSelector:`, which would treat
        /// the menu item as a selector and run nothing.
        @objc func runItem(_ sender: NSMenuItem) {
            guard actions.indices.contains(sender.tag) else { return }
            actions[sender.tag]()
        }
    }
}
