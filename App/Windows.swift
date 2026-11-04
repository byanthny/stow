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
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private(set) var store: AppStore!
    private(set) var board: StowPanel!
    private(set) var noteWindows: [UUID: StowPanel] = [:]
    private var settingsWindow: NSWindow?
    private var isRestoring = false
    /// Held for the process lifetime; another Stow writing the same state would revert its changes.
    private var stateLock: StateLock?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hosted unit tests construct their own app delegate with temporary state.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return }
        var stateURL = StateRepository.defaultURL
        var demo = false
        #if DEBUG
            var hasIsolatedState = false
            let arguments = ProcessInfo.processInfo.arguments
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
        switch StateLock.acquire(forStateAt: stateURL) {
        case .acquired(let lock): stateLock = lock
        case .unavailable: break
        case .heldByAnotherProcess:
            // Another Stow already writes this state. Hand over to it instead of competing.
            Self.activateRunningCopy()
            NSApp.terminate(nil)
            return
        }
        Task {
            await prepare(stateURL: stateURL, isDemo: demo)
            #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--stow-smoke-test") {
                    await runSmokeTest()
                    return
                }
            #endif
            await store.refresh()
        }
    }

    func prepare(stateURL: URL, isDemo: Bool) async {
        store = AppStore(stateURL: stateURL, isDemo: isDemo)
        store.onDetach = { [weak self] id in self?.showNote(id) }
        store.onDelete = { [weak self] id in self?.noteWindows.removeValue(forKey: id)?.orderOut(nil) }
        store.onShowBoard = { [weak self] in self?.showBoard() }
        store.onAppearanceChange = { [weak self] in self?.applyWindowAppearance() }
        store.onBoardLevelChange = { [weak self] in self?.applyBoardLevel() }
        store.onRestoreWindows = { [weak self] in self?.restoreWindows() }
        installMenus()
        await store.start()
        isRestoring = true
        createBoard()
        for note in store.state.notes where note.isDetached { showNote(note.id) }
        isRestoring = false
        applyWindowAppearance()
        showBoard()
        DispatchQueue.main.async { LaunchMetrics.firstBoardVisible() }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard store?.isLoaded == true else { return }
        Task {
            _ = await store.flush()
            await store.refresh()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard board != nil else { return false }
        showBoard()
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

    private func restoreWindows() {
        isRestoring = true
        for panel in noteWindows.values {
            panel.delegate = nil
            panel.close()
        }
        noteWindows.removeAll()
        board.delegate = nil
        board.close()
        createBoard()
        for note in store.state.notes where note.isDetached { showNote(note.id) }
        applyWindowAppearance()
        isRestoring = false
        showBoard()
    }

    private func createBoard() {
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let frame = restoredFrame(
            store.state.boardFrame,
            fallback: NSRect(x: visible.maxX - 404, y: visible.maxY - 744, width: 380, height: 700),
            minimum: NSSize(width: 320, height: 320))
        board = makePanel(frame: frame, title: "Stow")
        applyBoardLevel()
        board.minSize = NSSize(width: 320, height: 348)
        board.contentView = NSHostingView(
            rootView: BoardView(store: store, showSettings: { [weak self] in self?.showSettings() }))
    }

    private func makePanel(frame: NSRect, title: String) -> StowPanel {
        let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
        let content = NSWindow.contentRect(forFrameRect: frame, styleMask: style)
        let panel = StowPanel(contentRect: content, styleMask: style, backing: .buffered, defer: false)
        panel.title = title
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.appearance = NSAppearance(named: ThemeController.shared.colorScheme == .dark ? .darkAqua : .aqua)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.level = .floating
        // Follow every desktop, but stay out of other apps' full-screen spaces by design.
        panel.collectionBehavior = [.canJoinAllSpaces]
        panel.delegate = self
        panel.onPaste = { [weak self] text in self?.store.pasteOutsideEditor(text) }
        return panel
    }

    private func applyBoardLevel() {
        board?.level = store.state.boardAlwaysOnTop ? .floating : .normal
    }

    private func applyWindowAppearance() {
        let appearance = NSAppearance(named: ThemeController.shared.colorScheme == .dark ? .darkAqua : .aqua)
        for panel in [board].compactMap({ $0 }) + Array(noteWindows.values) {
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.appearance = appearance
            panel.contentView?.needsDisplay = true
        }
        settingsWindow?.appearance = appearance
    }

    @objc func showBoard() {
        guard board != nil else { return }
        board.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func showNote(_ id: UUID) {
        guard let note = store.note(id) else { return }
        let panel: StowPanel
        if let existing = noteWindows[id] {
            panel = existing
        } else {
            let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
            let offset = CGFloat(noteWindows.count % 8) * 24
            let frame = restoredFrame(
                note.frame,
                fallback: NSRect(x: screen.midX - 170 + offset, y: screen.midY - 190 - offset, width: 340, height: 380),
                minimum: NSSize(width: 260, height: 180))
            panel = makePanel(frame: frame, title: "Stow note")
            panel.noteID = id
            panel.minSize = NSSize(width: 260, height: 208)
            panel.contentView = NSHostingView(rootView: NoteView(store: store, noteID: id, detached: true))
            noteWindows[id] = panel
        }
        panel.level = note.isAlwaysOnTop ? .floating : .normal
        panel.makeKeyAndOrderFront(nil)
        if !isRestoring { NSApp.activate(ignoringOtherApps: true) }
    }

    func windowWillClose(_ notification: Notification) {
        guard let panel = notification.object as? StowPanel else { return }
        if let id = panel.noteID {
            store.closeDetachedNote(id)
            noteWindows[id] = nil
        }
    }

    func windowDidMove(_ notification: Notification) { recordFrame(notification) }
    func windowDidResize(_ notification: Notification) { recordFrame(notification) }
    private func recordFrame(_ notification: Notification) {
        guard !isRestoring, store?.isLoaded == true, let panel = notification.object as? StowPanel else { return }
        let rect = panel.frame
        store.saveFrame(.init(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height), noteID: panel.noteID)
    }

    @objc func newNote() {
        showBoard()
        store.addNote()
    }
    @objc func refresh() { Task { await store.refresh() } }
    @objc func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 690), styleMask: [.titled, .closable],
                backing: .buffered, defer: false)
            window.title = "Stow settings"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(store: store))
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

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
