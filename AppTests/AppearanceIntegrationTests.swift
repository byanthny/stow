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

        NativeEditor.styleMarkdown(in: editor, appearance: appearance)

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
        NativeEditor.styleMarkdown(in: editor, appearance: appearance)
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
        NativeEditor.styleMarkdown(in: editor, appearance: .graphite)

        undo.undo()

        XCTAssertEqual(editor.string, "Use ")
    }

    func testMarkdownShowsAsItReadsWithoutChangingTheSource() throws {
        let editor = NSTextView()
        editor.isRichText = false
        let source = """
            Weekly sync
            ## Agenda
            - **Ship** the *beta*
            - ~~old item~~
            > quoted
            See [the docs](https://example.com/docs).
            """
        editor.string = source
        let appearance = AppearanceSettings.paper
        NativeEditor.applyAppearance(appearance, to: editor)

        NativeEditor.styleMarkdown(in: editor, appearance: appearance)

        let storage = try XCTUnwrap(editor.textStorage)
        let text = storage.string as NSString
        func attribute(_ key: NSAttributedString.Key, of word: String) -> Any? {
            storage.attribute(key, at: text.range(of: word).location, effectiveRange: nil)
        }
        func font(of word: String) throws -> NSFont { try XCTUnwrap(attribute(.font, of: word) as? NSFont) }
        func color(of word: String) -> NSColor? {
            (attribute(.foregroundColor, of: word) as? NSColor)?.usingColorSpace(.sRGB)
        }
        let body = try font(of: "quoted")
        let muted = NSColor(Color(stowHex: appearance.colors.muted)).usingColorSpace(.sRGB)
        XCTAssertGreaterThan(try font(of: "Weekly").pointSize, try font(of: "Agenda").pointSize)
        XCTAssertGreaterThan(try font(of: "Agenda").pointSize, body.pointSize)
        XCTAssertTrue(NSFontManager.shared.traits(of: try font(of: "Ship")).contains(.boldFontMask))
        XCTAssertTrue(NSFontManager.shared.traits(of: try font(of: "beta")).contains(.italicFontMask))
        XCTAssertNotNil(attribute(.strikethroughStyle, of: "old item"))
        XCTAssertEqual(color(of: "##"), muted)
        XCTAssertEqual(color(of: "quoted"), muted)
        XCTAssertNotEqual(color(of: "Ship"), muted)
        XCTAssertEqual(attribute(.noteLink, of: "the docs") as? URL, URL(string: "https://example.com/docs"))
        XCTAssertNotNil(attribute(.underlineStyle, of: "the docs"))
        XCTAssertEqual(color(of: "](https"), muted)
        XCTAssertEqual(editor.string, source)
        XCTAssertEqual(editor.typingAttributes[.font] as? NSFont, body)
        XCTAssertNil(editor.typingAttributes[.noteLink])
    }

    func testLinksTheTextViewFindsGoThroughTheWebLinkCheck() {
        let coordinator = NativeEditor(text: .constant(""), focusRequestID: UUID(), appearance: .paper).makeCoordinator()
        let editor = NSTextView()
        // Claimed, then refused by Stow's web-link check.
        XCTAssertTrue(coordinator.textView(editor, clickedOnLink: URL(fileURLWithPath: "/Applications"), at: 0))
        XCTAssertTrue(coordinator.textView(editor, clickedOnLink: "javascript:alert(1)", at: 0))
    }

    func testWebLinksOpenFromTheirContextMenu() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 200), styleMask: [.titled], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let editor = NoteTextView(frame: window.contentView?.bounds ?? .zero)
        editor.isRichText = false
        window.contentView = editor
        editor.string = "Read https://example.com/guide today. Not [this](javascript:alert)."
        NativeEditor.applyAppearance(.paper, to: editor)
        NativeEditor.styleMarkdown(in: editor, appearance: .paper)
        let text = editor.string as NSString
        let link = text.range(of: "example.com")
        let guide = URL(string: "https://example.com/guide")

        XCTAssertEqual(editor.link(atInsertionPoint: link.location), guide)
        XCTAssertNil(editor.link(atInsertionPoint: text.range(of: "Read").location))
        XCTAssertNil(editor.link(atInsertionPoint: text.range(of: "this").location))

        let rect = window.convertFromScreen(editor.firstRect(forCharacterRange: link, actualRange: nil))
        let click = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .rightMouseDown, location: NSPoint(x: rect.midX, y: rect.midY), modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let menu = try XCTUnwrap(editor.menu(for: click))
        XCTAssertEqual(menu.items.first?.title, "Open Link")
        XCTAssertEqual(menu.items.first?.representedObject as? URL, guide)
    }

    func testBoardNotesGrowWithTheirTextUpToTheLimit() async throws {
        func lines(_ count: Int) -> String { (1...count).map { "Synthetic line \($0)" }.joined(separator: "\n") }
        let short = try await hostedEditor(lines(1))
        let medium = try await hostedEditor(lines(12))
        let long = try await hostedEditor(lines(80))

        XCTAssertEqual(short.height, 104, accuracy: 0.5)
        XCTAssertGreaterThan(medium.height, 104)
        XCTAssertLessThan(medium.height, 300)
        XCTAssertFalse(medium.scrolls, "A note under the limit shows all of its text")
        XCTAssertEqual(long.height, 300, accuracy: 0.5)
        XCTAssertTrue(long.scrolls, "A note over the limit scrolls inside")
    }

    func testTypingAtTheEndOfAGrowingNoteKeepsTheCursorInView() async throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 300), styleMask: [.titled], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: GrowingEditorHost(text: "Synthetic title"))
        window.contentView = host
        window.orderFront(nil)
        await settle(host)
        let scroll = try XCTUnwrap(noteScrollViews(in: host).first)
        let editor = try XCTUnwrap(scroll.documentView as? NSTextView)
        let board = try XCTUnwrap(scroll.enclosingScrollView)
        window.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))

        for line in 1...16 {
            editor.insertText("\nSynthetic line \(line)", replacementRange: editor.selectedRange())
            await settle(host)
        }

        // The cursor ends the note, so its last line shows on the board.
        let note = board.contentView.convert(scroll.bounds, from: scroll)
        XCTAssertGreaterThan(board.contentView.bounds.minY, 0, "The board scrolled with the note")
        XCTAssertGreaterThanOrEqual(board.contentView.bounds.maxY, note.maxY - editor.textContainerInset.height - 1)
    }

    func testBoardNotesShowAFewLinesUntilEditedAndShrinkWhenClickedAway() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(stateURL: root.appendingPathComponent("state.json"))
        let id = store.addNote((1...40).map { "Synthetic line \($0)" }.joined(separator: "\n"))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 700), styleMask: [.titled], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let board = ScrollView {
            VStack(spacing: 0) {
                NoteView(store: store, noteID: id, editorHeightLimit: 300) {}
                Color.clear.frame(height: 200)
            }
        }.themed(by: store.theme)
        let host = NSHostingView(rootView: board)
        window.contentView = host
        window.orderFront(nil)
        await settle(host)
        let scroll = try XCTUnwrap(noteScrollViews(in: host).first)
        let editor = try XCTUnwrap(scroll.documentView as? NSTextView)
        window.makeFirstResponder(nil)
        await settle(host)
        XCTAssertLessThanOrEqual(scroll.frame.height, 176.5, "A note that isn't being edited shows a few lines")

        window.makeFirstResponder(editor)
        await settle(host)
        XCTAssertEqual(scroll.frame.height, 300, accuracy: 0.5, "While edited, it grows to the limit")

        // A click in empty board space below the note ends the editing.
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let click = try XCTUnwrap(
                NSEvent.mouseEvent(
                    with: type, location: NSPoint(x: 180, y: 20), modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            NSApp.postEvent(click, atStart: false)
        }
        await settle(host)
        XCTAssertFalse(window.firstResponder === editor)
        XCTAssertLessThanOrEqual(scroll.frame.height, 176.5)
    }

    func testANewNoteTakesFocusOnlyOnce() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(stateURL: root.appendingPathComponent("state.json"))
        let id = store.addNote("Synthetic")
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 500), styleMask: [.titled], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.orderFront(nil)
        func showNote() async throws -> NSTextView {
            let host = NSHostingView(
                rootView: AnyView(NoteView(store: store, noteID: id, editorHeightLimit: 300) {}.themed(by: store.theme)))
            window.contentView = host
            await settle(host)
            return try XCTUnwrap(noteScrollViews(in: host).first?.documentView as? NSTextView)
        }
        let first = try await showNote()
        XCTAssertTrue(window.firstResponder === first, "A new note takes focus")
        window.makeFirstResponder(nil)

        // Rebuilt, as collapsing and expanding Notes does, the note leaves focus where it is.
        let rebuilt = try await showNote()
        XCTAssertFalse(window.firstResponder === rebuilt)
    }

    /// Hosts a board-style editor showing `text`, and reports its height and whether its text scrolls inside.
    private func hostedEditor(_ text: String) async throws -> (height: CGFloat, scrolls: Bool) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 700), styleMask: [.titled], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let editor = NativeEditor(
            text: .constant(text), focusRequestID: UUID(), appearance: .paper, fitsText: 104...300)
        let host = NSHostingView(rootView: ScrollView { editor })
        window.contentView = host
        window.orderFront(nil)
        await settle(host)
        let scroll = try XCTUnwrap(noteScrollViews(in: host).first)
        let document = try XCTUnwrap(scroll.documentView)
        return (scroll.frame.height, document.frame.height > scroll.contentView.bounds.height + 0.5)
    }

    private func settle(_ host: NSView) async {
        for _ in 0..<6 {
            host.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private func noteScrollViews(in view: NSView) -> [NoteScrollView] {
        view.subviews.flatMap { noteScrollViews(in: $0) } + [view].compactMap { $0 as? NoteScrollView }
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

    func testNoteMenuAppearsOnlyWithSomethingToOffer() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(stateURL: root.appendingPathComponent("state.json"))
        let id = store.addNote("Synthetic note")
        func noteMenu() -> NSPopUpButton? {
            let (window, buttons) = hostPullDowns(NoteView(store: store, noteID: id) {}.themed(by: store.theme))
            defer { window.close() }
            return buttons.first { $0.accessibilityLabel() == "Note actions" }
        }
        XCTAssertNil(noteMenu(), "A note with no link and the sample off has no ⋯ menu")

        store.toggleSample()
        let titles = try XCTUnwrap(noteMenu()?.menu?.items.map(\.title))
        XCTAssertTrue(titles.contains("Enable sample accessory"))
    }

    func testDetachedNoteWindowsAreNamedAfterTheirNotes() {
        XCTAssertEqual(Note(markdown: "# Groceries\n- synthetic").windowTitle(profileName: nil), "Groceries")
        XCTAssertEqual(Note(markdown: "Standup\nnotes").windowTitle(profileName: "Work"), "Standup — Work")
        XCTAssertEqual(Note(markdown: "").windowTitle(profileName: nil), "Untitled note")
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

/// A board-style note: room above it, and a binding, so typing grows it inside a scrolling board.
private struct GrowingEditorHost: View {
    @State var text: String
    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Color.clear.frame(height: 150)
                NativeEditor(text: $text, focusRequestID: UUID(), appearance: .paper, fitsText: 104...2000)
            }
        }
    }
}
