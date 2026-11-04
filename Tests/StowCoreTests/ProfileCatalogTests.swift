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
        try? FileManager.default.removeItem(at: root)
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
}
