import AppKit
import StowCore
import SwiftUI

final class StowPanel: NSPanel {
    var noteID: UUID?
    var onPaste: ((String) -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
            event.charactersIgnoringModifiers?.lowercased() == "v", !(firstResponder is NSTextView),
            let value = NSPasteboard.general.string(forType: .string)
        {
            onPaste?(value)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    @objc func paste(_ sender: Any?) {
        if let value = NSPasteboard.general.string(forType: .string) { onPaste?(value) }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private(set) var manager: ProfileManager?
    /// Held for the process lifetime; a second Stow on the same data folder hands over to this one.
    private var instanceLock: StateLock?
    private var profilesMenu = NSMenu(title: "Profiles")
    /// The menu bar's Profiles item, hidden while one profile looks as Stow did before profiles.
    private var profilesMenuItem: NSMenuItem?
    /// Menu items whose titles name the active profile once several exist: base title, then the item.
    private var profileTitled: [(base: String, join: String, item: NSMenuItem)] = []

    /// The active profile's store and windows.
    var store: AppStore! { manager?.activeSession?.store }
    var board: StowPanel! { manager?.activeSession?.board }
    var noteWindows: [UUID: StowPanel] { manager?.activeSession?.noteWindows ?? [:] }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hosted unit tests construct their own app delegate with temporary state.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return }
        var stateURL = StateRepository.defaultURL
        var demo = false
        #if DEBUG
            var hasIsolatedState = false
            let arguments = ProcessInfo.processInfo.arguments
            // The folder after --stow-testing-state becomes the data folder, and it can never be the normal one.
            if let index = arguments.firstIndex(of: "--stow-testing-state"), arguments.count > index + 1 {
                let path = arguments[index + 1]
                let proposed = URL(fileURLWithPath: path).appendingPathComponent("state.json")
                if path.hasPrefix("/"), !path.hasPrefix("--"),
                    proposed.resolvingSymlinksInPath().standardizedFileURL
                        != StateRepository.defaultURL.resolvingSymlinksInPath().standardizedFileURL
                {
                    hasIsolatedState = true
                    stateURL = proposed
                    demo = arguments.contains("--stow-demo")
                }
            }
            let smoke = arguments.contains("--stow-smoke-test")
            if (arguments.contains("--stow-testing-state") || smoke || arguments.contains("--stow-demo"))
                && !hasIsolatedState
            {
                NSApp.terminate(nil)
                return
            }
            // A smoke run may capture views, so it must start with fresh synthetic state.
            if smoke && (!demo || FileManager.default.fileExists(atPath: stateURL.path)) {
                NSApp.terminate(nil)
                return
            }
        #endif
        switch StateLock.acquire(named: StateLock.instanceFilename, in: stateURL.deletingLastPathComponent()) {
        case .acquired(let lock): instanceLock = lock
        case .unavailable: break
        case .heldByAnotherProcess:
            // Another Stow already runs on this data folder. Hand over to it instead of competing.
            Self.activateRunningCopy()
            NSApp.terminate(nil)
            return
        }
        Task {
            guard await prepare(stateURL: stateURL, isDemo: demo), let manager else {
                // Another process, such as an older build, has the profiles open: hand over to it. With no profile
                // to list, the manager has already said so.
                if self.manager?.profiles.isEmpty == false { Self.activateRunningCopy() }
                NSApp.terminate(nil)
                return
            }
            #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--stow-smoke-test") {
                    await runSmokeTest()
                    return
                }
            #endif
            for session in manager.sessions.values { await session.store.refresh() }
        }
    }

    /// Opens the profiles of the data folder, the folder holding `stateURL`. Returns false when no profile could
    /// open because other processes hold their locks. Tests pass a catalog whose Trash is their own.
    @discardableResult
    func prepare(stateURL: URL, isDemo: Bool, catalog: ProfileCatalog? = nil) async -> Bool {
        let manager = ProfileManager(
            dataFolder: stateURL.deletingLastPathComponent(), isDemo: isDemo, catalog: catalog)
        self.manager = manager
        manager.onProfilesChange = { [weak self] in self?.rebuildProfilesMenu() }
        installMenus()
        guard await manager.start() else { return false }
        DispatchQueue.main.async { LaunchMetrics.firstBoardVisible() }
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // A profile put back from the Trash, or moved in Finder, appears or goes from the menus. A list that
        // cannot be read now stays as it was.
        if let manager { Task { try? await manager.reloadProfiles() } }
        for session in manager?.sessions.values.filter({ $0.store.isLoaded }) ?? [] {
            let store = session.store
            Task {
                _ = await store.flush()
                await store.refresh()
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard let manager else { return false }
        manager.reopenMostRecent()
        return true
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let dock = NSMenu()
        if let manager, manager.profiles.count > 1 {
            for entry in manager.profiles { dock.addItem(profileItem(entry, in: manager, shortcut: nil)) }
            dock.addItem(.separator())
        }
        item("New profile…", #selector(newProfile), "", in: dock)
        return dock
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshTitles()
        if menu === profilesMenu { rebuildProfilesMenu() }
    }

    @objc private func newProfile() { manager?.requestNewProfile() }
    @objc private func switchToProfile(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID, let manager else { return }
        Task { await manager.switchTo(id) }
    }
    @objc private func nextProfile() {
        guard let manager else { return }
        Task { await manager.switchRelative(1) }
    }
    @objc private func previousProfile() {
        guard let manager else { return }
        Task { await manager.switchRelative(-1) }
    }

    /// A profile's menu item: checked when visible, a dash when hidden, plain when closed.
    private func profileItem(_ entry: ProfileEntry, in manager: ProfileManager, shortcut: String?) -> NSMenuItem {
        let item = NSMenuItem(title: entry.name, action: #selector(switchToProfile), keyEquivalent: shortcut ?? "")
        item.target = self
        item.representedObject = entry.id
        if shortcut != nil { item.keyEquivalentModifierMask = [.control, .option] }
        item.state = manager.menuState(of: entry.id)
        return item
    }

    /// The Profiles menu lists every profile in order. The first nine carry ⌃⌥1 to ⌃⌥9, and Next and Previous
    /// use ⌃⌥] and ⌃⌥[. These are menu key equivalents, so they work only while Stow is the active app. The menu
    /// shows once a second profile exists, or always with Always show profile name. Until then it is hidden and
    /// carries no shortcuts, since AppKit still honors those of a hidden menu, so one profile looks and behaves as
    /// Stow did before profiles.
    private func rebuildProfilesMenu() {
        guard let manager else { return }
        let shows = manager.showsProfileNames
        profilesMenuItem?.isHidden = !shows
        profilesMenu.removeAllItems()
        for (position, entry) in manager.profiles.enumerated() {
            let shortcut = shows && position < 9 ? String(position + 1) : nil
            profilesMenu.addItem(profileItem(entry, in: manager, shortcut: shortcut))
        }
        profilesMenu.addItem(.separator())
        if manager.profiles.count > 1 {
            for (title, selector, key) in [
                ("Next profile", #selector(nextProfile), "]"), ("Previous profile", #selector(previousProfile), "["),
            ] {
                item(title, selector, key, in: profilesMenu).keyEquivalentModifierMask = [.control, .option]
            }
            profilesMenu.addItem(.separator())
        }
        item("New profile…", #selector(newProfile), "", in: profilesMenu)
    }

    /// With several profiles, New note, Refresh GitHub, Settings…, and Show board name the profile they act on.
    private func refreshTitles() {
        let name = manager.flatMap { $0.showsProfileNames ? $0.activeSession?.entry.name : nil }
        for entry in profileTitled {
            guard let name else {
                entry.item.title = entry.base
                continue
            }
            let ellipsis = entry.base.hasSuffix("…")
            let base = ellipsis ? String(entry.base.dropLast()) : entry.base
            entry.item.title = "\(base) \(entry.join) \(name)" + (ellipsis ? "…" : "")
        }
    }

    private static func activateRunningCopy() {
        let current = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != current }
        // Prefer the same installed copy; a development build may share the bundle identifier.
        if let other = others.first(where: { $0.bundleURL == Bundle.main.bundleURL }) ?? others.first {
            other.activate(options: [])
        } else {
            let alert = NSAlert()
            alert.messageText = "Stow is already open"
            alert.informativeText = "Another Stow process is using this data. Quit it, then open Stow again."
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // With every profile closed there is nothing to save, but the quit still records that none is open.
        guard let manager, let quitting = manager.prepareToQuit() else { return .terminateNow }
        Task.detached {
            let results = await quitting.value
            // AppKit waits in a nested run loop during termination; a main-queue Task
            // can be blocked there. Deliver the reply as a run-loop source instead.
            RunLoop.main.perform(inModes: [.common]) {
                MainActor.assumeIsolated {
                    let failed = Set(results.filter { !$0.value }.keys)
                    guard !failed.isEmpty else { return NSApp.reply(toApplicationShouldTerminate: true) }
                    let failedNames = manager.profiles.filter { failed.contains($0.id) }.map(\.name)
                    let alert = NSAlert()
                    // A single profile reads as Stow always has; with names showing, it names the failed ones.
                    alert.messageText = "Some changes could not be saved"
                    if manager.showsProfileNames, !failedNames.isEmpty {
                        let names = ListFormatter.localizedString(byJoining: failedNames)
                        alert.messageText = "Some changes in \(names) could not be saved"
                    }
                    alert.informativeText =
                        "Keep Stow open to preserve notes currently in memory, or quit without saving those changes."
                    alert.addButton(withTitle: "Keep open")
                    alert.addButton(withTitle: "Quit without saving")
                    let quit = alert.runModal() == .alertSecondButtonReturn
                    if !quit { manager.cancelTermination() }
                    NSApp.reply(toApplicationShouldTerminate: quit)
                }
            }
        }
        return .terminateLater
    }

    /// Records a moved window's frame through the profile that owns it. Windows report moves to their profile
    /// directly, so only tests call this.
    func windowDidMove(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        manager?.session(owning: window)?.windowDidMove(notification)
    }

    @objc func showBoard() { manager?.activeSession?.showBoard() }
    @objc func newNote() {
        guard let session = manager?.activeSession else { return }
        session.showBoard()
        session.store.addNote()
    }
    @objc func refresh() {
        guard let store = manager?.activeSession?.store else { return }
        Task { await store.refresh() }
    }
    @objc func showSettings() { manager?.activeSession?.showSettings() }

    private func installMenus() {
        profileTitled = []
        let main = NSMenu()
        let app = NSMenu()
        app.addItem(
            withTitle: "About Stow", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: "")
        app.addItem(.separator())
        item("Settings…", #selector(showSettings), ",", in: app, names: "for")
        app.addItem(.separator())
        app.addItem(withTitle: "Hide Stow", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Stow", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem()
        appItem.submenu = app
        main.addItem(appItem)
        let file = NSMenu(title: "File")
        item("New note", #selector(newNote), "n", in: file, names: "in")
        item("New profile…", #selector(newProfile), "", in: file)
        item("Refresh GitHub", #selector(refresh), "r", in: file, names: "in")
        file.addItem(withTitle: "Close window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(withTitle: "File", action: nil, keyEquivalent: "").submenu = file
        let edit = NSMenu(title: "Edit")
        for (title, selector, key) in [
            ("Undo", "undo:", "z"), ("Redo", "redo:", "Z"), ("Cut", "cut:", "x"),
            ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select all", "selectAll:", "a"),
        ] {
            edit.addItem(withTitle: title, action: NSSelectorFromString(selector), keyEquivalent: key)
        }
        main.addItem(withTitle: "Edit", action: nil, keyEquivalent: "").submenu = edit
        let windows = NSMenu(title: "Window")
        item("Show board", #selector(showBoard), "0", in: windows, names: "in")
        windows.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        main.addItem(withTitle: "Window", action: nil, keyEquivalent: "").submenu = windows
        // The Profiles menu sits before Window, as the menus that list windows usually do.
        profilesMenu = NSMenu(title: "Profiles")
        let profilesItem = main.insertItem(
            withTitle: "Profiles", action: nil, keyEquivalent: "", at: main.items.count - 1)
        profilesItem.submenu = profilesMenu
        profilesMenuItem = profilesItem
        for menu in [app, file, profilesMenu, windows] { menu.delegate = self }
        rebuildProfilesMenu()
        NSApp.mainMenu = main
        NSApp.windowsMenu = windows
    }

    @discardableResult
    private func item(
        _ title: String, _ action: Selector, _ key: String, in menu: NSMenu, names join: String? = nil
    ) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        item.target = self
        if let join { profileTitled.append((title, join, item)) }
        return item
    }
}

@MainActor
func restoredFrame(_ stored: WindowFrame?, fallback: NSRect, minimum: NSSize) -> NSRect {
    let screens = NSScreen.screens.map(\.visibleFrame)
    let defaultScreen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
    var candidate = fallback
    if let stored, [stored.x, stored.y, stored.width, stored.height].allSatisfy(\.isFinite), stored.width > 0,
        stored.height > 0
    {
        candidate = NSRect(x: stored.x, y: stored.y, width: stored.width, height: stored.height)
    }
    let screen =
        screens.max { left, right in
            let l = left.intersection(candidate)
            let r = right.intersection(candidate)
            return (l.isNull ? 0 : l.width * l.height) < (r.isNull ? 0 : r.width * r.height)
        } ?? defaultScreen
    candidate.size.width = min(max(candidate.width, minimum.width), screen.width)
    candidate.size.height = min(max(candidate.height, minimum.height), screen.height)
    candidate.origin.x = max(screen.minX, min(candidate.minX, screen.maxX - candidate.width))
    candidate.origin.y = max(screen.minY, min(candidate.minY, screen.maxY - candidate.height))
    return candidate
}
