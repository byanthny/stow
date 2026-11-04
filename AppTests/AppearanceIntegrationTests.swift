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

    func testCodeShowsInAFixedWidthFontWithoutChangingTheSource() throws {
        let editor = NSTextView()
        editor.isRichText = false
        let source = "Run `swift test` first.\n\n```sh\n./scripts/build.sh Debug\n```\nThen ship."
        editor.string = source
        let appearance = AppearanceSettings.paper
        NativeEditor.applyAppearance(appearance, to: editor)

        XCTAssertTrue(NativeEditor.styleCode(in: editor, appearance: appearance, wasShowingCode: false))

        let storage = try XCTUnwrap(editor.textStorage)
        let text = storage.string as NSString
        func font(of word: String) -> NSFont? {
            storage.attribute(.font, at: text.range(of: word).location, effectiveRange: nil) as? NSFont
        }
        XCTAssertEqual(font(of: "swift test")?.isFixedPitch, true)
        XCTAssertEqual(font(of: "./scripts")?.isFixedPitch, true)
        XCTAssertEqual(font(of: "Run")?.isFixedPitch, false)
        XCTAssertEqual(font(of: "ship")?.isFixedPitch, false)
        XCTAssertNotNil(storage.attribute(.backgroundColor, at: text.range(of: "swift").location, effectiveRange: nil))
        XCTAssertEqual(editor.string, source)
        XCTAssertNil(editor.typingAttributes[.backgroundColor])

        editor.string = "No code anymore."
        XCTAssertFalse(NativeEditor.styleCode(in: editor, appearance: appearance, wasShowingCode: true))
        XCTAssertNil(storage.attribute(.backgroundColor, at: 0, effectiveRange: nil))
        XCTAssertEqual((storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.isFixedPitch, false)
    }

    func testCodeStylingDoesNotReplaceTypingUndo() throws {
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
        editor.string = "Use "
        editor.setSelectedRange(NSRange(location: 4, length: 0))
        editor.insertText("`code`", replacementRange: editor.selectedRange())
        editor.breakUndoCoalescing()
        let undo = try XCTUnwrap(editor.undoManager)
        XCTAssertTrue(NativeEditor.styleCode(in: editor, appearance: .graphite, wasShowingCode: false))

        undo.undo()

        XCTAssertEqual(editor.string, "Use ")
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
