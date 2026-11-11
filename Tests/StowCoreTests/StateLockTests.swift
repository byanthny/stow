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
        XCTAssertEqual(kind(StateLock.acquire(forStateAt: directory.appendingPathComponent("state.json"))), "failed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    func testFolderOrFifoAtTheLockPathFails() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("folder.lock"), withIntermediateDirectories: false)
        XCTAssertEqual(kind(StateLock.acquire(named: "folder.lock", in: directory)), "failed")
        // A FIFO answers that it cannot lock, like a volume without flock.
        XCTAssertEqual(mkfifo(directory.appendingPathComponent("fifo.lock").path, 0o600), 0)
        XCTAssertEqual(kind(StateLock.acquire(named: "fifo.lock", in: directory)), "failed")
    }

    func testHardLinkAtTheLockPathFailsAndLeavesItsFileAlone() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let elsewhere = directory.appendingPathComponent("elsewhere")
        XCTAssertTrue(
            FileManager.default.createFile(
                atPath: elsewhere.path, contents: Data("kept".utf8), attributes: [.posixPermissions: 0o644]))
        XCTAssertEqual(link(elsewhere.path, directory.appendingPathComponent(StateLock.filename).path), 0)
        XCTAssertEqual(kind(StateLock.acquire(forStateAt: directory.appendingPathComponent("state.json"))), "failed")
        let mode = try FileManager.default.attributesOfItem(atPath: elsewhere.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o644)
        let other = open(elsewhere.path, O_RDWR | O_CLOEXEC | O_EXLOCK | O_NONBLOCK)
        XCTAssertGreaterThanOrEqual(other, 0, "The linked file must not stay locked")
        close(other)
    }

    func testLockExcludesBuildsThatLockWhileOpening() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent(StateLock.filename).path
        // Earlier builds take the lock with open(O_EXLOCK).
        func openLocked() -> (descriptor: Int32, error: Int32) {
            let descriptor = open(path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_EXLOCK | O_NONBLOCK, 0o600)
            return (descriptor, errno)
        }
        let earlier = openLocked()
        XCTAssertGreaterThanOrEqual(earlier.descriptor, 0)
        XCTAssertEqual(kind(StateLock.acquire(named: StateLock.filename, in: directory)), "held")
        close(earlier.descriptor)
        guard case .acquired(let lock) = StateLock.acquire(named: StateLock.filename, in: directory) else {
            return XCTFail("The lock must be free once the earlier build closes it")
        }
        let refused = openLocked()
        XCTAssertEqual(refused.descriptor, -1)
        XCTAssertEqual(refused.error, EWOULDBLOCK)
        lock.release()
        let after = openLocked()
        XCTAssertGreaterThanOrEqual(after.descriptor, 0)
        close(after.descriptor)
    }

    func testFolderThatCannotBeWrittenFailsUntilItHasALockFile() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = directory.appendingPathComponent("state.json")
        func setMode(_ mode: Int) throws {
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: directory.path)
        }
        defer { try? setMode(0o700) }
        try setMode(0o500)
        XCTAssertEqual(kind(StateLock.acquire(forStateAt: state)), "failed")
        // A lock file made while the folder could be written still locks.
        try setMode(0o700)
        XCTAssertEqual(kind(StateLock.acquire(forStateAt: state)), "acquired")
        try setMode(0o500)
        XCTAssertEqual(kind(StateLock.acquire(forStateAt: state)), "acquired")
    }

    func testLockFileWhoseModeCannotBeSetFails() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for code in [ENOTSUP, EOPNOTSUPP, EPERM] {
            let outcome = StateLock.acquire(named: "a.lock", in: directory) { _ in
                errno = code
                return -1
            }
            XCTAssertEqual(kind(outcome), "failed", "errno \(code)")
        }
        // The failed attempts dropped the lock they took.
        XCTAssertEqual(kind(StateLock.acquire(named: "a.lock", in: directory)), "acquired")
    }

    func testOnlyMissingLockSupportIsUnavailable() {
        XCTAssertEqual(kind(StateLock.outcome(ofLockError: EWOULDBLOCK)), "held")
        XCTAssertEqual(kind(StateLock.outcome(ofLockError: ENOTSUP)), "unavailable")
        XCTAssertEqual(kind(StateLock.outcome(ofLockError: EOPNOTSUPP)), "unavailable")
        for code in [ELOOP, EISDIR, EACCES, EPERM, EROFS, EIO, ENOSPC, ENOENT] {
            XCTAssertEqual(kind(StateLock.outcome(ofLockError: code)), "failed", "errno \(code)")
        }
    }

    func testNamedLocksAreIndependent() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        guard case .acquired(let instance) = StateLock.acquire(named: StateLock.instanceFilename, in: directory),
            case .acquired(let state) = StateLock.acquire(named: StateLock.filename, in: directory)
        else { return XCTFail("Locks with different names must not block each other") }
        XCTAssertEqual(StateLock.instanceFilename, ".stow-app.lock")
        instance.release()
        state.release()
    }

    func testSecondAcquireInSameProcessIsRefusedUntilRelease() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        guard case .acquired(let lock) = StateLock.acquire(named: "a.lock", in: directory) else {
            return XCTFail("The first acquire must succeed")
        }
        guard case .heldByAnotherProcess = StateLock.acquire(named: "a.lock", in: directory) else {
            return XCTFail("A second acquire of the same name must be refused while held")
        }
        lock.release()
        guard case .acquired(let again) = StateLock.acquire(named: "a.lock", in: directory) else {
            return XCTFail("The lock must be available again after release")
        }
        again.release()
    }

    private func kind(_ outcome: StateLock.Outcome) -> String {
        switch outcome {
        case .acquired(let lock):
            lock.release()
            return "acquired"
        case .heldByAnotherProcess: return "held"
        case .unavailable: return "unavailable"
        case .failed: return "failed"
        }
    }
}
