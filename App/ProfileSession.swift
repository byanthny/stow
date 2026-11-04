import AppKit
import StowCore
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
    /// Held while the profile is open; another writer of this folder would revert its changes.
    private var lock: StateLock?
    private var isRestoring = false

    /// Takes the profile's `.stow.lock`, or returns nil when another holder has it. Callers check their own open
    /// sessions first, because a second lock on the same file fails even within one process.
    init?(entry: ProfileEntry, isDemo: Bool) {
        let stateURL = entry.folder.appendingPathComponent("state.json")
        switch StateLock.acquire(forStateAt: stateURL) {
        case .acquired(let held): lock = held
        // A folder that cannot be locked, such as one on a volume without flock, is written unguarded.
        case .unavailable: break
        case .heldByAnotherProcess: return nil
        }
        self.entry = entry
        store = AppStore(stateURL: stateURL, isDemo: isDemo)
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
        isRestoring = true
        createBoard()
        for note in store.state.notes where note.isDetached { showNote(note.id) }
        isRestoring = false
        applyWindowAppearance()
        showBoard()
    }

    /// Stops the store, closes the windows, and releases the lock, without a final save: flush first to keep the
    /// last edit. Detached notes stay detached, so they reopen with the profile.
    func stop() {
        store.stop()
        for panel in noteWindows.values {
            panel.delegate = nil
            panel.close()
        }
        noteWindows.removeAll()
        board?.delegate = nil
        board?.close()
        board = nil
        settingsWindow?.close()
        settingsWindow = nil
        lock?.release()
        lock = nil
    }

    func owns(_ window: NSWindow) -> Bool {
        window === board || window === settingsWindow || noteWindows.values.contains { $0 === window }
    }

    func showBoard() {
        guard let board else { return }
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
            panel.contentView = NSHostingView(
                rootView: NoteView(store: store, noteID: id, detached: true).themed(by: store.theme))
            noteWindows[id] = panel
        }
        panel.level = note.isAlwaysOnTop ? .floating : .normal
        panel.makeKeyAndOrderFront(nil)
        if !isRestoring { NSApp.activate(ignoringOtherApps: true) }
    }

    func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 690), styleMask: [.titled, .closable],
                backing: .buffered, defer: false)
            window.title = "Stow settings"
            window.isReleasedWhenClosed = false
            // Reopening Settings brings it to the current desktop instead of switching to its last one.
            window.collectionBehavior = [.moveToActiveSpace]
            window.contentView = NSHostingView(rootView: SettingsView(store: store).themed(by: store.theme))
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

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

    private func restoreWindows() {
        // A stopped session has no windows to rebuild.
        guard let board else { return }
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
            rootView: BoardView(store: store, showSettings: { [weak self] in self?.showSettings() })
                .themed(by: store.theme))
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
