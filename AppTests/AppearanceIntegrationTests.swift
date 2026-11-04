import AppKit
import StowCore
import SwiftUI
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

    func testPullDownMenuItemsRunTheirActions() throws {
        var chosen: [String] = []
        let menu = PullDownMenu(
            title: "Synthetic",
            sections: [
                [.init(title: "First") { chosen.append("first") }],
                [.init(title: "Second") { chosen.append("second") }],
            ],
            label: "Synthetic menu")
        let (window, buttons) = hostPullDowns(menu)
        defer { window.close() }
        let button = try XCTUnwrap(buttons.first)
        let second = try XCTUnwrap(button.menu?.items.firstIndex { $0.title == "Second" })

        button.menu?.performActionForItem(at: second)

        XCTAssertEqual(chosen, ["second"])
    }

    func testThemePresetMenuSwitchesThemeAndKeepsFonts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(stateURL: root.appendingPathComponent("state.json"))
        var custom = AppearanceSettings.default
        custom.editorFontName = "Synthetic-Note-Font"
        XCTAssertTrue(store.applyAppearance(custom))
        let (window, buttons) = hostPullDowns(AppearanceView(store: store).themed(by: store.theme))
        defer { window.close() }
        let presets = try XCTUnwrap(buttons.first { $0.accessibilityLabel() == "Theme preset" })
        let graphite = try XCTUnwrap(presets.menu?.items.firstIndex { $0.title == "Graphite · dark" })

        presets.menu?.performActionForItem(at: graphite)

        XCTAssertEqual(store.state.appearance.name, AppearanceSettings.graphite.name)
        XCTAssertEqual(store.state.appearance.colors, AppearanceSettings.graphite.colors)
        XCTAssertEqual(store.state.appearance.editorFontName, "Synthetic-Note-Font")
    }

    /// Hosts `view` in a window and finds its pull-down buttons, so a test can choose a menu item as a click does.
    private func hostPullDowns<V: View>(_ view: V) -> (NSWindow, [NSPopUpButton]) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 900), styleMask: [.titled], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: view)
        window.contentView = hosting
        window.orderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        func buttons(in view: NSView) -> [NSPopUpButton] {
            view.subviews.flatMap { buttons(in: $0) } + [view].compactMap { $0 as? NSPopUpButton }
        }
        return (window, buttons(in: hosting))
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
