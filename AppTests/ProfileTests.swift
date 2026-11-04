import AppKit
import Foundation
import StowCore
import XCTest

@testable import Stow

/// Profile sessions on synthetic state in temporary folders, never the normal data folder.
@MainActor
final class ProfileTests: XCTestCase {
    func testDataFolderOpensAsSingleProfileWithoutWritingIndex() async throws {
        // A folder saved by a build without profiles, then a new installation.
        for seeded in [true, false] {
            let folder = try makeDirectory()
            defer { try? FileManager.default.removeItem(at: folder) }
            if seeded { try await seed(folder) }
            let manager = ProfileManager(dataFolder: folder, isDemo: false)
            defer { stop(manager) }
            let opened = await manager.start()
            XCTAssertTrue(opened)
            XCTAssertEqual(manager.profiles.map(\.isDataFolder), [true])
            XCTAssertEqual(manager.sessions.count, 1)
            let session = try XCTUnwrap(manager.activeSession)
            XCTAssertEqual(session.entry.name, "Main")
            XCTAssertEqual(manager.lastActiveID, session.entry.id)
            XCTAssertFalse(manager.showsProfileNames)
            XCTAssertEqual(session.board.title, "Stow")
            XCTAssertTrue(session.board.isVisible)
            // A new installation still asks before using GitHub.
            XCTAssertEqual(session.store.offersGitHubSetup, !seeded)
            let saved = await session.store.flush()
            XCTAssertTrue(saved)
            XCTAssertTrue(exists("state.json", in: folder))
            for name in [ProfileIndex.filename, ProfileIdentity.filename, ProfileCatalog.profilesDirectoryName] {
                XCTAssertFalse(exists(name, in: folder), "\(name) must not be written")
            }
        }
    }

    func testProfileLockedElsewhereStaysClosed() async throws {
        let folder = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        try await seed(folder)
        let stateURL = folder.appendingPathComponent("state.json")
        let before = try Data(contentsOf: stateURL)
        // flock refuses a second lock on the file within one process, as it would for another process.
        guard case .acquired(let held) = StateLock.acquire(forStateAt: stateURL) else {
            return XCTFail("The test could not take the profile lock")
        }
        defer { held.release() }
        let manager = ProfileManager(dataFolder: folder, isDemo: false)
        defer { stop(manager) }
        let opened = await manager.start()
        XCTAssertFalse(opened)
        XCTAssertTrue(manager.sessions.isEmpty)
        XCTAssertNil(manager.activeSession)
        XCTAssertEqual(manager.profiles.count, 1)
        XCTAssertEqual(try Data(contentsOf: stateURL), before)
    }

    func testStopClosesWindowsKeepsNotesDetachedAndReleasesLock() async throws {
        let folder = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        try await seed(folder, detached: true)
        let manager = ProfileManager(dataFolder: folder, isDemo: false)
        defer { stop(manager) }
        let opened = await manager.start()
        XCTAssertTrue(opened)
        let session = try XCTUnwrap(manager.activeSession)
        let note = try XCTUnwrap(session.store.state.notes.first)
        let board = try XCTUnwrap(session.board)
        let noteWindow = try XCTUnwrap(session.noteWindows[note.id])
        XCTAssertTrue(noteWindow.isVisible)

        session.stop()
        XCTAssertNil(session.board)
        XCTAssertTrue(session.noteWindows.isEmpty)
        XCTAssertFalse(board.isVisible)
        XCTAssertFalse(noteWindow.isVisible)
        // Closing a profile's windows is not closing its notes; they reopen with the profile.
        XCTAssertEqual(session.store.note(note.id)?.isDetached, true)
        guard case .acquired(let lock) = StateLock.acquire(forStateAt: folder.appendingPathComponent("state.json"))
        else { return XCTFail("Stopping must release the profile lock") }
        lock.release()
    }

    /// Closes each session's windows and releases its lock.
    private func stop(_ manager: ProfileManager) {
        for session in manager.sessions.values { session.stop() }
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "StowProfileTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func seed(_ folder: URL, detached: Bool = false) async throws {
        var state = AppState()
        state.githubEnabled = false
        state.notes = [Note(markdown: "Synthetic profile note", isDetached: detached)]
        try await StateRepository(url: folder.appendingPathComponent("state.json")).save(state)
    }

    private func exists(_ name: String, in folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path)
    }
}
