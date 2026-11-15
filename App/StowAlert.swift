import AppKit

/// Shows a modal alert and says which button was chosen.
enum StowAlert {
    /// Runs the alert, in the warning style NSAlert uses by default, and returns the index of the chosen button in
    /// `buttons`. The first button is the default.
    @MainActor @discardableResult
    static func run(
        _ message: String, _ detail: String, buttons: [String], firstIsDestructive: Bool = false,
        accessory: NSView? = nil, appearance: NSAppearance? = nil
    ) -> Int {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = detail
        for title in buttons { alert.addButton(withTitle: title) }
        if firstIsDestructive { alert.buttons.first?.hasDestructiveAction = true }
        if let accessory {
            alert.accessoryView = accessory
            alert.window.initialFirstResponder = accessory
        }
        if let appearance { alert.window.appearance = appearance }
        return alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
    }
}
