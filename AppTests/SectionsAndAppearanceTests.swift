import AppKit
import Foundation
import StowCore
import SwiftUI
import XCTest

@testable import Stow

/// Hosted AppKit/SwiftUI integration with temporary synthetic state, not desktop UI automation.
@MainActor
final class SectionsAndAppearanceTests: XCTestCase {
    func testSectionsDefaultOpenPersistAndExpandForNewOrFocusedNotes() async throws {
        let previousTheme = ThemeController.shared.settings
        defer { ThemeController.shared.apply(previousTheme) }
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
        let previousTheme = ThemeController.shared.settings
        defer { ThemeController.shared.apply(previousTheme) }
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
        XCTAssertEqual(ThemeController.shared.settings, appearance)
        let saved = await app.store.flush()
        XCTAssertTrue(saved)
        let persisted = try await StateRepository(url: stateURL(directory)).load()
        XCTAssertEqual(persisted.appearance, appearance)
        dispose(app)
        ThemeController.shared.apply(.default)

        let restored = try await prepare(directory)
        defer { dispose(restored) }
        XCTAssertEqual(restored.store.state.appearance, appearance)
        XCTAssertEqual(ThemeController.shared.settings, appearance)
        XCTAssertEqual(ThemeController.shared.colorScheme, .light)
        XCTAssertEqual(restored.board.appearance?.name, .aqua)
    }

    func testChangingEditorFontAndLineHeightPreservesMarkdownSelectionAndEditorIdentity() async throws {
        let previousTheme = ThemeController.shared.settings
        defer { ThemeController.shared.apply(previousTheme) }
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
        let updated = await waitUntil {
            panel.contentView?.layoutSubtreeIfNeeded()
            return editor.font?.pointSize == 19 && editor.defaultParagraphStyle?.lineHeightMultiple == 1.8
        }
        XCTAssertTrue(updated)
        XCTAssertTrue(textViews(in: panel.contentView).first === editor)
        XCTAssertEqual(editor.string, markdown)
        XCTAssertEqual(editor.selectedRange(), selection)
        XCTAssertEqual(app.store.note(note.id), originalNote)
        if let name = appearance.editorFontName, let expected = NSFont(name: name, size: 19) {
            XCTAssertEqual(editor.font?.fontName, expected.fontName)
        }
        XCTAssertEqual(editor.textColor?.alphaComponent ?? 0, 1, accuracy: 0.001)
    }

    func testBackgroundOpacityLeavesWindowAndTextFullyOpaque() async throws {
        let previousTheme = ThemeController.shared.settings
        defer { ThemeController.shared.apply(previousTheme) }
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
        XCTAssertEqual(ThemeController.shared.effectiveBackgroundOpacity, expectedBackgroundOpacity, accuracy: 0.001)
        XCTAssertEqual(NSColor(Color.stowBackground).alphaComponent, expectedBackgroundOpacity, accuracy: 0.001)
        XCTAssertEqual(NSColor(Color.stowNote).alphaComponent, expectedBackgroundOpacity, accuracy: 0.001)
        XCTAssertEqual(NSColor(Color.stowSurface).alphaComponent, expectedBackgroundOpacity, accuracy: 0.001)
        XCTAssertEqual(NSColor(Color.stowText).alphaComponent, 1, accuracy: 0.001)
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
        app.store?.isTerminating = true
        for panel in app.noteWindows.values {
            panel.delegate = nil
            panel.close()
        }
        app.board?.delegate = nil
        app.board?.close()
        app.store?.stop()
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
