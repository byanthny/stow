import AppKit
import StowCore
import SwiftUI
import XCTest

@testable import Stow

/// Times typing 50 characters at the end of a note through the editor's key-press path, with queued main-thread work
/// and one frame per key. Runs only for `scripts/measure.sh`, which sets STOW_MEASURE.
@MainActor
final class TypingMeasureTests: XCTestCase {
    private let typed = String(String(repeating: "typed text ", count: 5).prefix(50))

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["STOW_MEASURE"] == "1")
    }

    func testTypingInA4KBNote() async throws { try await measureTyping("4KB", bytes: 4_000) }
    func testTypingInA46KBNote() async throws { try await measureTyping("46KB", bytes: 46_000) }
    func testTypingInA100KBNote() async throws { try await measureTyping("100KB", bytes: 100_000) }

    func testTypingInAShortNoteWithTheBoardAndNoteWindowsOpen() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        DemoContent.load = (30, 20)
        defer { DemoContent.load = nil }
        let app = AppDelegate()
        await app.prepare(stateURL: directory.appendingPathComponent("state.json"), isDemo: true)
        defer { for session in app.manager?.sessions.values.map({ $0 }) ?? [] { session.stop() } }
        let store = try XCTUnwrap(app.store)
        let note = try XCTUnwrap(store.snapshot().notes.last { $0.isDetached && $0.markdown.utf8.count < 100 })
        XCTAssertEqual(app.noteWindows.count, 5)
        let board = try XCTUnwrap(app.board)
        let panel = try XCTUnwrap(app.noteWindows[note.id])
        for _ in 0..<10 {
            board.contentView?.layoutSubtreeIfNeeded()
            for window in app.noteWindows.values { window.contentView?.layoutSubtreeIfNeeded() }
            try? await Task.sleep(for: .milliseconds(50))
        }
        let editor = try XCTUnwrap(textViews(in: try XCTUnwrap(panel.contentView)).first)
        let windows = [board] + Array(app.noteWindows.values)
        panel.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))

        try await time("board", typing: editor, in: windows)
        XCTAssertEqual(store.note(note.id)?.markdown, editor.string, "Typing reached the store")
        _ = await store.flush()
    }

    private func measureTyping(_ name: String, bytes: Int) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(stateURL: root.appendingPathComponent("state.json"))
        let id = store.addNote(DemoContent.markdown(bytes: bytes))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 400), styleMask: [.titled], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: NoteView(store: store, noteID: id, detached: true).themed(by: store.theme))
        window.contentView = host
        window.orderFront(nil)
        for _ in 0..<6 {
            host.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(20))
        }
        let editor = try XCTUnwrap(textViews(in: host).first)
        let windows = [window]
        window.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))

        try await time(name, typing: editor, in: windows)
        XCTAssertEqual(store.note(id)?.markdown, editor.string, "Typing reached the store")
    }

    /// One warm-up run and three timed runs of 50 keys, each followed by queued work and a frame.
    private func time(_ name: String, typing editor: NSTextView, in windows: [NSWindow]) async throws {
        var seconds: [Double] = []
        for run in 0..<4 {
            let start = ContinuousClock.now
            for character in typed {
                editor.insertText(String(character), replacementRange: editor.selectedRange())
                await Task.yield()
                await Task.yield()
                drawFrame(of: windows)
            }
            if run > 0 { seconds.append((ContinuousClock.now - start) / .seconds(1)) }
        }
        XCTAssertTrue(editor.string.hasSuffix(typed), "The typed characters landed at the end")
        let average = seconds.reduce(0, +) / Double(seconds.count)
        let runs = seconds.map { String(format: "%.3f", $0) }.joined(separator: ", ")
        print(String(format: "typing-measure %@: average %.3f s (%@)", name, average, runs))
    }

    /// One frame for each window, as a key press gets: the run loop applies pending updates, then layout and drawing.
    private func drawFrame(of windows: [NSWindow]) {
        RunLoop.current.run(mode: .default, before: .now)
        for window in windows {
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
        CATransaction.flush()
    }

    private func textViews(in root: NSView) -> [NSTextView] {
        (root as? NSTextView).map { [$0] } ?? root.subviews.flatMap { textViews(in: $0) }
    }
}
