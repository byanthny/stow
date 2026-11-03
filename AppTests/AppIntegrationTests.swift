import AppKit
import Foundation
import StowCore
import SwiftUI
import XCTest

@testable import Stow

/// Hosted integration checks of real AppKit objects with synthetic, temporary state.
/// These do not drive the user's desktop, general clipboard, or real GitHub account.
@MainActor
final class AppIntegrationTests: XCTestCase {
    func testDetachedCloseHideReopenAndExplicitDelete() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = try await prepare(directory)
        defer { dispose(app) }
        let id = app.store.addNote("Synthetic lifecycle note")
        app.store.detachNote(id)
        let panel = try XCTUnwrap(app.noteWindows[id])
        XCTAssertTrue(panel.isVisible)

        panel.performClose(nil)
        XCTAssertEqual(app.store.note(id)?.markdown, "Synthetic lifecycle note")
        XCTAssertEqual(app.store.note(id)?.isDetached, false)
        XCTAssertNil(app.noteWindows[id])

        app.store.detachNote(id)
        let reopened = try XCTUnwrap(app.noteWindows[id])
        app.board.orderOut(nil)
        XCTAssertFalse(app.board.isVisible)
        XCTAssertTrue(reopened.isVisible)
        XCTAssertFalse(app.applicationShouldTerminateAfterLastWindowClosed(NSApp))
        XCTAssertTrue(app.applicationShouldHandleReopen(NSApp, hasVisibleWindows: true))
        XCTAssertTrue(app.board.isVisible)
        XCTAssertTrue(reopened.isVisible)

        app.store.toggleSample(noteID: id)
        app.store.deleteNote(id)
        XCTAssertNil(app.store.note(id))
        XCTAssertNil(app.noteWindows[id])
        XCTAssertFalse(reopened.isVisible)
        XCTAssertFalse(app.store.state.extensionInstances.contains { $0.noteID == id })
        let saved = await app.store.flush()
        XCTAssertTrue(saved)
        let persisted = try await StateRepository(url: stateURL(directory)).load()
        XCTAssertFalse(persisted.notes.contains { $0.id == id })
    }

    func testFlushedLastEditAndDetachedGeometrySurviveTwoReconstructions() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try await prepare(directory)
        defer { dispose(first) }
        let id = first.store.addNote("Before final edit")
        first.store.detachNote(id)
        XCTAssertEqual(first.noteWindows[id]?.level, .floating)
        first.store.toggleAlwaysOnTop(id)
        let originalPanel = try XCTUnwrap(first.noteWindows[id])
        XCTAssertEqual(originalPanel.level, .normal)

        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let noteFrame = NSRect(
            x: screen.minX + 30, y: screen.minY + 40,
            width: min(360, screen.width), height: min(400, screen.height))
        let boardFrame = NSRect(
            x: screen.minX + 50, y: screen.minY + 60,
            width: min(390, screen.width), height: min(580, screen.height))
        originalPanel.setFrame(noteFrame, display: true)
        first.board.setFrame(boardFrame, display: true)
        first.windowDidMove(Notification(name: NSWindow.didMoveNotification, object: originalPanel))
        first.windowDidMove(Notification(name: NSWindow.didMoveNotification, object: first.board))
        first.store.editNote(
            id, markdown: "Final edit immediately before flush\nhttps://github.com/example/synthetic/pull/42")
        let saved = await first.store.flush()
        XCTAssertTrue(saved)
        dispose(first)

        let second = try await prepare(directory)
        defer { dispose(second) }
        XCTAssertEqual(
            second.store.note(id)?.markdown,
            "Final edit immediately before flush\nhttps://github.com/example/synthetic/pull/42")
        XCTAssertEqual(second.store.note(id)?.isDetached, true)
        XCTAssertEqual(second.store.note(id)?.isAlwaysOnTop, false)
        let secondPanel = try XCTUnwrap(second.noteWindows[id])
        XCTAssertEqual(secondPanel.level, .normal)
        assertFrame(secondPanel.frame, equals: noteFrame)
        assertFrame(second.board.frame, equals: boardFrame)
        second.windowDidMove(Notification(name: NSWindow.didMoveNotification, object: secondPanel))
        second.windowDidMove(Notification(name: NSWindow.didMoveNotification, object: second.board))
        let savedAgain = await second.store.flush()
        XCTAssertTrue(savedAgain)
        dispose(second)

        let third = try await prepare(directory)
        defer { dispose(third) }
        assertFrame(try XCTUnwrap(third.noteWindows[id]).frame, equals: noteFrame)
        assertFrame(third.board.frame, equals: boardFrame)
    }

    func testSampleEnableDisableAndConfigurationPersist() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = try await prepare(directory)
        defer { dispose(app) }
        let id = app.store.addNote("Synthetic accessory owner")
        app.store.toggleSample()
        app.store.toggleSample(noteID: id)
        await app.store.refreshAccessories()
        XCTAssertTrue(app.store.sampleEnabled())
        XCTAssertTrue(app.store.sampleEnabled(noteID: id))
        let instanceIndex = try XCTUnwrap(app.store.state.extensionInstances.firstIndex { $0.noteID == id })
        let instanceID = app.store.state.extensionInstances[instanceIndex].id
        app.store.state.extensionInstances[instanceIndex].configurationVersion = 7
        app.store.state.extensionInstances[instanceIndex].configuration = .object(["synthetic-setting": .string("kept")]
        )
        app.store.toggleSample(noteID: id)
        XCTAssertFalse(app.store.sampleEnabled(noteID: id))
        XCTAssertNil(app.store.accessoryResults[instanceID])
        let saved = await app.store.flush()
        XCTAssertTrue(saved)
        dispose(app)

        let restored = try await prepare(directory)
        defer { dispose(restored) }
        XCTAssertTrue(restored.store.sampleEnabled())
        XCTAssertFalse(restored.store.sampleEnabled(noteID: id))
        let instance = try XCTUnwrap(restored.store.state.extensionInstances.first { $0.id == instanceID })
        XCTAssertEqual(instance.configurationVersion, 7)
        XCTAssertEqual(instance.configuration, .object(["synthetic-setting": .string("kept")]))
    }

    func testCorruptAndNewerStateRemainUntouchedUntilExplicitRecovery() async throws {
        for original in [Data("not json: synthetic corrupt state".utf8), Data("{\"schemaVersion\":9999}".utf8)] {
            let directory = try makeDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let url = stateURL(directory)
            try original.write(to: url)
            let app = AppDelegate()
            await app.prepare(stateURL: url, isDemo: true)
            defer { dispose(app) }
            XCTAssertTrue(app.store.storageNeedsRecovery)
            XCTAssertNotNil(app.store.saveError)
            let id = app.store.addNote("New in-memory synthetic note")
            let blocked = await app.store.flush()
            XCTAssertFalse(blocked)
            XCTAssertEqual(try Data(contentsOf: url), original)

            await app.store.recoverState()
            XCTAssertFalse(app.store.storageNeedsRecovery)
            let backups = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix("state.json.backup-") }
            XCTAssertEqual(backups.count, 1)
            XCTAssertEqual(try Data(contentsOf: XCTUnwrap(backups.first)), original)
            let recovered = try await StateRepository(url: url).load()
            XCTAssertEqual(recovered.notes.first { $0.id == id }?.markdown, "New in-memory synthetic note")
        }
    }

    func testNativeEditorRepeatedFocusAndPrivatePasteboardInsertion() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = try await prepare(directory)
        defer { dispose(app) }
        let id = app.store.addNote()
        app.store.detachNote(id)
        let panel = try XCTUnwrap(app.noteWindows[id])
        let foundEditor = await waitUntil {
            panel.contentView?.layoutSubtreeIfNeeded()
            return self.textViews(in: panel.contentView).count == 1
        }
        XCTAssertTrue(foundEditor)
        let editor = try XCTUnwrap(textViews(in: panel.contentView).first)
        app.store.requestFocus(id)
        let initiallyFocused = await waitUntil { panel.firstResponder === editor }
        XCTAssertTrue(initiallyFocused)
        XCTAssertTrue(panel.makeFirstResponder(nil))
        XCTAssertFalse(panel.firstResponder === editor)
        app.store.requestFocus(id)
        let focusedAgain = await waitUntil { panel.firstResponder === editor }
        XCTAssertTrue(focusedAgain, "A fresh request for the same note must return keyboard focus")

        let pasteboard = NSPasteboard(name: .init("org.stow.tests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let ordinaryText = "https://github.com/example/synthetic/pull/42\nPersonal Markdown **stays text**"
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString(ordinaryText, forType: .string))
        let previousPins = app.store.state.pins
        let previousNoteCount = app.store.state.notes.count
        XCTAssertTrue(editor.readSelection(from: pasteboard, type: .string))
        // readSelection is an AppKit editor API, not a simulated Command-V event.
        editor.didChangeText()
        XCTAssertEqual(editor.string, ordinaryText)
        XCTAssertEqual(app.store.note(id)?.markdown, ordinaryText)
        XCTAssertEqual(app.store.state.pins, previousPins)
        XCTAssertEqual(app.store.state.notes.count, previousNoteCount)
        let saved = await app.store.flush()
        XCTAssertTrue(saved)
        let persisted = try await StateRepository(url: stateURL(directory)).load()
        XCTAssertEqual(persisted.notes.first { $0.id == id }?.markdown, ordinaryText)
    }

    func testRestoredFrameRejectsNonFiniteAndClampsOffscreenGeometry() {
        let fallback = NSRect(x: 20, y: 20, width: 350, height: 380)
        let minimum = NSSize(width: 260, height: 180)
        let invalid = WindowFrame(x: .nan, y: .infinity, width: 500, height: 500)
        assertFrame(
            restoredFrame(invalid, fallback: fallback, minimum: minimum),
            equals: restoredFrame(nil, fallback: fallback, minimum: minimum))
        let frame = restoredFrame(
            .init(x: 1e8, y: -1e8, width: 1e7, height: 1e7),
            fallback: fallback, minimum: minimum)
        XCTAssertTrue([frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite))
        let screens = NSScreen.screens.map(\.visibleFrame)
        XCTAssertTrue(
            screens.contains { screen in
                frame.minX >= screen.minX - 0.5 && frame.minY >= screen.minY - 0.5
                    && frame.maxX <= screen.maxX + 0.5 && frame.maxY <= screen.maxY + 0.5
            })
    }

    func testMarkdownInlineAndBlockImagesDoNotRequestNetworkResources() async throws {
        PreviewNetworkTripwire.reset()
        XCTAssertTrue(URLProtocol.registerClass(PreviewNetworkTripwire.self))
        defer { URLProtocol.unregisterClass(PreviewNetworkTripwire.self) }
        let window = NSWindow(
            contentRect: NSRect(x: 10, y: 10, width: 420, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let source = """
            # Synthetic preview

            ![block image](https://stow-preview.invalid/block.png)

            text ![inline image](http://stow-preview.invalid/inline.png) after image

            [Safe test link](https://stow-preview.invalid/link)
            """
        let host = NSHostingView(rootView: MarkdownPreview(source: source))
        window.contentView = host
        window.orderFront(nil)
        for _ in 0..<12 {
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertGreaterThan(host.bounds.width, 0)
        XCTAssertEqual(
            PreviewNetworkTripwire.requestCount, 0,
            "Rendering inline and block image Markdown must not fetch their URLs")
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "StowAppTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func stateURL(_ directory: URL) -> URL { directory.appendingPathComponent("state.json") }

    private func prepare(_ directory: URL) async throws -> AppDelegate {
        let url = stateURL(directory)
        if !FileManager.default.fileExists(atPath: url.path) {
            var initial = AppState()
            initial.githubEnabled = false
            initial.notes = [Note(markdown: "Synthetic seed note")]
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

    private func assertFrame(
        _ actual: NSRect, equals expected: NSRect,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(actual.minX, expected.minX, accuracy: 0.5, file: file, line: line)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: 0.5, file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: 0.5, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: 0.5, file: file, line: line)
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

private final class PreviewRequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
    func reset() {
        lock.lock()
        count = 0
        lock.unlock()
    }
    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

/// Fails closed for synthetic preview URLs if a future renderer tries to load them.
private final class PreviewNetworkTripwire: URLProtocol, @unchecked Sendable {
    private static let counter = PreviewRequestCounter()
    static var requestCount: Int { counter.value }
    static func reset() { counter.reset() }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "stow-preview.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.counter.increment()
        client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
    }
    override func stopLoading() {}
}
