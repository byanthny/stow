import Foundation
import XCTest

@testable import StowCore

final class ProfileCatalogTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("stow-catalog-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        restorePermissions(at: root)
        try? FileManager.default.removeItem(at: root)
    }

    private func restorePermissions(at url: URL) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        let children = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        for child in children {
            let childURL = url.appendingPathComponent(child)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: childURL.path, isDirectory: &isDirectory), isDirectory.boolValue {
                restorePermissions(at: childURL)
            }
        }
    }

    private func catalog(uid: uid_t = getuid()) -> ProfileCatalog {
        ProfileCatalog(dataFolder: root, currentUserID: uid, trash: { _ in })
    }

    private func write(_ text: String, _ relative: String) throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func identity(_ id: UUID, _ name: String, color: String = "#336699") -> String {
        "{\"id\":\"\(id.uuidString)\",\"name\":\"\(name)\",\"color\":\"\(color)\"}"
    }

    @discardableResult
    private func addProfile(_ id: UUID = UUID(), name: String?) throws -> UUID {
        if let name {
            try write(identity(id, name), "profiles/\(id.uuidString)/identity.json")
        } else {
            try write("{}", "profiles/\(id.uuidString)/state.json")
        }
        return id
    }

    private func listing() throws -> [String] {
        try FileManager.default.subpathsOfDirectory(atPath: root.path).sorted()
    }

    func testEmptyFolderIsNewInstallation() async throws {
        let snapshot = try await catalog().load()
        XCTAssertTrue(snapshot.isNewInstallation)
        XCTAssertTrue(snapshot.profiles.isEmpty)
        XCTAssertEqual(snapshot.indexStatus, .absent)
        XCTAssertEqual(try listing(), [])
    }

    func testExistingStateBecomesMainWithoutWritingFiles() async throws {
        try write("{}", "state.json")
        let before = try listing()
        let snapshot = try await catalog().load()
        XCTAssertFalse(snapshot.isNewInstallation)
        XCTAssertEqual(snapshot.profiles.count, 1)
        let main = try XCTUnwrap(snapshot.profiles.first)
        XCTAssertTrue(main.isDataFolder)
        XCTAssertEqual(main.name, "Main")
        XCTAssertFalse(main.isArrival)
        XCTAssertEqual(main.folder.standardizedFileURL, root.standardizedFileURL)
        XCTAssertEqual(snapshot.indexStatus, .absent)
        XCTAssertEqual(try listing(), before)
    }

    func testDataFolderProfileKeepsOneIDWhileCatalogLives() async throws {
        try write("{}", "state.json")
        let catalog = catalog()
        let first = try await catalog.load()
        let second = try await catalog.load()
        XCTAssertEqual(first.profiles.first?.id, second.profiles.first?.id)
    }

    func testDataFolderIdentityProvidesIDAndName() async throws {
        let id = UUID()
        try write(identity(id, "Home"), "identity.json")
        let loaded = try await catalog().load()
        let main = try XCTUnwrap(loaded.profiles.first)
        XCTAssertEqual(main.id, id)
        XCTAssertEqual(main.name, "Home")
        XCTAssertTrue(main.isDataFolder)
        XCTAssertFalse(main.isArrival)
    }

    func testProfileFoldersAreFoundWithoutIndex() async throws {
        let id = try addProfile(name: "Work")
        let snapshot = try await catalog().load()
        XCTAssertFalse(snapshot.isNewInstallation)
        let entry = try XCTUnwrap(snapshot.profiles.first)
        XCTAssertEqual(snapshot.profiles.count, 1)
        XCTAssertEqual(entry.id, id)
        XCTAssertEqual(entry.name, "Work")
        XCTAssertEqual(entry.color, "#336699")
        XCTAssertFalse(entry.isDataFolder)
        XCTAssertTrue(entry.isArrival)
    }

    func testLinksNonUUIDAndForeignFoldersAreIgnored() async throws {
        let target = root.appendingPathComponent("elsewhere/\(UUID().uuidString)")
        let linkedID = UUID()
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data(identity(linkedID, "Linked").utf8).write(to: target.appendingPathComponent("identity.json"))
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("profiles"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("profiles/\(linkedID.uuidString)"), withDestinationURL: target)
        try write("{}", "profiles/notes/state.json")
        let kept = try addProfile(name: "Kept")

        let snapshot = try await catalog().load()
        XCTAssertEqual(snapshot.profiles.map(\.id), [kept])

        let foreign = try await catalog(uid: getuid() + 1).load()
        XCTAssertTrue(foreign.profiles.isEmpty)
    }

    func testFolderWithoutProfileDataIsIgnored() async throws {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("profiles/\(UUID().uuidString)"), withIntermediateDirectories: true)
        let snapshot = try await catalog().load()
        XCTAssertTrue(snapshot.profiles.isEmpty)
        XCTAssertTrue(snapshot.isNewInstallation)
    }

    func testMismatchedIdentityFallsBackToUnnamed() async throws {
        let id = UUID()
        try write(identity(UUID(), "Other"), "profiles/\(id.uuidString)/identity.json")
        let loaded = try await catalog().load()
        let entry = try XCTUnwrap(loaded.profiles.first)
        XCTAssertEqual(entry.id, id)
        XCTAssertEqual(entry.name, "Unnamed profile")
    }

    func testCorruptOrNewerIndexIsPreservedAndNeedsReset() async throws {
        try write("{}", "state.json")
        try addProfile(name: "Zed")
        try addProfile(name: "Alpha")
        for bytes in ["not json", "{\"schemaVersion\":99,\"future\":true}"] {
            try write(bytes, ProfileIndex.filename)
            let snapshot = try await catalog().load()
            XCTAssertEqual(snapshot.indexStatus, .needsReset)
            XCTAssertFalse(snapshot.isNewInstallation)
            XCTAssertEqual(snapshot.profiles.map(\.name), ["Alpha", "Main", "Zed"])
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(ProfileIndex.filename)), Data(bytes.utf8))
        }
    }

    func testIndexOnlyIsNotANewInstallation() async throws {
        try write(#"{"schemaVersion":1}"#, ProfileIndex.filename)
        let snapshot = try await catalog().load()
        XCTAssertFalse(snapshot.isNewInstallation)
        XCTAssertEqual(snapshot.indexStatus, .loaded)
    }

    func testIndexOrderWinsAndUnknownOrDuplicateIDsAreIgnored() async throws {
        let b = try addProfile(name: "Bravo")
        let a = try addProfile(name: "Alpha")
        let c = try addProfile(name: "Charlie")
        var index = ProfileIndex()
        index.order = [c, UUID(), c, b]
        try JSONEncoder().encode(index).write(to: root.appendingPathComponent(ProfileIndex.filename))
        let snapshot = try await catalog().load()
        XCTAssertEqual(snapshot.indexStatus, .loaded)
        XCTAssertEqual(snapshot.profiles.map(\.id), [c, b, a])
        XCTAssertEqual(snapshot.index, index)
    }

    func testDuplicateNamesAreNumberedOnScreenOnly() async throws {
        let first = try addProfile(name: "Work")
        let second = try addProfile(name: "work")
        var index = ProfileIndex()
        index.order = [first, second]
        try JSONEncoder().encode(index).write(to: root.appendingPathComponent(ProfileIndex.filename))
        let files = [first, second].map { root.appendingPathComponent("profiles/\($0.uuidString)/identity.json") }
        let before = try files.map { try Data(contentsOf: $0) }
        let snapshot = try await catalog().load()
        XCTAssertEqual(snapshot.profiles.map(\.name), ["Work", "work 2"])
        XCTAssertEqual(try files.map { try Data(contentsOf: $0) }, before)
    }

    func testSeenProfilesAreNotArrivals() async throws {
        let seen = try addProfile(name: "Seen")
        let fresh = try addProfile(name: "Fresh")
        var index = ProfileIndex()
        index.seenIDs = [seen]
        try JSONEncoder().encode(index).write(to: root.appendingPathComponent(ProfileIndex.filename))
        let snapshot = try await catalog().load()
        let arrivals = Dictionary(uniqueKeysWithValues: snapshot.profiles.map { ($0.id, $0.isArrival) })
        XCTAssertEqual(arrivals[seen], false)
        XCTAssertEqual(arrivals[fresh], true)
    }

    // MARK: skipping and numbering

    func testUnreadableProfileFolderIsSkippedWhileOthersLoad() async throws {
        try write("{}", "state.json")
        let good = try addProfile(name: "Good")
        let locked = try addProfile(name: "Locked")
        let lockedFolder = root.appendingPathComponent("profiles/\(locked.uuidString)")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: lockedFolder.path)
        let snapshot = try await catalog().load()
        XCTAssertEqual(Set(snapshot.profiles.map(\.name)), ["Main", "Good"])
        XCTAssertTrue(snapshot.profiles.contains { $0.id == good })
    }

    func testUnlistableProfilesFolderStillLoadsDataFolderProfile() async throws {
        try write("{}", "state.json")
        try addProfile(name: "Hidden")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000], ofItemAtPath: root.appendingPathComponent("profiles").path)
        let snapshot = try await catalog().load()
        XCTAssertEqual(snapshot.profiles.map(\.name), ["Main"])
    }

    func testIdenticalDuplicateNamesDisplayNumbered() async throws {
        let first = try addProfile(name: "Work")
        let second = try addProfile(name: "Work")
        var index = ProfileIndex()
        index.order = [first, second]
        try JSONEncoder().encode(index).write(to: root.appendingPathComponent(ProfileIndex.filename))
        let snapshot = try await catalog().load()
        XCTAssertEqual(snapshot.profiles.map(\.name), ["Work", "Work 2"])
    }

    func testFolderOwnedByAnotherUserIsIgnoredWhileProfilesFolderIsOwned() async throws {
        let mine = try addProfile(name: "Mine")
        let theirs = try addProfile(name: "Theirs")
        let me = getuid()
        let catalog = ProfileCatalog(
            dataFolder: root, currentUserID: me, trash: { _ in },
            ownerOf: { $0.lastPathComponent == theirs.uuidString ? me + 1 : me })
        let snapshot = try await catalog.load()
        XCTAssertEqual(snapshot.profiles.map(\.id), [mine])
    }

    // MARK: changes

    private func mode(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    func testCreateWritesFolderIdentityAndIndex() async throws {
        try write("{}", "state.json")
        let catalog = catalog()
        let main = try await catalog.load().profiles[0]
        let entry = try await catalog.createProfile(name: "  Work\u{200B} ", color: "#336699")
        XCTAssertEqual(entry.name, "Work")
        XCTAssertFalse(entry.isDataFolder)
        let folder = root.appendingPathComponent("profiles/\(entry.id.uuidString)")
        XCTAssertEqual(try mode(folder), 0o700)
        let stored = try ProfileIdentity.decode(
            Data(contentsOf: folder.appendingPathComponent("identity.json")), folderID: entry.id)
        XCTAssertEqual(stored, ProfileIdentity(id: entry.id, name: "Work", color: "#336699"))
        let indexURL = root.appendingPathComponent(ProfileIndex.filename)
        XCTAssertEqual(try mode(indexURL), 0o600)
        let index = try ProfileIndex.decode(Data(contentsOf: indexURL))
        XCTAssertEqual(index.order, [main.id, entry.id])
        XCTAssertTrue(index.seenIDs.contains(entry.id))
        let mainIdentity = try ProfileIdentity.decode(
            Data(contentsOf: root.appendingPathComponent("identity.json")), folderID: nil)
        XCTAssertEqual(mainIdentity.id, main.id)
        XCTAssertEqual(mainIdentity.name, "Main")
        let reloaded = try await catalog.load()
        XCTAssertEqual(reloaded.indexStatus, .loaded)
        XCTAssertEqual(reloaded.profiles.map(\.id), [main.id, entry.id])
        XCTAssertFalse(try XCTUnwrap(reloaded.profiles.last).isArrival)
        let fresh = try await self.catalog().load()
        XCTAssertEqual(fresh.profiles.first?.id, main.id)
    }

    func testEmptyAndDuplicateNamesAreRejected() async throws {
        let catalog = catalog()
        _ = try await catalog.createProfile(name: "Work", color: "#336699")
        await assertThrows(.duplicateName) { _ = try await catalog.createProfile(name: "work", color: "#336699") }
        await assertThrows(.emptyName) { _ = try await catalog.createProfile(name: "  ", color: "#336699") }
        await assertThrows(.invalidColor) { _ = try await catalog.createProfile(name: "Other", color: "#12") }
        let snapshot = try await catalog.load()
        XCTAssertEqual(snapshot.profiles.map(\.name), ["Work"])
    }

    func testChangesWaitForResetThenSucceed() async throws {
        let id = try addProfile(name: "Work")
        let corrupt = "not json"
        try write(corrupt, ProfileIndex.filename)
        let catalog = catalog()
        await assertThrows(.indexNeedsReset) { try await catalog.rename(id, to: "Home") }
        await assertThrows(.indexNeedsReset) { try await catalog.setAlwaysShowProfileName(true) }
        await assertThrows(.indexNeedsReset) { _ = try await catalog.createProfile(name: "New", color: "#336699") }
        let backup = try await catalog.resetIndex()
        XCTAssertEqual(try Data(contentsOf: backup), Data(corrupt.utf8))
        XCTAssertEqual(try mode(root.appendingPathComponent(ProfileIndex.filename)), 0o600)
        try await catalog.rename(id, to: "Home")
        let snapshot = try await catalog.load()
        XCTAssertEqual(snapshot.indexStatus, .loaded)
        XCTAssertEqual(snapshot.profiles.map(\.name), ["Home"])
        XCTAssertTrue(snapshot.index.seenIDs.isEmpty)
        XCTAssertTrue(try XCTUnwrap(snapshot.profiles.first).isArrival)
    }

    func testIndexWriteFailureLeavesProfilesUsable() async throws {
        try write("{}", "state.json")
        let work = try addProfile(name: "Work")
        let catalog = catalog()
        let before = try await catalog.load()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
        await assertThrows(.unwritable) { _ = try await catalog.createProfile(name: "New", color: "#336699") }
        let after = try await catalog.load()
        XCTAssertEqual(after.profiles.map(\.id), before.profiles.map(\.id))
        XCTAssertTrue(after.profiles.contains { $0.id == work })
        XCTAssertEqual(after.profiles.count, 2)
    }

    func testRenameAndColorWriteIdentityAndKeepOtherFields() async throws {
        let id = try addProfile(name: "Work")
        let other = try addProfile(name: "Home")
        let catalog = catalog()
        try await catalog.rename(id, to: "Office")
        try await catalog.setColor(id, to: "#AABBCC")
        await assertThrows(.duplicateName) { try await catalog.rename(id, to: "HOME") }
        await assertThrows(.invalidColor) { try await catalog.setColor(id, to: "red") }
        await assertThrows(.notFound) { try await catalog.rename(UUID(), to: "Nope") }
        try await catalog.rename(id, to: "office")
        let stored = try ProfileIdentity.decode(
            Data(contentsOf: root.appendingPathComponent("profiles/\(id.uuidString)/identity.json")), folderID: id)
        XCTAssertEqual(stored, ProfileIdentity(id: id, name: "office", color: "#AABBCC"))
        let snapshot = try await catalog.load()
        XCTAssertTrue(snapshot.profiles.contains { $0.id == other && $0.name == "Home" })
    }

    func testMoveReordersAndClamps() async throws {
        let catalog = catalog()
        let a = try await catalog.createProfile(name: "A", color: "#111111").id
        let b = try await catalog.createProfile(name: "B", color: "#222222").id
        let c = try await catalog.createProfile(name: "C", color: "#333333").id
        try await catalog.move(c, by: -1)
        let order1 = try await catalog.load().profiles.map(\.id)
        XCTAssertEqual(order1, [a, c, b])
        try await catalog.move(a, by: 10)
        let order2 = try await catalog.load().profiles.map(\.id)
        XCTAssertEqual(order2, [c, b, a])
        try await catalog.move(a, by: -10)
        let order3 = try await catalog.load().profiles.map(\.id)
        XCTAssertEqual(order3, [a, c, b])
        await assertThrows(.notFound) { try await catalog.move(UUID(), by: 1) }
    }

    func testSessionSeenAndDisplaySettingPersist() async throws {
        let id = try addProfile(name: "Work")
        let catalog = catalog()
        try await catalog.markSeen(id)
        try await catalog.markSeen(id)
        try await catalog.setAlwaysShowProfileName(true)
        try await catalog.recordSession(open: [.init(id: id, isHidden: true), .init(id: UUID(), isHidden: false)], lastActiveID: id)
        let snapshot = try await catalog.load()
        XCTAssertEqual(snapshot.index.seenIDs, [id])
        XCTAssertTrue(snapshot.index.alwaysShowProfileName)
        XCTAssertEqual(snapshot.index.open, [.init(id: id, isHidden: true)])
        XCTAssertEqual(snapshot.index.lastActiveID, id)
        XCTAssertFalse(try XCTUnwrap(snapshot.profiles.first).isArrival)
    }

    private func assertThrows(
        _ expected: ProfileError, file: StaticString = #filePath, line: UInt = #line,
        _ body: () async throws -> Void
    ) async {
        do {
            try await body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? ProfileError, expected, file: file, line: line)
        }
    }
}
