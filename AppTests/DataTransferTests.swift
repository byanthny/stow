import Foundation
import StowCore
import XCTest

@testable import Stow

final class DataTransferTests: XCTestCase {
    func testMarkdownExportsUseNewPrivateFoldersAndCleanUpOnlyFailedExports() throws {
        let parent = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let existing = parent.appendingPathComponent("existing.md")
        try Data("Existing synthetic file stays intact".utf8).write(to: existing)
        let sources = ["# Original source\r\n\r\n**bold** and café\r\n", "# Second note\n\n```swift\nlet x = 1\n```"]
        let files = MarkdownTransfer.files(for: sources.map { Note(markdown: $0) })
        let first = try DataTransferFiles.exportMarkdown(files, into: parent)
        let second = try DataTransferFiles.exportMarkdown(files, into: parent)
        XCTAssertNotEqual(first, second)
        for folder in [first, second] {
            XCTAssertEqual(try permissions(folder), 0o700)
            for file in files {
                let url = folder.appendingPathComponent(file.filename)
                XCTAssertEqual(try Data(contentsOf: url), Data(file.source.utf8))
                XCTAssertEqual(try permissions(url), 0o600)
            }
        }
        let beforeFailure = try children(of: parent)
        XCTAssertThrowsError(
            try DataTransferFiles.exportMarkdown(
                [
                    MarkdownFile(filename: "duplicate.md", source: "first"),
                    MarkdownFile(filename: "duplicate.md", source: "second"),
                ], into: parent))
        XCTAssertEqual(try children(of: parent), beforeFailure)
        XCTAssertThrowsError(
            try DataTransferFiles.exportMarkdown(
                [
                    MarkdownFile(filename: "../outside.md", source: "must stay inside export folder")
                ], into: parent))
        XCTAssertEqual(try children(of: parent), beforeFailure)
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "Existing synthetic file stays intact")
        XCTAssertEqual(try Data(contentsOf: first.appendingPathComponent(files[0].filename)), Data(sources[0].utf8))
    }

    func testAtomicPrivateReplacementDoesNotFollowDestinationSymlinksOrLeaveTemporaryFiles() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("untouched.md")
        try Data("Synthetic existing target".utf8).write(to: target)
        let destination = directory.appendingPathComponent("export.md")
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: target)
        let bytes = Data("# Synthetic private export\n\nExact source.\n".utf8)
        try DataTransferFiles.writePrivateAtomically(bytes, to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), bytes)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "Synthetic existing target")
        XCTAssertEqual(try permissions(destination), 0o600)
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        XCTAssertEqual(attributes[.type] as? FileAttributeType, .typeRegular)
        XCTAssertEqual(try children(of: directory), ["untouched.md", "export.md"])

        let cannotReplace = directory.appendingPathComponent("existing-directory", isDirectory: true)
        try FileManager.default.createDirectory(at: cannotReplace, withIntermediateDirectories: false)
        XCTAssertThrowsError(try DataTransferFiles.writePrivateAtomically(bytes, to: cannotReplace))
        XCTAssertEqual(try children(of: directory), ["untouched.md", "export.md", "existing-directory"])
    }

    func testBoundedReadsAcceptExactLimitAndRejectAnExtraByteWithoutRewritingInput() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("synthetic.md")
        let exact = Data(repeating: 0x61, count: 65_536)
        try exact.write(to: file)
        XCTAssertEqual(try DataTransferFiles.read(file, maximumBytes: exact.count), exact)
        let oversized = exact + Data([0x62])
        try oversized.write(to: file)
        XCTAssertThrowsError(try DataTransferFiles.read(file, maximumBytes: exact.count)) { error in
            XCTAssertEqual(error as? DataTransferFileError, .tooLarge)
        }
        XCTAssertEqual(try Data(contentsOf: file), oversized)
        try Data().write(to: file)
        XCTAssertEqual(try DataTransferFiles.read(file, maximumBytes: 0), Data())
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "StowTransferTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func permissions(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    private func children(of directory: URL) throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
    }
}
