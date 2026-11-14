import AppKit
import StowCore
import SwiftUI
import XCTest

@testable import Stow

/// Measures typing 50 characters at the end of a note through the editor's key-press path, one frame per key.
@MainActor
final class TypingMeasureTests: XCTestCase {
    func testTypingInA4KBNote() async throws { try await measureTyping(inNoteOf: 4_000) }
    func testTypingInA46KBNote() async throws { try await measureTyping(inNoteOf: 46_000) }
    func testTypingInA100KBNote() async throws { try await measureTyping(inNoteOf: 100_000) }

    func testTypingInAShortNoteWithTheBoardAndNoteWindowsOpen() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        DemoContent.load = (30, 20)
        defer { DemoContent.load = nil }
        let app = AppDelegate()
        await app.prepare(stateURL: directory.appendingPathComponent("state.json"), isDemo: true)
        defer { for session in app.manager?.sessions.values.map({ $0 }) ?? [] { session.stop() } }
        let store = try XCTUnwrap(app.store)
        let note = try XCTUnwrap(store.state.notes.last { $0.isDetached && $0.markdown.utf8.count < 100 })
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

        let options = XCTMeasureOptions()
        options.iterationCount = 3
        measure(metrics: [XCTClockMetric(), XCTCPUMetric()], options: options) {
            for character in String(repeating: "typed text ", count: 5).prefix(50) {
                editor.insertText(String(character), replacementRange: editor.selectedRange())
                drawFrame(of: windows)
            }
        }
        XCTAssertEqual(store.note(note.id)?.markdown, editor.string, "Typing reached the store")
        _ = await store.flush()
    }

    private func measureTyping(inNoteOf bytes: Int) async throws {
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

        let options = XCTMeasureOptions()
        options.iterationCount = 3
        measure(metrics: [XCTClockMetric(), XCTCPUMetric()], options: options) {
            for character in String(repeating: "typed text ", count: 5).prefix(50) {
                editor.insertText(String(character), replacementRange: editor.selectedRange())
                drawFrame(of: windows)
            }
        }
        XCTAssertEqual(store.note(id)?.markdown, editor.string, "Typing reached the store")
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
