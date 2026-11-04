import AppKit
import StowCore
import XCTest

@testable import Stow

@MainActor
final class AppearanceIntegrationTests: XCTestCase {
    func testNativeEditorAppearancePreservesSourceAndSelection() throws {
        let editor = NSTextView()
        editor.isRichText = false
        editor.string = "# Synthetic note\nKeep this **Markdown** source."
        let original = editor.string
        let selection = NSRange(location: 17, length: 9)
        editor.setSelectedRange(selection)
        var appearance = AppearanceSettings.paper
        appearance.editorFontName = "Unavailable-Synthetic-Font"
        appearance.editorFontSize = 19
        appearance.editorLineHeight = 1.7

        NativeEditor.applyAppearance(appearance, to: editor)

        XCTAssertEqual(editor.string, original)
        XCTAssertEqual(editor.selectedRange(), selection)
        XCTAssertEqual(editor.font?.pointSize, 19)
        XCTAssertEqual(editor.font?.fontName, NSFont.systemFont(ofSize: 19).fontName)
        let paragraph = try XCTUnwrap(editor.defaultParagraphStyle)
        XCTAssertEqual(paragraph.lineHeightMultiple, 1.7, accuracy: 0.001)
        XCTAssertEqual(editor.insertionPointColor, editor.textColor)
    }

    func testAppearanceDoesNotReplaceTypingUndo() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let editor = NSTextView(frame: window.contentView?.bounds ?? .zero)
        editor.isRichText = false
        editor.allowsUndo = true
        window.contentView = editor
        window.makeFirstResponder(editor)
        editor.string = "Synthetic"
        editor.setSelectedRange(NSRange(location: 9, length: 0))
        editor.insertText(" note", replacementRange: editor.selectedRange())
        editor.breakUndoCoalescing()
        let undo = try XCTUnwrap(editor.undoManager)
        XCTAssertTrue(undo.canUndo)
        var appearance = AppearanceSettings.graphite
        appearance.editorFontSize = 18
        NativeEditor.applyAppearance(appearance, to: editor)
        XCTAssertEqual(editor.string, "Synthetic note")

        undo.undo()

        XCTAssertEqual(editor.string, "Synthetic")
    }

    func testThemesDoNotBleedBetweenStores() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = AppStore(stateURL: root.appendingPathComponent("a/state.json"))
        let b = AppStore(stateURL: root.appendingPathComponent("b/state.json"))
        var dark = AppearanceSettings.default
        dark.colorScheme = .dark
        var light = AppearanceSettings.default
        light.colorScheme = .light

        XCTAssertTrue(a.applyAppearance(dark))
        XCTAssertTrue(b.applyAppearance(light))

        XCTAssertEqual(a.theme.snapshot.colorScheme, .dark)
        XCTAssertEqual(b.theme.snapshot.colorScheme, .light)
        XCTAssertNotEqual(a.theme.snapshot, b.theme.snapshot)
    }
}
