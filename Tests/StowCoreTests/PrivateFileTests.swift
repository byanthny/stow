import Foundation
import XCTest

@testable import StowCore

final class PrivateFileTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "StowPrivateFileTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func permissions(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    private func children(of directory: URL) throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
    }

    func testReadAcceptsTheExactLimitAndRefusesAnExtraByte() throws {
        let file = try directory().appendingPathComponent("synthetic.md")
        let exact = Data(repeating: 0x61, count: 65_537)
        try exact.write(to: file)
        XCTAssertEqual(try PrivateFile.read(file, maximumBytes: exact.count), exact)
        XCTAssertThrowsError(try PrivateFile.read(file, maximumBytes: exact.count - 1)) { error in
            XCTAssertEqual(error as? PrivateFileError, .tooLarge)
        }
        XCTAssertEqual(try Data(contentsOf: file), exact)
        try Data().write(to: file)
        XCTAssertEqual(try PrivateFile.read(file, maximumBytes: 0), Data())
    }

    func testReadIsNilWhenMissingAndRefusesLinksAndFolders() throws {
        let root = try directory()
        let target = root.appendingPathComponent("target.md")
        try Data("Synthetic target".utf8).write(to: target)
        let link = root.appendingPathComponent("link.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        XCTAssertNil(try PrivateFile.read(root.appendingPathComponent("missing.md"), maximumBytes: 100))
        XCTAssertThrowsError(try PrivateFile.read(link, maximumBytes: 100)) { error in
            XCTAssertEqual(error as? PrivateFileError, .unreadable)
        }
        XCTAssertThrowsError(try PrivateFile.read(root, maximumBytes: 100)) { error in
            XCTAssertEqual(error as? PrivateFileError, .unreadable)
        }
    }

    func testBoundedHandleReadStopsOneBytePastTheLimit() throws {
        let file = try directory().appendingPathComponent("synthetic.conf")
        try Data(repeating: 0x20, count: 10).write(to: file)
        let exact = try FileHandle(forReadingFrom: file)
        defer { try? exact.close() }
        XCTAssertEqual(try PrivateFile.read(exact, maximumBytes: 10).count, 10)
        let short = try FileHandle(forReadingFrom: file)
        defer { try? short.close() }
        XCTAssertThrowsError(try PrivateFile.read(short, maximumBytes: 9)) { error in
            XCTAssertEqual(error as? PrivateFileError, .tooLarge)
        }
        XCTAssertEqual(try short.offset(), 10)
    }

    func testCreateMakesAnOwnerOnlyFileAndRefusesAnythingAlreadyThere() throws {
        let root = try directory()
        let file = root.appendingPathComponent("new.md")
        let bytes = Data("# Synthetic private note\n".utf8)
        try PrivateFile.create(bytes, at: file)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        XCTAssertEqual(try permissions(file), 0o600)

        XCTAssertThrowsError(try PrivateFile.create(Data("replacement".utf8), at: file)) { error in
            XCTAssertEqual(error as? PrivateFileError, .exists)
        }
        XCTAssertEqual(try Data(contentsOf: file), bytes)

        let target = root.appendingPathComponent("target.md")
        try Data("Synthetic target".utf8).write(to: target)
        let link = root.appendingPathComponent("link.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try PrivateFile.create(bytes, at: link)) { error in
            XCTAssertEqual(error as? PrivateFileError, .exists)
        }
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "Synthetic target")
        XCTAssertEqual(try children(of: root), ["new.md", "target.md", "link.md"])
    }

    func testAtomicWriteReplacesALinkWithoutFollowingItAndLeavesNoTemporaryFile() throws {
        let root = try directory()
        let target = root.appendingPathComponent("target.md")
        try Data("Synthetic target".utf8).write(to: target)
        let destination = root.appendingPathComponent("state.json")
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: target)
        let bytes = Data("{\"synthetic\":true}".utf8)

        try PrivateFile.writeAtomically(bytes, to: destination)

        XCTAssertEqual(try Data(contentsOf: destination), bytes)
        XCTAssertEqual(try permissions(destination), 0o600)
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        XCTAssertEqual(attributes[.type] as? FileAttributeType, .typeRegular)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "Synthetic target")
        XCTAssertEqual(try children(of: root), ["target.md", "state.json"])
    }

    func testAtomicWriteWithoutReplacingRefusesAnExistingFile() throws {
        let root = try directory()
        let backup = root.appendingPathComponent("state.json.backup")
        try PrivateFile.writeAtomically(Data("first".utf8), to: backup, replacing: false)
        XCTAssertEqual(try permissions(backup), 0o600)
        XCTAssertThrowsError(try PrivateFile.writeAtomically(Data("second".utf8), to: backup, replacing: false)) {
            XCTAssertEqual($0 as? PrivateFileError, .unwritable)
        }
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), "first")
        XCTAssertEqual(try children(of: root), ["state.json.backup"])
    }

    func testEnsureFolderMakesOwnerOnlyFoldersAndRefusesALink() throws {
        let root = try directory()
        let folder = root.appendingPathComponent("profiles/nested", isDirectory: true)
        try PrivateFile.ensureFolder(folder)
        XCTAssertTrue(folder.isRealFolder)
        XCTAssertEqual(try permissions(folder), 0o700)
        try PrivateFile.ensureFolder(folder)

        let link = root.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)
        XCTAssertThrowsError(try PrivateFile.ensureFolder(link)) { error in
            XCTAssertEqual(error as? PrivateFileError, .unreadable)
        }
        let file = root.appendingPathComponent("file")
        try Data().write(to: file)
        XCTAssertThrowsError(try PrivateFile.ensureFolder(file)) { error in
            XCTAssertEqual(error as? PrivateFileError, .unreadable)
        }
    }

    func testCreateFolderMakesANewOwnerOnlyFolderAndRefusesAnythingAlreadyThere() throws {
        let root = try directory()
        let folder = root.appendingPathComponent("export", isDirectory: true)
        try PrivateFile.createFolder(folder)
        XCTAssertTrue(folder.isRealFolder)
        XCTAssertEqual(try permissions(folder), 0o700)
        XCTAssertThrowsError(try PrivateFile.createFolder(folder)) { error in
            XCTAssertEqual(error as? PrivateFileError, .exists)
        }
        let link = root.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)
        XCTAssertThrowsError(try PrivateFile.createFolder(link)) { error in
            XCTAssertEqual(error as? PrivateFileError, .exists)
        }
        XCTAssertThrowsError(try PrivateFile.createFolder(root.appendingPathComponent("missing/child"))) { error in
            XCTAssertEqual(error as? PrivateFileError, .unwritable)
        }
    }

    func testExistsSeesADanglingLink() throws {
        let root = try directory()
        let link = root.appendingPathComponent("dangling")
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: root.appendingPathComponent("nowhere"))
        XCTAssertTrue(try PrivateFile.exists(link))
        XCTAssertFalse(try PrivateFile.exists(root.appendingPathComponent("missing")))
        XCTAssertFalse(try PrivateFile.exists(link.appendingPathComponent("below")))
    }
}
