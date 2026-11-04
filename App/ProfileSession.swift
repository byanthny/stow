import AppKit
import StowCore
import StowGitHub
import SwiftUI

/// One open profile: its lock, store, and windows. Nothing here reads another profile's state.
@MainActor
final class ProfileSession: NSObject, NSWindowDelegate {
    let entry: ProfileEntry
    let store: AppStore
    private(set) var board: StowPanel!
    private(set) var noteWindows: [UUID: StowPanel] = [:]
    var settingsWindow: NSWindow?
    /// Whether the profile's windows are ordered out while it stays open.
    private(set) var isHidden = false
    /// Set when the session closes or stops. Its windows are gone and its store never saves again; the lock goes
    /// once a closing profile's final save is done.
    private(set) var isStopped = false
    /// Window titles carry the profile name once names show, so the Window menu, Mission Control, and VoiceOver
    /// can tell profiles apart. Otherwise they read "Stow", "Stow note", and "Stow settings".
    var showsName = false {
        didSet { if showsName != oldValue { applyTitles() } }
    }
    /// Called when one of the profile's windows becomes key.
    var onActivate: (() -> Void)?
    /// Held while the profile is open; another writer of this folder would revert its changes.
    private var lock: StateLock?
    private var isRestoring = false
    /// The windows `hide()` ordered out, ordered back in by `show()`.
    private var hiddenWindows: [NSWindow] = []

    /// Takes the profile's `.stow.lock`, or returns nil when another holder has it. Callers check their own open
    /// sessions first, because a second lock on the same file fails even within one process.
    init?(entry: ProfileEntry, isDemo: Bool, githubClient: (any GitHubClient)? = nil) {
        let stateURL = entry.folder.appendingPathComponent("state.json")
        switch StateLock.acquire(forStateAt: stateURL) {
        case .acquired(let held): lock = held
        // A folder that cannot be locked, such as one on a volume without flock, is written unguarded.
        case .unavailable: break
        case .heldByAnotherProcess: return nil
        }
        self.entry = entry
        store = AppStore(stateURL: stateURL, isDemo: isDemo, githubClient: githubClient, arrival: entry.isArrival)
        super.init()
        store.onDetach = { [weak self] id in self?.showNote(id) }
        store.onDelete = { [weak self] id in self?.noteWindows.removeValue(forKey: id)?.orderOut(nil) }
        store.onShowBoard = { [weak self] in self?.showBoard() }
        store.onAppearanceChange = { [weak self] in self?.applyWindowAppearance() }
        store.onBoardLevelChange = { [weak self] in self?.applyBoardLevel() }
        store.onRestoreWindows = { [weak self] in self?.restoreWindows() }
    }

    /// Loads the profile, then shows its board and the notes that were detached.
    func start() async {
        await store.start()
        // A session stopped while its store loaded opens no windows.
        guard !isStopped else { return }
        isRestoring = true
        createBoard()
        for note in store.state.notes where note.isDetached { showNote(note.id) }
        isRestoring = false
        applyWindowAppearance()
        showBoard()
    }

    /// Closes the profile with a final save: stops the store and closes the windows, then waits for a save still
    /// running, writes the last state, and releases the lock, so nothing writes after the release. Detached notes
    /// stay detached, so they reopen with the profile. Callers flush first, so a failed save can keep it open.
    func close() async {
        shutDown()
        _ = await store.saveAndClose()
        releaseLock()
    }

    /// Stops at once, without a final save and without waiting for a save already running, then releases the
    /// lock. Closing a profile goes through `close()`; this is for teardown.
    func stop() {
        shutDown()
        releaseLock()
    }

    private func shutDown() {
        guard !isStopped else { return }
        isStopped = true
        hiddenWindows.removeAll()
        store.stop()
        closeBoardAndNotes()
        board = nil
        settingsWindow?.delegate = nil
        settingsWindow?.close()
        settingsWindow = nil
    }

    private func releaseLock() {
        lock?.release()
        lock = nil
    }

    func owns(_ window: NSWindow) -> Bool {
        ownWindows.contains { $0 === window }
    }

    /// Orders out the profile's windows without minimizing them, and pauses its GitHub refreshes and accessories.
    /// Always-on-top notes stay on screen when the profile keeps them while hidden.
    func hide() {
        guard board != nil, !isHidden else { return }
        isHidden = true
        store.isPaused = true
        let keepsFloatingNotes = store.state.hideKeepsAlwaysOnTopNotes
        hiddenWindows = ownWindows.filter { window in
            guard window.isVisible else { return false }
            if keepsFloatingNotes, let id = (window as? StowPanel)?.noteID, store.note(id)?.isAlwaysOnTop == true {
                return false
            }
            return true
        }
        for window in hiddenWindows { window.orderOut(nil) }
    }

    /// Brings the profile's windows forward and makes its board key. A hidden profile first gets back the
    /// windows it hid, with their frames and levels, and refreshes.
    func show() {
        guard let board else { return }
        reveal()
        for window in ownWindows where window !== board && window.isVisible { window.orderFront(nil) }
        showBoard()
    }

    func showBoard() {
        guard let board else { return }
        reveal()
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
            panel = makePanel(frame: frame, title: title("note"))
            panel.noteID = id
            panel.minSize = NSSize(width: 260, height: 208)
            panel.contentView = describedHost(
                NoteView(store: store, noteID: id, detached: true).themed(by: store.theme), label: "Note")
            noteWindows[id] = panel
        }
        panel.level = note.isAlwaysOnTop ? .floating : .normal
        panel.makeKeyAndOrderFront(nil)
        if !isRestoring { NSApp.activate(ignoringOtherApps: true) }
    }

    func showSettings() {
        guard !isStopped else { return }
        reveal()
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 690), styleMask: [.titled, .closable],
                backing: .buffered, defer: false)
            window.title = title("settings")
            window.isReleasedWhenClosed = false
            // Reopening Settings brings it to the current desktop instead of switching to its last one.
            window.collectionBehavior = [.moveToActiveSpace]
            window.contentView = describedHost(SettingsView(store: store).themed(by: store.theme), label: "Settings")
            window.center()
            window.delegate = self
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowDidBecomeKey(_ notification: Notification) { onActivate?() }

    func windowWillClose(_ notification: Notification) {
        guard let panel = notification.object as? StowPanel, let id = panel.noteID else { return }
        store.closeDetachedNote(id)
        noteWindows[id] = nil
    }

    func windowDidMove(_ notification: Notification) { recordFrame(notification) }
    func windowDidResize(_ notification: Notification) { recordFrame(notification) }
    private func recordFrame(_ notification: Notification) {
        guard !isRestoring, store.isLoaded, let panel = notification.object as? StowPanel else { return }
        let rect = panel.frame
        store.saveFrame(.init(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height), noteID: panel.noteID)
    }

    /// The board, the detached notes, and Settings once it exists.
    private var ownWindows: [NSWindow] {
        var windows: [NSWindow] = board.map { [$0] } ?? []
        windows += noteWindows.values.map { $0 as NSWindow }
        if let settingsWindow { windows.append(settingsWindow) }
        return windows
    }

    /// Orders back in the windows `hide()` ordered out, and resumes the store.
    private func reveal() {
        guard isHidden else { return }
        isHidden = false
        for window in hiddenWindows where owns(window) { window.orderFront(nil) }
        hiddenWindows.removeAll()
        store.isPaused = false
    }

    private func restoreWindows() {
        // A stopped session has no windows to rebuild.
        guard board != nil else { return }
        isRestoring = true
        closeBoardAndNotes()
        createBoard()
        for note in store.state.notes where note.isDetached { showNote(note.id) }
        applyWindowAppearance()
        isRestoring = false
        showBoard()
    }

    /// Closes the board and detached notes without marking the notes closed.
    private func closeBoardAndNotes() {
        for panel in noteWindows.values {
            panel.delegate = nil
            panel.close()
        }
        noteWindows.removeAll()
        board?.delegate = nil
        board?.close()
    }

    private func createBoard() {
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let frame = restoredFrame(
            store.state.boardFrame,
            fallback: NSRect(x: visible.maxX - 404, y: visible.maxY - 744, width: 380, height: 700),
            minimum: NSSize(width: 320, height: 320))
        board = makePanel(frame: frame, title: title())
        applyBoardLevel()
        board.minSize = NSSize(width: 320, height: 348)
        board.contentView = describedHost(
            BoardView(store: store, showSettings: { [weak self] in self?.showSettings() }).themed(by: store.theme),
            label: "Board")
    }

    /// "Stow", or "Stow note" with a suffix, using the profile's name in place of "Stow" once names show.
    private func title(_ suffix: String? = nil) -> String {
        let name = showsName ? entry.name : "Stow"
        return suffix.map { "\(name) \($0)" } ?? name
    }

    private func applyTitles() {
        board?.title = title()
        for panel in noteWindows.values { panel.title = title("note") }
        settingsWindow?.title = title("settings")
    }

    /// SwiftUI leaves the hosting view's accessibility group without a description.
    private func describedHost<Content: View>(_ view: Content, label: String) -> NSHostingView<Content> {
        let host = NSHostingView(rootView: view)
        host.setAccessibilityLabel(label)
        return host
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
        panel.appearance = store.theme.snapshot.appKitAppearance
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
        let appearance = store.theme.snapshot.appKitAppearance
        for panel in [board].compactMap({ $0 }) + Array(noteWindows.values) {
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.appearance = appearance
            panel.contentView?.needsDisplay = true
        }
        settingsWindow?.appearance = appearance
    }
}
