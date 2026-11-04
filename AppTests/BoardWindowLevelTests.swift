import AppKit
import Foundation
import StowCore
import XCTest

@testable import Stow

/// Checks AppKit window levels using synthetic temporary state, without desktop UI automation.
@MainActor
final class BoardWindowLevelTests: XCTestCase {
    func testBoardDefaultsToFloatingAndTogglesIndependentlyOfDetachedNotes() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = try await prepare(directory)
        defer { dispose(app) }
        XCTAssertTrue(app.store.state.boardAlwaysOnTop)
        XCTAssertEqual(app.board.level, .floating)
        let floatingNote = try XCTUnwrap(app.store.state.notes.first { $0.isAlwaysOnTop })
        let normalNote = try XCTUnwrap(app.store.state.notes.first { !$0.isAlwaysOnTop })
        let floatingWindow = try XCTUnwrap(app.noteWindows[floatingNote.id])
        let normalWindow = try XCTUnwrap(app.noteWindows[normalNote.id])
        XCTAssertEqual(floatingWindow.level, .floating)
        XCTAssertEqual(normalWindow.level, .normal)

        app.store.toggleBoardAlwaysOnTop()
        XCTAssertFalse(app.store.state.boardAlwaysOnTop)
        XCTAssertEqual(app.board.level, .normal)
        XCTAssertEqual(floatingWindow.level, .floating)
        XCTAssertEqual(normalWindow.level, .normal)
        XCTAssertEqual(app.store.note(floatingNote.id)?.isAlwaysOnTop, true)
        XCTAssertEqual(app.store.note(normalNote.id)?.isAlwaysOnTop, false)

        app.store.toggleAlwaysOnTop(normalNote.id)
        XCTAssertEqual(normalWindow.level, .floating)
        XCTAssertFalse(app.store.state.boardAlwaysOnTop)
        XCTAssertEqual(app.board.level, .normal)
        app.store.toggleBoardAlwaysOnTop()
        XCTAssertTrue(app.store.state.boardAlwaysOnTop)
        XCTAssertEqual(app.board.level, .floating)
        XCTAssertEqual(floatingWindow.level, .floating)
        XCTAssertEqual(normalWindow.level, .floating)
    }

    func testUnpinnedBoardPersistsAcrossReconstructionAndCanBePinnedAgain() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try await prepare(directory)
        defer { dispose(first) }
        first.store.toggleBoardAlwaysOnTop()
        let saved = await first.store.flush()
        XCTAssertTrue(saved)
        let persisted = try await StateRepository(url: stateURL(directory)).load()
        XCTAssertFalse(persisted.boardAlwaysOnTop)
        dispose(first)

        let restored = try await prepare(directory)
        defer { dispose(restored) }
        XCTAssertFalse(restored.store.state.boardAlwaysOnTop)
        XCTAssertEqual(restored.board.level, .normal)
        for note in persisted.notes {
            let panel = try XCTUnwrap(restored.noteWindows[note.id])
            XCTAssertEqual(panel.level, note.isAlwaysOnTop ? .floating : .normal)
            XCTAssertEqual(restored.store.note(note.id)?.markdown, note.markdown)
        }
        restored.store.toggleBoardAlwaysOnTop()
        XCTAssertTrue(restored.store.state.boardAlwaysOnTop)
        XCTAssertEqual(restored.board.level, .floating)
        for note in persisted.notes {
            XCTAssertEqual(restored.noteWindows[note.id]?.level, note.isAlwaysOnTop ? .floating : .normal)
        }
        let savedAgain = await restored.store.flush()
        XCTAssertTrue(savedAgain)
        let pinned = try await StateRepository(url: stateURL(directory)).load()
        XCTAssertTrue(pinned.boardAlwaysOnTop)
    }

    func testWindowsFollowTheCurrentDesktopButNotOtherFullScreenApps() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = try await prepare(directory)
        defer { dispose(app) }
        for panel in [app.board] + Array(app.noteWindows.values) {
            XCTAssertTrue(panel?.collectionBehavior.contains(.canJoinAllSpaces) == true)
            XCTAssertFalse(panel?.collectionBehavior.contains(.fullScreenAuxiliary) == true)
        }
        app.showSettings()
        let settings = try XCTUnwrap(NSApp.windows.first { $0.title == "Stow settings" })
        defer { settings.close() }
        XCTAssertTrue(settings.collectionBehavior.contains(.moveToActiveSpace))
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "StowBoardLevelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func stateURL(_ directory: URL) -> URL { directory.appendingPathComponent("state.json") }

    private func prepare(_ directory: URL) async throws -> AppDelegate {
        let url = stateURL(directory)
        if !FileManager.default.fileExists(atPath: url.path) {
            var state = AppState()
            state.githubEnabled = false
            state.notes = [
                Note(markdown: "Synthetic floating note", isDetached: true, isAlwaysOnTop: true),
                Note(markdown: "Synthetic ordinary note", isDetached: true, isAlwaysOnTop: false),
            ]
            try await StateRepository(url: url).save(state)
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
}
