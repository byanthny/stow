import XCTest

@testable import StowCore

final class RealFolderTests: XCTestCase {
    func testOnlyAFolderItselfCounts() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? manager.removeItem(at: root) }
        let folder = root.appendingPathComponent("notes")
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("linked")
        try manager.createSymbolicLink(at: link, withDestinationURL: folder)
        let file = root.appendingPathComponent("file.md")
        try Data("Synthetic".utf8).write(to: file)

        XCTAssertTrue(folder.isRealFolder)
        XCTAssertFalse(link.isRealFolder, "A link to a folder could lead anywhere")
        XCTAssertFalse(file.isRealFolder)
        XCTAssertFalse(root.appendingPathComponent("missing").isRealFolder)
    }
}
