import AppKit
import Foundation
import StowCore
import SwiftUI
import XCTest

@testable import Stow

/// Hosted AppKit/SwiftUI integration with temporary synthetic state, not desktop UI automation.
@MainActor
final class SectionsAndAppearanceTests: XCTestCase {
    func testClickingNotesStartsANoteThatStaysOnlyOnceTyped() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = try await prepare(directory)
        defer { dispose(app) }
        let store = try XCTUnwrap(app.store)
        let seed = try XCTUnwrap(store.state.notes.first)
        let count = store.state.notes.count

        // A started note is open, focused, and empty; folding it away without typing removes it.
        let first = store.startNote()
        XCTAssertEqual(store.draftNoteID, first)
        XCTAssertEqual(store.state.notes.count, count + 1)
        XCTAssertTrue(store.isNoteExpanded(first))
        XCTAssertEqual(store.focusNoteID, first)
        store.toggleNoteExpanded(first)
        XCTAssertNil(store.note(first))
        XCTAssertNil(store.draftNoteID)
        XCTAssertEqual(store.state.notes.count, count)

        // Opening another note, or making a new one with the + button, also drops an empty started note.
        let second = store.startNote()
        store.toggleNoteExpanded(seed.id)
        XCTAssertNil(store.note(second))
        XCTAssertTrue(store.isNoteExpanded(seed.id))
        let third = store.startNote()
        let added = store.addNote()
        XCTAssertNil(store.note(third))
        XCTAssertNotNil(store.note(added))
        XCTAssertNil(store.draftNoteID, "A note made with the + button is not a started note")

        // Typing keeps a started note, even after it folds away, and it is saved like any other.
        let typed = store.startNote()
        store.editNote(typed, markdown: "Typed straight into the Notes area")
        XCTAssertNil(store.draftNoteID)
        store.toggleNoteExpanded(typed)
        XCTAssertEqual(store.note(typed)?.markdown, "Typed straight into the Notes area")
        let saved = await store.flush()
        XCTAssertTrue(saved)
        let persisted = try await StateRepository(url: stateURL(directory)).load()
        XCTAssertEqual(persisted.notes.first { $0.id == typed }?.markdown, "Typed straight into the Notes area")
        XCTAssertNil(persisted.notes.first { $0.id == first })
    }

    func testBoardHeaderSharesTheTitleBarWithTheWindowButtons() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = try await prepare(directory)
        defer { dispose(app) }
        let board = try XCTUnwrap(app.board)
        let store = try XCTUnwrap(app.store)
        XCTAssertTrue(board.styleMask.contains(.fullSizeContentView))
        XCTAssertTrue(board.titlebarAppearsTransparent)
        let chrome = WindowChrome(window: board)
        XCTAssertGreaterThan(chrome.titlebarHeight, 0)
        let zoom = try XCTUnwrap(board.standardWindowButton(.zoomButton))
        XCTAssertGreaterThan(chrome.leadingInset, zoom.frame.maxX, "The header starts after the window buttons")

        // The header's draggable background marks out its row: the window's top edge, as tall as the title bar,
        // with the window buttons inside it rather than in a strip above the header.
        let row = await headerRow(in: board)
        XCTAssertEqual(row.height, chrome.titlebarHeight, accuracy: 0.5)
        let buttons = zoom.convert(zoom.bounds, to: nil)
        XCTAssertTrue(row.contains(NSPoint(x: buttons.midX, y: buttons.midY)))

        // A click in that row still reaches the header's buttons: + is second from the trailing edge, after
        // the 15-point margin, the 22-point Settings button, and 7 points of spacing.
        let point = NSPoint(x: row.maxX - 15 - 22 - 7 - 11, y: row.midY)
        let count = store.state.notes.count
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(
                NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: board.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                    pressure: type == .leftMouseDown ? 1 : 0))
            board.sendEvent(event)
        }
        let clicked = await waitUntil { store.state.notes.count == count + 1 }
        XCTAssertTrue(clicked, "The header's New note button took the click")

        // A detached note's header shares its title bar row the same way.
        let note = try XCTUnwrap(store.state.notes.first)
        store.detachNote(note.id)
        let panel = try XCTUnwrap(app.noteWindows[note.id])
        let noteRow = await headerRow(in: panel)
        XCTAssertEqual(noteRow.height, WindowChrome(window: panel).titlebarHeight, accuracy: 0.5)
    }

    /// A panel's header row in window coordinates, once it reaches the window's top edge.
    private func headerRow(in panel: NSWindow) async -> NSRect {
        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        var row = NSRect.zero
        let placed = await waitUntil {
            guard let content = panel.contentView else { return false }
            content.layoutSubtreeIfNeeded()
            guard let drag = views(content).first(where: { $0 is WindowDragArea.DragView }) else { return false }
            row = drag.convert(drag.bounds, to: nil)
            return abs(row.maxY - panel.frame.height) < 0.5
        }
        XCTAssertTrue(placed, "Header row \(row) in a window \(panel.frame.size)")
        return row
    }

    func testSectionsDefaultOpenPersistAndExpandForNewOrFocusedNotes() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = try await prepare(directory)
        defer { dispose(app) }
        let sectionIDs = [AttentionSection.needsYou.rawValue, AttentionSection.waiting.rawValue, "notes"]
        XCTAssertTrue(app.store.state.collapsedSections.isEmpty)
        for section in sectionIDs { XCTAssertFalse(app.store.sectionIsCollapsed(section)) }
        let originalNotes = app.store.state.notes
        for section in sectionIDs { app.store.toggleSection(section) }
        XCTAssertEqual(
            app.store.state.notes, originalNotes, "Collapsing sections must preserve note content and metadata")
        for section in sectionIDs { XCTAssertTrue(app.store.sectionIsCollapsed(section)) }
        let saved = await app.store.flush()
        XCTAssertTrue(saved)
        dispose(app)

        let restored = try await prepare(directory)
        defer { dispose(restored) }
        XCTAssertEqual(restored.store.state.notes, originalNotes)
        for section in sectionIDs { XCTAssertTrue(restored.store.sectionIsCollapsed(section)) }
        let newID = restored.store.addNote("New synthetic note opens the notes section")
        XCTAssertFalse(restored.store.sectionIsCollapsed("notes"))
        XCTAssertEqual(restored.store.focusNoteID, newID)
        XCTAssertTrue(restored.store.sectionIsCollapsed(AttentionSection.waiting.rawValue))
        restored.store.toggleSection("notes")
        XCTAssertTrue(restored.store.sectionIsCollapsed("notes"))
        let notesBeforeFocus = restored.store.state.notes
        restored.store.requestFocus(newID)
        XCTAssertFalse(restored.store.sectionIsCollapsed("notes"))
        XCTAssertEqual(restored.store.state.notes, notesBeforeFocus)
        let savedExpanded = await restored.store.flush()
        XCTAssertTrue(savedExpanded)
        let persisted = try await StateRepository(url: stateURL(directory)).load()
        XCTAssertFalse(persisted.collapsedSections.contains("notes"))
        XCTAssertTrue(persisted.collapsedSections.contains(AttentionSection.waiting.rawValue))
        XCTAssertEqual(persisted.notes.first { $0.id == newID }?.markdown, "New synthetic note opens the notes section")
    }

    func testAppearancePersistsAndRestoresThemeControllerAndWindowScheme() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = try await prepare(directory)
        defer { dispose(app) }
        var appearance = AppearanceSettings.paper
        appearance.name = "Synthetic custom appearance"
        appearance.backgroundOpacity = 0.45
        appearance.interfaceFontSize = 15
        appearance.editorFontSize = 18
        appearance.editorLineHeight = 1.6
        appearance.interfaceFontName = availableMonospaceFontName()
        appearance.editorFontName = availableMonospaceFontName()
        appearance.colors.background = "#E4E8EC"
        appearance.colors.text = "#18202A"
        XCTAssertTrue(app.store.applyAppearance(appearance))
        XCTAssertEqual(app.store.state.appearance, appearance)
        XCTAssertEqual(app.store.theme.settings, appearance)
        let saved = await app.store.flush()
        XCTAssertTrue(saved)
        let persisted = try await StateRepository(url: stateURL(directory)).load()
        XCTAssertEqual(persisted.appearance, appearance)
        dispose(app)

        let restored = try await prepare(directory)
        defer { dispose(restored) }
        XCTAssertEqual(restored.store.state.appearance, appearance)
        XCTAssertEqual(restored.store.theme.settings, appearance)
        XCTAssertEqual(restored.store.theme.snapshot.colorScheme, .light)
        XCTAssertEqual(restored.board.appearance?.name, .aqua)
    }

    func testChangingEditorFontAndLineHeightPreservesMarkdownSelectionAndEditorIdentity() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = try await prepare(directory)
        defer { dispose(app) }
        let note = try XCTUnwrap(app.store.state.notes.first)
        app.store.detachNote(note.id)
        let panel = try XCTUnwrap(app.noteWindows[note.id])
        let ready = await waitUntil {
            panel.contentView?.layoutSubtreeIfNeeded()
            return self.textViews(in: panel.contentView).count == 1
        }
        XCTAssertTrue(ready)
        let editor = try XCTUnwrap(textViews(in: panel.contentView).first)
        XCTAssertTrue(panel.makeFirstResponder(editor))
        let selection = NSRange(location: 2, length: 7)
        editor.setSelectedRange(selection)
        let markdown = editor.string
        let originalNote = app.store.note(note.id)
        var appearance = app.store.state.appearance
        appearance.editorFontName = availableMonospaceFontName()
        appearance.editorFontSize = 19
        appearance.editorLineHeight = 1.8
        appearance.colors.text = "#DDEEFF"
        XCTAssertTrue(app.store.applyAppearance(appearance))
        // The first line shows as a larger title, so the note's own font is the one typing uses.
        let updated = await waitUntil {
            panel.contentView?.layoutSubtreeIfNeeded()
            return (editor.typingAttributes[.font] as? NSFont)?.pointSize == 19
                && editor.defaultParagraphStyle?.lineHeightMultiple == 1.8
        }
        XCTAssertTrue(updated)
        XCTAssertTrue(textViews(in: panel.contentView).first === editor)
        XCTAssertEqual(editor.string, markdown)
        XCTAssertEqual(editor.selectedRange(), selection)
        XCTAssertEqual(app.store.note(note.id), originalNote)
        if let name = appearance.editorFontName, let expected = NSFont(name: name, size: 19) {
            XCTAssertEqual((editor.typingAttributes[.font] as? NSFont)?.fontName, expected.fontName)
        }
        XCTAssertEqual(editor.textColor?.alphaComponent ?? 0, 1, accuracy: 0.001)
    }

    func testBackgroundOpacityLeavesWindowAndTextFullyOpaque() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = try await prepare(directory)
        defer { dispose(app) }
        let note = try XCTUnwrap(app.store.state.notes.first)
        app.store.detachNote(note.id)
        let panel = try XCTUnwrap(app.noteWindows[note.id])
        var appearance = app.store.state.appearance
        appearance.backgroundOpacity = 0.25
        XCTAssertTrue(app.store.applyAppearance(appearance))
        let ready = await waitUntil {
            panel.contentView?.layoutSubtreeIfNeeded()
            return !self.textViews(in: panel.contentView).isEmpty
        }
        XCTAssertTrue(ready)
        let editor = try XCTUnwrap(textViews(in: panel.contentView).first)
        for window in [app.board!, panel] {
            XCTAssertEqual(window.alphaValue, 1, accuracy: 0.001)
            XCTAssertFalse(window.isOpaque)
            XCTAssertEqual(window.backgroundColor?.alphaComponent ?? 1, 0, accuracy: 0.001)
            XCTAssertEqual(window.contentView?.alphaValue ?? 0, 1, accuracy: 0.001)
        }
        let expectedBackgroundOpacity = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency ? 1.0 : 0.25
        XCTAssertEqual(app.store.theme.snapshot.effectiveBackgroundOpacity, expectedBackgroundOpacity, accuracy: 0.001)
        XCTAssertEqual(NSColor(app.store.theme.snapshot.color(.background)).alphaComponent, expectedBackgroundOpacity, accuracy: 0.001)
        XCTAssertEqual(NSColor(app.store.theme.snapshot.color(.note)).alphaComponent, expectedBackgroundOpacity, accuracy: 0.001)
        XCTAssertEqual(NSColor(app.store.theme.snapshot.color(.surface)).alphaComponent, expectedBackgroundOpacity, accuracy: 0.001)
        XCTAssertEqual(NSColor(app.store.theme.snapshot.color(.text)).alphaComponent, 1, accuracy: 0.001)
        XCTAssertEqual(editor.textColor?.alphaComponent ?? 0, 1, accuracy: 0.001)
        XCTAssertEqual(editor.insertionPointColor.alphaComponent, 1, accuracy: 0.001)
        XCTAssertEqual(editor.alphaValue, 1, accuracy: 0.001)
    }

    private func availableMonospaceFontName() -> String? {
        NSFont(name: "Menlo-Regular", size: 13)?.fontName
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "StowAppearanceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func stateURL(_ directory: URL) -> URL { directory.appendingPathComponent("state.json") }

    private func prepare(_ directory: URL) async throws -> AppDelegate {
        let url = stateURL(directory)
        if !FileManager.default.fileExists(atPath: url.path) {
            var initial = AppState()
            initial.githubEnabled = false
            initial.notes = [Note(markdown: "# Synthetic note\n\n**Selection** and Markdown stay intact.")]
            try await StateRepository(url: url).save(initial)
        }
        let app = AppDelegate()
        await app.prepare(stateURL: url, isDemo: true)
        return app
    }

    private func dispose(_ app: AppDelegate) {
        guard let manager = app.manager else { return }
        for session in manager.sessions.values { session.stop() }
    }

    private func textViews(in root: NSView?) -> [NSTextView] {
        guard let root else { return [] }
        return (root as? NSTextView).map { [$0] } ?? root.subviews.flatMap { textViews(in: $0) }
    }

    private func waitUntil(_ predicate: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<50 {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return predicate()
    }
}
