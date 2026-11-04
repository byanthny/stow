import Foundation
import XCTest

@testable import StowCore

final class StateLockTests: XCTestCase {
    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "StowStateLockTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func testSecondWriterIsRefusedUntilTheFirstReleases() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = directory.appendingPathComponent("state.json")
        guard case .acquired(let first) = StateLock.acquire(forStateAt: state) else {
            return XCTFail("The first writer must acquire the lock")
        }
        guard case .heldByAnotherProcess = StateLock.acquire(forStateAt: state) else {
            return XCTFail("A second writer must be refused while the first holds the lock")
        }
        first.release()
        guard case .acquired(let second) = StateLock.acquire(forStateAt: state) else {
            return XCTFail("The lock must be available again after release")
        }
        second.release()
    }

    func testLockIsDroppedWhenItsOwnerGoesAway() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = directory.appendingPathComponent("state.json")
        // Like a process exit or crash: the descriptor closes and the kernel drops the lock.
        func holdBriefly() -> Bool {
            if case .acquired = StateLock.acquire(forStateAt: state) { return true }
            return false
        }
        XCTAssertTrue(holdBriefly())
        guard case .acquired(let next) = StateLock.acquire(forStateAt: state) else {
            return XCTFail("A released owner must not leave a stale lock")
        }
        next.release()
    }

    func testLockFileAndNewFolderAreOwnerOnly() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Stow", isDirectory: true)
        guard case .acquired(let lock) = StateLock.acquire(forStateAt: directory.appendingPathComponent("state.json"))
        else { return XCTFail("The lock must create its private folder") }
        defer { lock.release() }
        let file = directory.appendingPathComponent(StateLock.filename)
        let fileMode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        let folderMode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(fileMode?.intValue, 0o600)
        XCTAssertEqual(folderMode?.intValue, 0o700)
    }

    func testPlantedSymlinkIsNeverFollowed() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("elsewhere")
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent(StateLock.filename), withDestinationURL: target)
        guard case .unavailable = StateLock.acquire(forStateAt: directory.appendingPathComponent("state.json")) else {
            return XCTFail("A symlinked lock path must not be used")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }
}
