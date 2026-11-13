import AppKit
import Foundation
import StowCore
import XCTest

@testable import Stow

/// Hosted acceptance checks of store/window wiring with synthetic managed Markdown files.
@MainActor
final class LiveMarkdownIntegrationTests: XCTestCase {
    func testPortableSnapshotIncludesImmediateExternalEditBeforeWatcherDebounce() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = try await prepare(directory)
        defer { dispose(app) }
        let id = try XCTUnwrap(app.store.state.notes.first?.id)
        let external = "# External edit immediately before export\r\n\r\nFresh backup source.\r\n"
        try Data(external.utf8).write(to: noteFile(id, store: app.store), options: .atomic)
        // No delay or presenter callback: the snapshot itself must reconcile the managed files.
        let snapshot = try await app.store.portableSnapshot()
        XCTAssertEqual(snapshot.notes.first { $0.id == id }?.markdown, external)
        XCTAssertEqual(app.store.note(id)?.markdown, external)
        let decoded = try StowBackup.decode(StowBackup.encode(snapshot))
        XCTAssertEqual(decoded.notes.first { $0.id == id }?.markdown, external)
        XCTAssertEqual(try Data(contentsOf: noteFile(id, store: app.store)), Data(external.utf8))
        await shutdown(app)
    }

    func testASaveWithNothingNewLeavesTheStateAlone() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = try await prepare(directory)
        defer { dispose(app) }
        let first = await app.store.flush()
        XCTAssertTrue(first)
        final class Flag: @unchecked Sendable { var raised = false }
        let changed = Flag()
        withObservationTracking { _ = app.store.state } onChange: { changed.raised = true }
        let saved = await app.store.flush()
        XCTAssertTrue(saved)
        XCTAssertFalse(changed.raised, "A save that found nothing new still rewrote the notes, redrawing the board")
        await shutdown(app)
    }

    func testOrdinaryFlushAndPortableSnapshotAreBlockedDuringRestore() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = try await prepare(directory)
        defer { dispose(app) }
        let before = try XCTUnwrap(app.store.state.notes.first)
        let external = "# External text while restore is active\n"
        app.store.isRestoringBackup = true
        // The session has stopped by the time this runs, and a stopped profile is no longer the active one.
        defer { app.store?.isRestoringBackup = false }
        try Data(external.utf8).write(to: noteFile(before.id, store: app.store))
        let blocked = await app.store.flush()
        XCTAssertFalse(blocked)
        XCTAssertEqual(app.store.note(before.id)?.markdown, before.markdown)
        do {
            _ = try await app.store.portableSnapshot()
            XCTFail("Export must not snapshot state while restoration is active")
        } catch {
            // The failure is part of the public operation contract; no particular error text is required.
        }
        XCTAssertEqual(try Data(contentsOf: noteFile(before.id, store: app.store)), Data(external.utf8))
        app.store.isRestoringBackup = false
        let saved = await app.store.flush()
        XCTAssertTrue(saved)
        XCTAssertEqual(app.store.note(before.id)?.markdown, external)
        await shutdown(app)
    }

    func testExternalEditThenFlushUpdatesSourceWithoutChangingNoteIdentity() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = try await prepare(directory)
        defer { dispose(app) }
        let before = try XCTUnwrap(app.store.state.notes.first)
        let file = noteFile(before.id, store: app.store)
        let external = "# Edited outside Stow\r\n\r\n**Same note**, café.\r\n"
        try Data(external.utf8).write(to: file)
        let saved = await app.store.flush()
        XCTAssertTrue(saved)
        let edited = try XCTUnwrap(app.store.note(before.id))
        XCTAssertEqual(edited.markdown, external)
        XCTAssertEqual(edited.createdAt, before.createdAt)
        XCTAssertEqual(edited.pullRequest, before.pullRequest)
        XCTAssertEqual(edited.isDetached, before.isDetached)
        XCTAssertEqual(app.store.state.notes.count, 1)
        XCTAssertEqual(try Data(contentsOf: file), Data(external.utf8))
        await shutdown(app)

        let restarted = try await prepare(directory)
        defer { dispose(restarted) }
        XCTAssertEqual(restarted.store.note(before.id)?.markdown, external)
        XCTAssertEqual(restarted.store.state.notes.count, 1)
        await shutdown(restarted)
    }

    func testDirtyAppEditAndExternalEditBothSurviveFlushAndRestart() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = try await prepare(directory)
        defer { dispose(app) }
        let id = try XCTUnwrap(app.store.state.notes.first?.id)
        let local = "# Unsaved app variant\n\nKeep this exact source."
        let external = "# External variant\r\n\r\nKeep this one too.\r\n"
        app.store.editNote(id, markdown: local)
        try Data(external.utf8).write(to: noteFile(id, store: app.store), options: .atomic)
        let saved = await app.store.flush()
        XCTAssertTrue(saved)
        XCTAssertEqual(Set(app.store.state.notes.map(\.markdown)), Set([local, external]))
        XCTAssertEqual(app.store.state.notes.count, 2)
        XCTAssertNotNil(app.store.note(id))
        XCTAssertFalse(app.store.conflictNoteIDs.isEmpty)
        XCTAssertNotNil(app.store.noteFileMessage)
        let savedIDs = Set(app.store.state.notes.map(\.id))
        for note in app.store.state.notes {
            XCTAssertEqual(try Data(contentsOf: noteFile(note.id, store: app.store)), Data(note.markdown.utf8))
        }
        await shutdown(app)

        let restarted = try await prepare(directory)
        defer { dispose(restarted) }
        XCTAssertEqual(Set(restarted.store.state.notes.map(\.markdown)), Set([local, external]))
        XCTAssertEqual(Set(restarted.store.state.notes.map(\.id)), savedIDs)
        XCTAssertEqual(restarted.store.state.notes.count, 2)
        await shutdown(restarted)
    }

    func testRestorePreservesPreviousBackupAndFolderAndRebuildsRestoredWindows() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = try await prepare(directory)
        defer { dispose(app) }
        let oldNote = try XCTUnwrap(app.store.state.notes.first)
        app.store.detachNote(oldNote.id)
        let oldWindow = try XCTUnwrap(app.noteWindows[oldNote.id])
        let oldDirectory = app.store.notesDirectory
        let oldFile = noteFile(oldNote.id, store: app.store)
        let oldBytes = try Data(contentsOf: oldFile)
        let reference = PullRequestReference(owner: "example", repository: "restored-synthetic", number: 27)
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let frame = WindowFrame(x: screen.minX + 25, y: screen.minY + 35, width: 350, height: 380)
        let restoredNote = Note(
            markdown: "# Restored source\n\nExact Markdown from the backup.", pullRequest: reference,
            isDetached: true, isAlwaysOnTop: false, frame: frame)
        var replacement = AppState()
        replacement.githubEnabled = false
        replacement.boardAlwaysOnTop = false
        replacement.appearance = .paper
        replacement.pins = [reference]
        replacement.notes = [restoredNote]
        var portable = try StowBackup.decode(StowBackup.encode(replacement))
        // A crafted backup must not choose this Mac's GitHub CLI or turn GitHub access on.
        app.store.state.ghExecutablePath = "/synthetic/local/gh"
        portable.ghExecutablePath = "/bin/sh"
        portable.githubEnabled = true
        let restored = await app.store.restoreBackup(portable)
        XCTAssertTrue(restored)
        XCTAssertEqual(app.store.state.ghExecutablePath, "/synthetic/local/gh")
        XCTAssertFalse(app.store.state.githubEnabled)
        XCTAssertNotEqual(app.store.notesDirectory, oldDirectory)
        XCTAssertEqual(try Data(contentsOf: oldFile), oldBytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldDirectory.path))
        XCTAssertEqual(app.store.state.pins, [reference])
        XCTAssertEqual(app.store.note(restoredNote.id)?.markdown, restoredNote.markdown)
        XCTAssertEqual(app.store.note(restoredNote.id)?.frame, frame)
        XCTAssertEqual(app.store.note(restoredNote.id)?.isDetached, true)
        XCTAssertEqual(app.store.note(restoredNote.id)?.isAlwaysOnTop, false)
        XCTAssertEqual(app.board.level, .normal)
        XCTAssertEqual(app.noteWindows[restoredNote.id]?.level, .normal)
        XCTAssertNil(app.noteWindows[oldNote.id])
        XCTAssertFalse(oldWindow.isVisible)
        XCTAssertEqual(app.store.theme.settings, replacement.appearance)
        XCTAssertEqual(
            try Data(contentsOf: noteFile(restoredNote.id, store: app.store)), Data(restoredNote.markdown.utf8))
        let backups = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("pre-restore-") && $0.pathExtension == "stowbackup" }
        XCTAssertEqual(backups.count, 1)
        let backupURL = try XCTUnwrap(backups.first)
        let previous = try StowBackup.decode(Data(contentsOf: backupURL))
        XCTAssertEqual(previous.notes.first { $0.id == oldNote.id }?.markdown, oldNote.markdown)
        let backupMode =
            try FileManager.default.attributesOfItem(atPath: backupURL.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(backupMode?.intValue, 0o600)
        let restoredDirectory = app.store.notesDirectory
        await shutdown(app)

        let restarted = try await prepare(directory)
        defer { dispose(restarted) }
        XCTAssertEqual(restarted.store.notesDirectory, restoredDirectory)
        XCTAssertEqual(restarted.store.state.pins, [reference])
        XCTAssertEqual(restarted.store.note(restoredNote.id)?.markdown, restoredNote.markdown)
        XCTAssertEqual(restarted.noteWindows[restoredNote.id]?.level, .normal)
        XCTAssertEqual(restarted.board.level, .normal)
        XCTAssertEqual(try Data(contentsOf: oldFile), oldBytes)
        await shutdown(restarted)
    }

    func testMarkdownBatchImportPreservesSourceAndAllocatesNewStableIdentities() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = try await prepare(directory)
        defer { dispose(app) }
        let oldIDs = Set(app.store.state.notes.map(\.id))
        let sources = ["# Imported\r\n\r\n**Exact CRLF**\r\n", "\u{FEFF}# café\nline\n", ""]
        app.store.importMarkdown(sources)
        let imported = app.store.state.notes.filter { !oldIDs.contains($0.id) }
        XCTAssertEqual(imported.map(\.markdown), sources)
        XCTAssertEqual(Set(imported.map(\.id)).count, sources.count)
        let saved = await app.store.flush()
        XCTAssertTrue(saved)
        for note in imported {
            XCTAssertEqual(try Data(contentsOf: noteFile(note.id, store: app.store)), Data(note.markdown.utf8))
        }
        await shutdown(app)

        let restarted = try await prepare(directory)
        defer { dispose(restarted) }
        for note in imported { XCTAssertEqual(restarted.store.note(note.id)?.markdown, note.markdown) }
        XCTAssertEqual(restarted.store.state.notes.count, oldIDs.count + sources.count)
        await shutdown(restarted)
    }

    func testUncoordinatedInPlaceAndAtomicEditsReloadWithoutExplicitFlush() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = try await prepare(directory)
        defer { dispose(app) }
        let id = try XCTUnwrap(app.store.state.notes.first?.id)
        let file = noteFile(id, store: app.store)
        let inPlace = "# Uncoordinated in-place write\n"
        try Data(inPlace.utf8).write(to: file)
        let observedInPlace = await waitUntil { app.store.note(id)?.markdown == inPlace }
        XCTAssertTrue(observedInPlace, "An ordinary editor write must reload without an explicit flush")
        let atomic = "# Uncoordinated atomic replacement\n"
        try Data(atomic.utf8).write(to: file, options: .atomic)
        let observedAtomic = await waitUntil { app.store.note(id)?.markdown == atomic }
        XCTAssertTrue(observedAtomic, "Replacing the Markdown inode must also reload")
        await shutdown(app)
    }

    func testRemovingThePullRequestLinkKeepsTheNoteAndItsFile() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = try await prepare(directory)
        defer { dispose(app) }
        let note = try XCTUnwrap(app.store.state.notes.first)
        XCTAssertNotNil(note.pullRequest)
        let file = noteFile(note.id, store: app.store)
        let source = try Data(contentsOf: file)
        app.store.unlinkPullRequest(note.id)
        XCTAssertNil(app.store.note(note.id)?.pullRequest)
        XCTAssertEqual(app.store.note(note.id)?.markdown, note.markdown)
        await shutdown(app)
        XCTAssertEqual(try Data(contentsOf: file), source)

        let restarted = try await prepare(directory)
        defer { dispose(restarted) }
        let reloaded = try XCTUnwrap(restarted.store.note(note.id))
        XCTAssertNil(reloaded.pullRequest)
        XCTAssertEqual(reloaded.markdown, note.markdown)
        await shutdown(restarted)
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "StowLiveMarkdownTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func prepare(_ directory: URL) async throws -> AppDelegate {
        let url = directory.appendingPathComponent("state.json")
        if !FileManager.default.fileExists(atPath: url.path) {
            var initial = AppState()
            initial.githubEnabled = false
            initial.notes = [
                Note(
                    markdown: "# Synthetic original\n\nOriginal source.",
                    pullRequest: .init(owner: "example", repository: "synthetic", number: 1))
            ]
            try await StateRepository(url: url).save(initial)
        }
        let app = AppDelegate()
        await app.prepare(stateURL: url, isDemo: true)
        return app
    }

    private func noteFile(_ id: UUID, store: AppStore) -> URL {
        store.notesDirectory.appendingPathComponent("\(id.uuidString).md")
    }

    private func shutdown(_ app: AppDelegate) async {
        app.store.isTerminating = true
        let saved = await app.store.flush()
        XCTAssertTrue(saved)
        dispose(app)
    }

    private func dispose(_ app: AppDelegate) {
        guard let manager = app.manager else { return }
        for session in manager.sessions.values { session.stop() }
    }

    private func waitUntil(_ predicate: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return predicate()
    }
}
