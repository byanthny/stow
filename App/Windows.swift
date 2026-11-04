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
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var manager: ProfileManager?
    /// Held for the process lifetime; a second Stow on the same data folder hands over to this one.
    private var instanceLock: StateLock?

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
                // Another process, such as an older build, has the profile open. Hand over to it.
                Self.activateRunningCopy()
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

    /// Opens a profile from the data folder, the folder holding `stateURL`. Returns false when another process
    /// holds that profile's lock.
    @discardableResult
    func prepare(stateURL: URL, isDemo: Bool) async -> Bool {
        let manager = ProfileManager(dataFolder: stateURL.deletingLastPathComponent(), isDemo: isDemo)
        self.manager = manager
        installMenus()
        guard await manager.start() else { return false }
        DispatchQueue.main.async { LaunchMetrics.firstBoardVisible() }
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        for session in manager?.sessions.values.filter({ $0.store.isLoaded }) ?? [] {
            let store = session.store
            Task {
                _ = await store.flush()
                await store.refresh()
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard let session = manager?.activeSession, session.board != nil else { return false }
        session.showBoard()
        return true
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
        guard store?.isLoaded == true else { return .terminateNow }
        store.isTerminating = true
        let finalSave = store.terminationSave()
        Task.detached { [weak self] in
            let saved = await finalSave.value
            // AppKit waits in a nested run loop during termination; a main-queue Task
            // can be blocked there. Deliver the reply as a run-loop source instead.
            RunLoop.main.perform(inModes: [.common]) {
                MainActor.assumeIsolated {
                    guard let self else {
                        NSApp.reply(toApplicationShouldTerminate: saved)
                        return
                    }
                    if saved {
                        NSApp.reply(toApplicationShouldTerminate: true)
                    } else {
                        let alert = NSAlert()
                        alert.messageText = "Some changes could not be saved"
                        alert.informativeText =
                            "Keep Stow open to preserve notes currently in memory, or quit without saving those changes."
                        alert.addButton(withTitle: "Keep open")
                        alert.addButton(withTitle: "Quit without saving")
                        let quit = alert.runModal() == .alertSecondButtonReturn
                        self.store.isTerminating = quit
                        NSApp.reply(toApplicationShouldTerminate: quit)
                    }
                }
            }
        }
        return .terminateLater
    }

    /// Passes a window move to the profile that owns the window, which records its frame.
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
        let main = NSMenu()
        let app = NSMenu()
        app.addItem(
            withTitle: "About Stow", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: "")
        app.addItem(.separator())
        item("Settings…", #selector(showSettings), ",", in: app)
        app.addItem(.separator())
        app.addItem(withTitle: "Hide Stow", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Stow", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem()
        appItem.submenu = app
        main.addItem(appItem)
        let file = NSMenu(title: "File")
        item("New note", #selector(newNote), "n", in: file)
        item("Refresh GitHub", #selector(refresh), "r", in: file)
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
        item("Show board", #selector(showBoard), "0", in: windows)
        windows.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        main.addItem(withTitle: "Window", action: nil, keyEquivalent: "").submenu = windows
        NSApp.mainMenu = main
        NSApp.windowsMenu = windows
    }

    private func item(_ title: String, _ action: Selector, _ key: String, in menu: NSMenu) {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        item.target = self
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
