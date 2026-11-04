import Foundation
import XCTest

@testable import StowCore

final class ProfileCatalogTests: XCTestCase {
    private var root: URL!
    /// Stands in for the Trash. Tests never use the real one.
    private var bin: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("stow-catalog-\(UUID().uuidString)", isDirectory: true)
        bin = FileManager.default.temporaryDirectory
            .appendingPathComponent("stow-trash-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for folder in [root, bin].compactMap({ $0 }) {
            restorePermissions(at: folder)
            try? FileManager.default.removeItem(at: folder)
        }
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

    /// Trashing moves the folder into `bin`, unless the test passes its own trash operation.
    private func catalog(uid: uid_t = getuid(), trash: (@Sendable (URL) throws -> Void)? = nil) -> ProfileCatalog {
        let bin: URL = bin
        let intoBin: @Sendable (URL) throws -> Void = {
            try FileManager.default.moveItem(at: $0, to: bin.appendingPathComponent($0.lastPathComponent))
        }
        return ProfileCatalog(dataFolder: root, currentUserID: uid, trash: trash ?? intoBin)
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
        await assertThrows(.indexNeedsReset) { try await catalog.trash(id) }
        XCTAssertEqual(try trashed(), [])
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

    func testColorChangeKeepsAnIdentityItCannotRead() async throws {
        let catalog = catalog()
        for damaged in ["not json", identity(UUID(), "Other")] {
            let id = UUID()
            try write("{}", "profiles/\(id.uuidString)/state.json")
            try write(damaged, "profiles/\(id.uuidString)/identity.json")
            await assertThrows(.invalidIdentity) { try await catalog.setColor(id, to: "#AABBCC") }
            XCTAssertEqual(
                try Data(contentsOf: root.appendingPathComponent("profiles/\(id.uuidString)/identity.json")),
                Data(damaged.utf8))
        }
        let bare = try addProfile(name: nil)
        try await catalog.setColor(bare, to: "#AABBCC")
        let stored = try ProfileIdentity.decode(
            Data(contentsOf: root.appendingPathComponent("profiles/\(bare.uuidString)/identity.json")), folderID: bare)
        XCTAssertEqual(stored, ProfileIdentity(id: bare, name: "Unnamed profile", color: "#AABBCC"))
    }

    func testMoveKeepsThePlaceOfASkippedProfile() async throws {
        let a = try addProfile(name: "A")
        let skipped = try addProfile(name: "X")
        let b = try addProfile(name: "B")
        let c = try addProfile(name: "C")
        var index = ProfileIndex()
        index.order = [a, skipped, b, c]
        try JSONEncoder().encode(index).write(to: root.appendingPathComponent(ProfileIndex.filename))
        let me = getuid()
        let skipping = ProfileCatalog(
            dataFolder: root, currentUserID: me, trash: { _ in },
            ownerOf: { $0.lastPathComponent == skipped.uuidString ? me + 1 : me })
        try await skipping.move(c, by: -1)
        let saved = try ProfileIndex.decode(Data(contentsOf: root.appendingPathComponent(ProfileIndex.filename)))
        XCTAssertEqual(saved.order, [a, skipped, c, b])
        let snapshot = try await catalog().load()
        XCTAssertEqual(snapshot.profiles.map(\.id), [a, skipped, c, b])
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

    // MARK: deleting

    private func trashed() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: bin.path).sorted()
    }

    private func exists(_ relative: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(relative).path)
    }

    private func names(in folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    /// Every path under `folder` with its text; folders read as "<folder>".
    private func tree(_ folder: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        for path in try FileManager.default.subpathsOfDirectory(atPath: folder.path) {
            let url = folder.appendingPathComponent(path)
            var isDirectory: ObjCBool = false
            _ = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            result[path] =
                isDirectory.boolValue ? "<folder>" : String(decoding: try Data(contentsOf: url), as: UTF8.self)
        }
        return result
    }

    /// A data folder profile holding each kind of file that saves, restores, and recovery leave there,
    /// by the names Stow writes. Returns the top-level names.
    private func seedDataFolderProfile() throws -> [String] {
        let restored = "notes-\(UUID().uuidString)"
        let files = [
            "state.json": "{}",
            "notes/\(UUID().uuidString).md": "# First",
            "\(restored)/\(UUID().uuidString).md": "# Restored",
            "state.json.backup-\(UUID().uuidString)": "{\"backup\":1}",
            "state.json.before-restore-\(UUID().uuidString)": "{\"backup\":2}",
            "state.json.v1-\(UUID().uuidString).backup": "{\"backup\":3}",
            "notes.backup-\(UUID().uuidString)/\(UUID().uuidString).md": "# Recovered",
            "\(restored).backup-\(UUID().uuidString)/\(UUID().uuidString).md": "# Recovered after restore",
            "pre-restore-\(UUID().uuidString).stowbackup": "saved before a restore",
        ]
        for (path, text) in files { try write(text, path) }
        return Set(files.keys.map { String($0.split(separator: "/")[0]) }).sorted()
    }

    func testTrashMovesProfileFolderAndUpdatesIndex() async throws {
        try write("{}", "state.json")
        let catalog = catalog()
        let main = try await catalog.load().profiles[0].id
        let work = try await catalog.createProfile(name: "Work", color: "#336699").id
        let home = try await catalog.createProfile(name: "Home", color: "#336699").id
        let play = try await catalog.createProfile(name: "Play", color: "#336699").id
        try await catalog.recordSession(
            open: [.init(id: work, isHidden: false), .init(id: home, isHidden: true)], lastActiveID: work)

        try await catalog.trash(work)
        XCTAssertEqual(try trashed(), [work.uuidString])
        XCTAssertEqual(
            try names(in: bin.appendingPathComponent(work.uuidString)), [StateLock.filename, "identity.json"])
        XCTAssertFalse(exists("profiles/\(work.uuidString)"))
        var snapshot = try await catalog.load()
        XCTAssertEqual(snapshot.profiles.map(\.id), [main, home, play])
        XCTAssertEqual(snapshot.index.order, [main, home, play])
        XCTAssertEqual(snapshot.index.open, [.init(id: home, isHidden: true)])
        XCTAssertEqual(snapshot.index.seenIDs, [home, play])
        XCTAssertNil(snapshot.index.lastActiveID)

        try await catalog.recordSession(open: [.init(id: home, isHidden: true)], lastActiveID: home)
        try await catalog.trash(play)
        snapshot = try await catalog.load()
        XCTAssertEqual(snapshot.index.order, [main, home])
        XCTAssertEqual(snapshot.index.lastActiveID, home)
        XCTAssertEqual(try trashed(), [work.uuidString, play.uuidString].sorted())
    }

    func testFirstProfileMovesIntoProfilesThenTrash() async throws {
        let items = try seedDataFolderProfile()
        let staying = [StateLock.filename, StateLock.instanceFilename, "notes-draft.txt", "state.json~"]
        for name in staying { try write("", name) }
        let catalog = catalog()
        let main = try await catalog.load().profiles[0].id
        let work = try await catalog.createProfile(name: "Work", color: "#336699").id
        let moving = Set(items + ["identity.json"])
        let expected = try tree(root).filter { moving.contains(String($0.key.split(separator: "/")[0])) }

        try await catalog.trash(main)

        XCTAssertEqual(try trashed(), [main.uuidString])
        XCTAssertEqual(try tree(bin.appendingPathComponent(main.uuidString)), expected)
        XCTAssertEqual(try names(in: root), (staying + ["profiles", ProfileIndex.filename]).sorted())
        XCTAssertEqual(try names(in: root.appendingPathComponent("profiles")), [work.uuidString])
        let snapshot = try await catalog.load()
        XCTAssertEqual(snapshot.profiles.map(\.id), [work])
        XCTAssertEqual(snapshot.index.order, [work])
    }

    func testDeletingMainReusesOnlyAnEmptyLeftoverFolder() async throws {
        let items = try seedDataFolderProfile()
        try write("", StateLock.filename)
        let catalog = catalog()
        let main = try await catalog.load().profiles[0].id
        _ = try await catalog.createProfile(name: "Work", color: "#336699")
        let leftover = root.appendingPathComponent("profiles/\(main.uuidString)")

        // A folder with anything in it, a link to an empty folder, or an empty folder while a journal is waiting
        // is never used.
        try write("stray", "profiles/\(main.uuidString)/.DS_Store")
        var before = try tree(root)
        await assertThrows(.unwritable) { try await catalog.trash(main) }
        XCTAssertEqual(try tree(root), before)
        try FileManager.default.removeItem(at: leftover)
        let elsewhere = root.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: leftover, withDestinationURL: elsewhere)
        before = try tree(root)
        await assertThrows(.unwritable) { try await catalog.trash(main) }
        XCTAssertEqual(try tree(root), before)
        XCTAssertEqual(try names(in: elsewhere), [])
        try FileManager.default.removeItem(at: leftover)
        try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: false)
        try write("not json", ".moving.json")
        before = try tree(root)
        await assertThrows(.unwritable) { try await catalog.trash(main) }
        XCTAssertEqual(try tree(root), before)
        XCTAssertEqual(try trashed(), [])

        // An empty folder left by a crash right after it was made is reused, and made owner-only.
        try FileManager.default.removeItem(at: root.appendingPathComponent(".moving.json"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: leftover.path)
        try await catalog.trash(main)
        XCTAssertEqual(try trashed(), [main.uuidString])
        let moved = bin.appendingPathComponent(main.uuidString)
        XCTAssertEqual(try names(in: moved), (items + ["identity.json"]).sorted())
        XCTAssertEqual(try mode(moved), 0o700)
        XCTAssertFalse(exists(".moving.json"))
    }

    func testDataFolderProfileStartedAfterTrashGetsItsOwnID() async throws {
        try write("{}", "state.json")
        try addProfile(name: "Work")
        let catalog = catalog()
        let before = try await catalog.load()
        let trashedID = try XCTUnwrap(before.profiles.first(where: \.isDataFolder)).id
        try await catalog.trash(trashedID)
        // An older build then starts fresh in the data folder. Its profile must not take the trashed one's ID,
        // or the trashed folder would be hidden if it were put back.
        try write("{}", "state.json")
        let after = try await catalog.load()
        XCTAssertNotEqual(try XCTUnwrap(after.profiles.first(where: \.isDataFolder)).id, trashedID)
    }

    func testLastProfileCannotBeDeleted() async throws {
        try write("{}", "state.json")
        let catalog = catalog()
        let main = try await catalog.load().profiles[0].id
        let before = try tree(root)
        await assertThrows(.lastProfile) { try await catalog.trash(main) }
        await assertThrows(.notFound) { try await catalog.trash(UUID()) }
        XCTAssertEqual(try tree(root), before)
        XCTAssertEqual(try trashed(), [])
    }

    func testLockedProfileIsRefused() async throws {
        try write("{}", "state.json")
        let catalog = catalog()
        let main = try await catalog.load().profiles[0]
        let work = try await catalog.createProfile(name: "Work", color: "#336699")
        for entry in [work, main] {
            let state = entry.folder.appendingPathComponent("state.json")
            guard case .acquired(let lock) = StateLock.acquire(forStateAt: state) else {
                return XCTFail("the test must hold the profile's lock")
            }
            let before = try tree(root)
            await assertThrows(.inUse) { try await catalog.trash(entry.id) }
            XCTAssertEqual(try tree(root), before)
            lock.release()
        }
        XCTAssertEqual(try trashed(), [])
    }

    func testProfileThatCannotBeLockedIsStillTrashed() async throws {
        try write("{}", "state.json")
        let catalog = catalog()
        let work = try await catalog.createProfile(name: "Work", color: "#336699")
        // A planted link makes the lock unavailable, as on a volume without flock.
        try FileManager.default.createSymbolicLink(
            at: work.folder.appendingPathComponent(StateLock.filename),
            withDestinationURL: root.appendingPathComponent("missing"))
        try await catalog.trash(work.id)
        XCTAssertEqual(try trashed(), [work.id.uuidString])
    }

    func testFailedMovePutsEveryFileBack() async throws {
        let items = try seedDataFolderProfile()
        try write("", StateLock.filename)
        let catalog = catalog()
        let main = try await catalog.load().profiles[0].id
        _ = try await catalog.createProfile(name: "Work", color: "#336699")
        // A folder without write access cannot change parent, so the move fails after the first files moved.
        let stuck = try XCTUnwrap(items.first { $0.hasPrefix("notes-") && !$0.contains(".backup-") })
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500], ofItemAtPath: root.appendingPathComponent(stuck).path)
        let before = try tree(root)
        await assertThrows(.unwritable) { try await catalog.trash(main) }
        XCTAssertEqual(try tree(root), before)
        XCTAssertEqual(try trashed(), [])
        let snapshot = try await catalog.load()
        XCTAssertTrue(snapshot.profiles.contains { $0.id == main && $0.isDataFolder })
    }

    func testFailedTrashLeavesProfilesInPlace() async throws {
        _ = try seedDataFolderProfile()
        try write("", StateLock.filename)
        let refusing = catalog(trash: { _ in throw CocoaError(.fileWriteNoPermission) })
        let main = try await refusing.load().profiles[0].id
        let work = try await refusing.createProfile(name: "Work", color: "#336699").id
        try write("", "profiles/\(work.uuidString)/\(StateLock.filename)")
        let before = try tree(root)
        await assertThrows(.unwritable) { try await refusing.trash(work) }
        await assertThrows(.unwritable) { try await refusing.trash(main) }
        XCTAssertEqual(try tree(root), before)
        let snapshot = try await refusing.load()
        XCTAssertEqual(snapshot.profiles.map(\.id), [main, work])
        XCTAssertTrue(try XCTUnwrap(snapshot.profiles.first).isDataFolder)
    }

    func testTrashSucceedsWhenOnlyTheIndexUpdateFails() async throws {
        try write("{}", "state.json")
        let catalog = catalog()
        let work = try await catalog.createProfile(name: "Work", color: "#336699").id
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
        try await catalog.trash(work)
        XCTAssertEqual(try trashed(), [work.uuidString])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let snapshot = try await catalog.load()
        XCTAssertEqual(snapshot.profiles.count, 1)
        XCTAssertTrue(snapshot.index.order.contains(work))
    }

    // MARK: finishing an interrupted move

    private func journal(_ id: UUID, _ items: [String], version: Int = 1) -> String {
        let list = items.map { "\"\($0)\"" }.joined(separator: ",")
        return "{\"schemaVersion\":\(version),\"id\":\"\(id.uuidString)\",\"items\":[\(list)]}"
    }

    /// A deletion of the data folder profile that stopped after moving half of its files.
    private func seedInterruptedMove() throws -> (id: UUID, items: [String]) {
        let id = UUID()
        let restored = "notes-\(UUID().uuidString)"
        let backup = "state.json.backup-\(UUID().uuidString)"
        let saved = "pre-restore-\(UUID().uuidString).stowbackup"
        try write("{}", "profiles/\(id.uuidString)/state.json")
        try write(identity(id, "Home"), "profiles/\(id.uuidString)/identity.json")
        try write("# Moved", "profiles/\(id.uuidString)/notes/\(UUID().uuidString).md")
        try write("# Waiting", "\(restored)/\(UUID().uuidString).md")
        try write("{}", backup)
        try write("saved before a restore", saved)
        let items = ["state.json", "identity.json", "notes", restored, backup, saved]
        try write(journal(id, items), ".moving.json")
        return (id, items)
    }

    func testInterruptedFirstProfileMoveIsFinishedAtLoad() async throws {
        let (id, items) = try seedInterruptedMove()
        let snapshot = try await catalog().load()
        let entry = try XCTUnwrap(snapshot.profiles.first)
        XCTAssertEqual(snapshot.profiles.map(\.id), [id])
        XCTAssertFalse(entry.isDataFolder)
        XCTAssertEqual(entry.name, "Home")
        XCTAssertEqual(
            entry.folder.standardizedFileURL,
            root.appendingPathComponent("profiles/\(id.uuidString)").standardizedFileURL)
        XCTAssertEqual(try names(in: entry.folder), (items + [StateLock.filename]).sorted())
        XCTAssertEqual(try names(in: root), [StateLock.filename, "profiles"])
        XCTAssertEqual(try trashed(), [])
    }

    func testInterruptedMoveWaitsWhileEitherFolderIsLocked() async throws {
        let (id, items) = try seedInterruptedMove()
        let destination = root.appendingPathComponent("profiles/\(id.uuidString)")
        let catalog = catalog()
        for folder in [root!, destination] {
            guard case .acquired(let lock) = StateLock.acquire(forStateAt: folder.appendingPathComponent("state.json"))
            else { return XCTFail("the test must hold the lock") }
            let before = try tree(root)
            let waiting = try await catalog.load()
            XCTAssertEqual(try tree(root), before)
            XCTAssertEqual(waiting.profiles.map(\.id), [id])
            lock.release()
        }
        _ = try await catalog.load()
        XCTAssertFalse(exists(".moving.json"))
        XCTAssertEqual(try names(in: destination), (items + [StateLock.filename]).sorted())
        XCTAssertEqual(try trashed(), [])
    }

    func testJournalForAFolderAlreadyTrashedIsDropped() async throws {
        // The folder reached the Trash before its journal was removed, and an older build then started fresh.
        let id = UUID()
        try write(journal(id, ["state.json", "notes"]), ".moving.json")
        try write("{}", "state.json")
        try write("# New", "notes/\(UUID().uuidString).md")
        let snapshot = try await catalog().load()
        XCTAssertFalse(exists(".moving.json"))
        XCTAssertFalse(exists("profiles/\(id.uuidString)"))
        XCTAssertTrue(exists("state.json"))
        XCTAssertTrue(exists("notes"))
        XCTAssertEqual(snapshot.profiles.count, 1)
        XCTAssertTrue(try XCTUnwrap(snapshot.profiles.first).isDataFolder)
    }

    func testJournalThatCannotBeTrustedIsLeftAlone() async throws {
        let id = UUID()
        try write("{}", "profiles/\(id.uuidString)/state.json")
        try write("{}", "state.json")
        try write("# Here", "notes/\(UUID().uuidString).md")
        try write(#"{"schemaVersion":1}"#, ProfileIndex.filename)
        try write("", StateLock.filename)
        for untrusted in [
            "not json",
            journal(id, ["notes"], version: 2),
            journal(id, ["notes", ProfileIndex.filename]),
            journal(id, ["notes", "../elsewhere"]),
        ] {
            try write(untrusted, ".moving.json")
            let before = try tree(root)
            _ = try await catalog().load()
            XCTAssertEqual(try tree(root), before)
        }
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
