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
        let (window, editor) = linkEditor("Read https://example.com/guide today. Not [this](javascript:alert).")
        defer { window.close() }
        let link = center(of: "example.com", in: editor)
        let guide = URL(string: "https://example.com/guide")

        XCTAssertEqual(editor.link(at: link), guide)
        XCTAssertNil(editor.link(at: center(of: "Read", in: editor)))
        XCTAssertNil(editor.link(at: center(of: "this", in: editor)))

        let menu = try XCTUnwrap(editor.menu(for: try rightClick(at: link, in: editor)))
        XCTAssertEqual(menu.items.first?.title, "Open Link")
        XCTAssertEqual(menu.items.first?.representedObject as? URL, guide)
    }

    func testOnlyALinksOwnTextOpensIt() throws {
        let (window, editor) = linkEditor("See https://example.com/guide\nSynthetic next line")
        defer { window.close() }
        let link = frame(of: "https://example.com/guide", in: editor)
        let beside = NSPoint(x: link.maxX + 60, y: link.midY)
        let guide = URL(string: "https://example.com/guide")

        // The insertion point nearest the click ends the link, but the click is past its text.
        XCTAssertNil(editor.link(at: beside))
        let menu = try XCTUnwrap(editor.menu(for: try rightClick(at: beside, in: editor)))
        XCTAssertFalse(menu.items.contains { $0.title == "Open Link" })
        XCTAssertEqual(editor.link(at: NSPoint(x: link.maxX - 2, y: link.midY)), guide)
        XCTAssertNotNil(editor.textLayoutManager, "Hit testing keeps the note on TextKit 2")
    }

    /// A window showing `source` in a styled note text view, inset as the note editor is.
    private func linkEditor(_ source: String) -> (NSWindow, NoteTextView) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 200), styleMask: [.titled], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        let editor = NoteTextView(frame: window.contentView?.bounds ?? .zero)
        editor.isRichText = false
        editor.textContainerInset = NSSize(width: 4, height: 8)
        window.contentView = editor
        editor.string = source
        NativeEditor.applyAppearance(.paper, to: editor)
        NativeEditor.styleMarkdown(in: editor, appearance: .paper)
        return (window, editor)
    }

    /// Where `word` is drawn, in `editor`'s coordinates.
    private func frame(of word: String, in editor: NSTextView) -> NSRect {
        let screen = editor.firstRect(forCharacterRange: (editor.string as NSString).range(of: word), actualRange: nil)
        return editor.convert(editor.window?.convertFromScreen(screen) ?? .zero, from: nil)
    }

    private func center(of word: String, in editor: NSTextView) -> NSPoint {
        let rect = frame(of: word, in: editor)
        return NSPoint(x: rect.midX, y: rect.midY)
    }

    /// A right-click at `point`, in `view`'s coordinates.
    private func rightClick(at point: NSPoint, in view: NSView) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .rightMouseDown, location: view.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
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

    func testAClickOnAPinnedSectionHeaderOverATallNoteEndsEditing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(stateURL: root.appendingPathComponent("state.json"))
        let id = store.addNote((1...40).map { "Synthetic line \($0)" }.joined(separator: "\n"))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 400), styleMask: [.titled], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        // A header pinned over the board's top while the note scrolls under it, as a section header stays.
        let board = ScrollView {
            VStack(spacing: 0) {
                NoteView(store: store, noteID: id, editorHeightLimit: 300) {}
                Color.clear.frame(height: 600)
            }
        }
        .overlay(alignment: .top) {
            Text(verbatim: "Synthetic section").frame(maxWidth: .infinity, minHeight: 32).background(.gray)
        }
        .themed(by: store.theme)
        let host = NSHostingView(rootView: board)
        window.contentView = host
        window.orderFront(nil)
        await settle(host)
        let laidOut = await waitUntil(host) { !self.noteScrollViews(in: host).isEmpty }
        XCTAssertTrue(laidOut, "The board lays out the note")
        await settle(host)
        let scroll = try XCTUnwrap(noteScrollViews(in: host).first)
        let editor = try XCTUnwrap(scroll.documentView as? NSTextView)
        let boardScroll = try XCTUnwrap(scroll.enclosingScrollView)
        window.makeFirstResponder(editor)
        await settle(host)
        XCTAssertTrue(window.firstResponder === editor)

        // Scrolls the board until the pinned header covers the note's text.
        let note = boardScroll.contentView.convert(scroll.bounds, from: scroll)
        boardScroll.contentView.scroll(to: NSPoint(x: 0, y: note.minY + 60))
        boardScroll.reflectScrolledClipView(boardScroll.contentView)
        let headerPoint = {
            let visible = boardScroll.convert(boardScroll.bounds, to: nil)
            return NSPoint(x: visible.midX, y: visible.maxY - 12)
        }
        let covered = await waitUntil(host) { scroll.bounds.contains(scroll.convert(headerPoint(), from: nil)) }
        XCTAssertTrue(covered, "The header is drawn over the note")
        await settle(host)
        let visible = boardScroll.convert(boardScroll.bounds, to: nil)
        let header = headerPoint()

        // A click on the note's own text below the header keeps editing.
        let onText = NSPoint(x: editor.convert(editor.bounds, to: nil).minX + 30, y: visible.maxY - 100)
        XCTAssertTrue(scroll.bounds.contains(scroll.convert(onText, from: nil)))
        try postClick(at: onText, in: window)
        await settle(host)
        XCTAssertTrue(window.firstResponder === editor, "A click on the note's text keeps editing")

        try postClick(at: header, in: window)
        await settle(host)
        XCTAssertFalse(window.firstResponder === editor, "A click on the header ends the editing")
    }

    /// Posts a left click at `location`, in `window`'s coordinates, for the app to handle as a real one.
    private func postClick(at location: NSPoint, in window: NSWindow) throws {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let click = try XCTUnwrap(
                NSEvent.mouseEvent(
                    with: type, location: location, modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            NSApp.postEvent(click, atStart: false)
        }
    }

    func testBoardNotesShrinkWhileAnotherAppIsInFrontAndGrowOnReturn() async throws {
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
        window.makeFirstResponder(editor)
        await settle(host)
        XCTAssertEqual(scroll.frame.height, 300, accuracy: 0.5, "While edited, it grows to the limit")

        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        await settle(host)
        XCTAssertLessThanOrEqual(scroll.frame.height, 176.5, "Another app in front shrinks the note")
        XCTAssertTrue(window.firstResponder === editor, "The note keeps its cursor")

        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        await settle(host)
        XCTAssertEqual(scroll.frame.height, 300, accuracy: 0.5, "Coming back opens it again")
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

    func testRestylingWhatAnEditChangedMatchesAFullRestyle() async throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 700), styleMask: [.titled], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let source = "# Plan\n\nSome **bold** and *it*.\n```\ncode\n```\n> quote\n- [a](https://example.com) ~~old~~\n"
        let host = NSHostingView(rootView: GrowingEditorHost(text: source))
        window.contentView = host
        window.orderFront(nil)
        await settle(host)
        let editor = try XCTUnwrap(noteScrollViews(in: host).first?.documentView as? NSTextView)
        let pieces = ["*", "**", "_", "`", "```", "# ", " ", "\n", "x", "> ", "- ", "[b](https://example.org)", "~~"]
        var seed: UInt64 = 11
        func next(_ bound: Int) -> Int {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((seed >> 33) % UInt64(bound + 1))
        }
        for step in 0..<150 {
            let length = (editor.string as NSString).length
            let location = next(length)
            let removed = next(min(3, length - location))
            let piece = next(1) == 0 ? pieces[next(pieces.count - 1)] : ""
            editor.insertText(piece, replacementRange: NSRange(location: location, length: removed))

            let reference = NSTextView()
            reference.isRichText = false
            reference.string = editor.string
            NativeEditor.applyAppearance(.paper, to: reference)
            NativeEditor.styleMarkdown(in: reference, appearance: .paper)
            let styled = try XCTUnwrap(editor.textStorage)
            let expected = try XCTUnwrap(reference.textStorage)
            XCTAssertEqual(styles(of: styled), styles(of: expected), "Step \(step) left stale styles")
        }
    }

    /// Each UTF-16 offset's Markdown styles, described so two texts can be compared.
    private func styles(of storage: NSTextStorage) -> [String] {
        let keys: [NSAttributedString.Key] = [
            .foregroundColor, .backgroundColor, .strikethroughStyle, .underlineStyle, .obliqueness, .strokeWidth,
            .noteLink, .toolTip,
        ]
        return (0..<storage.length).map { position in
            let font = storage.attribute(.font, at: position, effectiveRange: nil) as? NSFont
            let rest = keys.map { "\(storage.attribute($0, at: position, effectiveRange: nil) ?? "-")" }
            return ([font.map { "\($0.fontName) \($0.pointSize)" } ?? "-"] + rest).joined(separator: "|")
        }
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

    /// Lays out `host` and checks `predicate` every 20 ms for up to five seconds.
    private func waitUntil(_ host: NSView, _ predicate: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<250 {
            host.layoutSubtreeIfNeeded()
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return predicate()
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
