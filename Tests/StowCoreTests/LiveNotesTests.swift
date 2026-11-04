import Foundation
import XCTest

@testable import StowCore

@MainActor
final class LiveNotesTests: XCTestCase {
    private let time = Date(timeIntervalSince1970: 1_700_000_000)
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "StowLiveTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func state(_ source: String = "# original\r\n\r\nUnicode e\u{0301} 🐈\r\n") -> AppState {
        var value = AppState()
        value.notes = [
            .init(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, markdown: source,
                pullRequest: .init(owner: "synthetic", repository: "live", number: 1),
                createdAt: time, updatedAt: time)
        ]
        return value
    }
    private func legacyData(_ state: AppState) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(state)
    }

    func testV1MigrationBacksUpExactOriginalBeforePublishingMetadataOnlyIndex() async throws {
        let root = try directory()
        let url = root.appendingPathComponent("state.json")
        let original = state()
        let bytes = try legacyData(original)
        try bytes.write(to: url)
        let repository = StateRepository(url: url)
        let loaded = try await repository.load()
        XCTAssertEqual(loaded, original)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        try await repository.save(loaded)
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        let backup = try XCTUnwrap(files.first { $0.lastPathComponent.hasSuffix(".backup") })
        XCTAssertEqual(try Data(contentsOf: backup), bytes)
        let mode = (try FileManager.default.attributesOfItem(atPath: backup.path)[.posixPermissions] as! NSNumber)
            .intValue
        XCTAssertEqual(mode & 0o777, 0o600)
        let index = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(index["schemaVersion"] as? Int, 2)
        let metadata = try XCTUnwrap(index["metadata"] as? [String: Any])
        let notes = try XCTUnwrap(metadata["notes"] as? [[String: Any]])
        XCTAssertEqual(notes[0]["markdown"] as? String, "")
        let sourceURL = await repository.noteFileURL(id: original.notes[0].id)
        XCTAssertEqual(try Data(contentsOf: sourceURL), Data(original.notes[0].markdown.utf8))
        let reloaded = try await StateRepository(url: url).load()
        XCTAssertEqual(reloaded, original)
    }

    func testExternalCleanEditAndAtomicReplacementAreAdopted() async throws {
        let url = try directory().appendingPathComponent("state.json")
        let repository = StateRepository(url: url)
        let original = state("original")
        try await repository.save(original)
        let sourceURL = await repository.noteFileURL(id: original.notes[0].id)
        try Data("external 🐈\r\n".utf8).write(to: sourceURL, options: .atomic)
        let result = try await repository.saveMerging(original)
        XCTAssertEqual(result.state.notes[0].markdown, "external 🐈\r\n")
        XCTAssertTrue(result.conflictNoteIDs.isEmpty)
        let loaded = try await StateRepository(url: url).load()
        XCTAssertEqual(loaded.notes[0].markdown, "external 🐈\r\n")
    }

    func testCleanExternalAdoptionSurvivesStaleQuitSnapshot() async throws {
        let url = try directory().appendingPathComponent("state.json")
        let repository = StateRepository(url: url)
        let original = state("A")
        try await repository.save(original)
        let sourceURL = await repository.noteFileURL(id: original.notes[0].id)
        try Data("B".utf8).write(to: sourceURL, options: .atomic)
        let adopted = try await repository.saveMerging(original)
        XCTAssertEqual(adopted.state.notes[0].markdown, "B")
        try await repository.saveAndClose(original)
        let loaded = try await StateRepository(url: url).load()
        XCTAssertEqual(loaded.notes.map(\.markdown), ["B"])
    }

    func testReopenAllowsSavingAfterSaveAndClose() async throws {
        let url = try directory().appendingPathComponent("state.json")
        let repository = StateRepository(url: url)
        let a = state("A")
        try await repository.saveAndClose(a)
        let b = state("B")
        try await repository.save(b)
        let closed = try await StateRepository(url: url).load()
        XCTAssertEqual(closed.notes.map(\.markdown), ["A"])
        await repository.reopen()
        try await repository.save(b)
        let loaded = try await repository.load()
        XCTAssertEqual(loaded.notes.map(\.markdown), ["B"])
    }

    func testNewLocalEditBeforeAdoptionAcknowledgementPreservesAdoptedSourceAsConflict() async throws {
        let url = try directory().appendingPathComponent("state.json")
        let repository = StateRepository(url: url)
        let original = state("A")
        try await repository.save(original)
        let sourceURL = await repository.noteFileURL(id: original.notes[0].id)
        try Data("B".utf8).write(to: sourceURL, options: .atomic)
        _ = try await repository.saveMerging(original)
        var newerLocal = original
        newerLocal.notes[0].markdown = "C"
        let merged = try await repository.saveMerging(newerLocal)
        XCTAssertEqual(Set(merged.state.notes.map(\.markdown)), ["B", "C"])
        XCTAssertEqual(merged.conflictNoteIDs.count, 1)
        try await repository.saveAndClose(newerLocal)
        let loaded = try await StateRepository(url: url).load()
        XCTAssertEqual(Set(loaded.notes.map(\.markdown)), ["B", "C"])
    }

    func testRepeatedExternalAdoptionKeepsOriginalCallerBaselineUntilAcknowledged() async throws {
        let url = try directory().appendingPathComponent("state.json")
        let repository = StateRepository(url: url)
        let original = state("A")
        try await repository.save(original)
        let sourceURL = await repository.noteFileURL(id: original.notes[0].id)
        try Data("B".utf8).write(to: sourceURL, options: .atomic)
        _ = try await repository.saveMerging(original)
        try Data("C".utf8).write(to: sourceURL, options: .atomic)
        let latest = try await repository.saveMerging(original)
        XCTAssertEqual(latest.state.notes.map(\.markdown), ["C"])
        try await repository.saveAndClose(original)
        let loaded = try await StateRepository(url: url).load()
        XCTAssertEqual(loaded.notes.map(\.markdown), ["C"])
    }

    func testV1CollisionWithExistingMarkdownPreservesBothBodiesAsCanonicalNotes() async throws {
        let root = try directory()
        let url = root.appendingPathComponent("state.json")
        let original = state("legacy body")
        let originalBytes = try legacyData(original)
        try originalBytes.write(to: url)
        let notesDirectory = root.appendingPathComponent("notes")
        try FileManager.default.createDirectory(at: notesDirectory, withIntermediateDirectories: false)
        try Data("pre-existing Markdown body".utf8).write(
            to: notesDirectory.appendingPathComponent("\(original.notes[0].id.uuidString).md"))
        let repository = StateRepository(url: url)
        let loaded = try await repository.load()
        XCTAssertEqual(loaded.notes.first { $0.id == original.notes[0].id }?.markdown, "legacy body")
        XCTAssertEqual(Set(loaded.notes.map(\.markdown)), ["legacy body", "pre-existing Markdown body"])
        try await repository.save(loaded)
        let restarted = try await StateRepository(url: url).load()
        XCTAssertEqual(Set(restarted.notes.map(\.markdown)), ["legacy body", "pre-existing Markdown body"])
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        let backup = try XCTUnwrap(files.first { $0.lastPathComponent.hasSuffix(".backup") })
        XCTAssertEqual(try Data(contentsOf: backup), originalBytes)
    }

    func testSimultaneousEditsKeepBothAndUnacknowledgedConflictSurvivesStaleQuitSnapshot() async throws {
        let url = try directory().appendingPathComponent("state.json")
        let repository = StateRepository(url: url)
        let original = state("baseline")
        try await repository.save(original)
        let sourceURL = await repository.noteFileURL(id: original.notes[0].id)
        try Data("external version".utf8).write(to: sourceURL, options: .atomic)
        var local = original
        local.notes[0].markdown = "local version"
        let merged = try await repository.saveMerging(local)
        XCTAssertEqual(merged.conflictNoteIDs.count, 1)
        XCTAssertEqual(merged.state.notes.count, 2)
        XCTAssertEqual(merged.state.notes.first { $0.id == original.notes[0].id }?.markdown, "local version")
        let conflict = try XCTUnwrap(merged.state.notes.first { $0.id == merged.conflictNoteIDs[0] })
        XCTAssertEqual(conflict.markdown, "external version")
        XCTAssertEqual(conflict.pullRequest, original.notes[0].pullRequest)
        try await repository.saveAndClose(local)
        let reloaded = try await StateRepository(url: url).load()
        XCTAssertEqual(Set(reloaded.notes.map(\.markdown)), ["local version", "external version"])
    }

    func testCleanExternalDeletionRemovesNoteButDirtyDeletionRetainsUnsavedEdits() async throws {
        for dirty in [false, true] {
            let url = try directory().appendingPathComponent("state.json")
            let repository = StateRepository(url: url)
            var incoming = state("baseline")
            try await repository.save(incoming)
            let sourceURL = await repository.noteFileURL(id: incoming.notes[0].id)
            try FileManager.default.removeItem(at: sourceURL)
            if dirty { incoming.notes[0].markdown = "unsaved local edit" }
            let result = try await repository.saveMerging(incoming)
            if dirty {
                XCTAssertEqual(result.state.notes[0].markdown, "unsaved local edit")
                XCTAssertEqual(result.conflictNoteIDs, [incoming.notes[0].id])
                XCTAssertEqual(try Data(contentsOf: sourceURL), Data("unsaved local edit".utf8))
            } else {
                XCTAssertTrue(result.state.notes.isEmpty)
                XCTAssertEqual(result.externallyDeletedIDs, [incoming.notes[0].id])
                XCTAssertFalse(FileManager.default.fileExists(atPath: sourceURL.path))
            }
        }
    }

    func testExplicitDeletionCanRemoveUnacknowledgedConflictAfterMetadataCommit() async throws {
        let url = try directory().appendingPathComponent("state.json")
        let repository = StateRepository(url: url)
        var local = state("baseline")
        try await repository.save(local)
        let sourceURL = await repository.noteFileURL(id: local.notes[0].id)
        try Data("external".utf8).write(to: sourceURL, options: .atomic)
        local.notes[0].markdown = "local"
        let merged = try await repository.saveMerging(local)
        let conflictID = try XCTUnwrap(merged.conflictNoteIDs.first)
        try await repository.saveAndClose(local, deletedNoteIDs: [conflictID])
        let loaded = try await StateRepository(url: url).load()
        XCTAssertEqual(loaded.notes.count, 1)
        XCTAssertEqual(loaded.notes[0].markdown, "local")
    }

    func testUUIDOrphanRecoveredAndArbitraryFilenamesIgnored() async throws {
        let root = try directory()
        let url = root.appendingPathComponent("state.json")
        let directory = root.appendingPathComponent("notes")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let id = UUID()
        try Data("recovered orphan".utf8).write(to: directory.appendingPathComponent("\(id.uuidString).md"))
        try Data("ignored".utf8).write(to: directory.appendingPathComponent("ordinary-name.md"))
        let repository = StateRepository(url: url)
        let loaded = try await repository.load()
        XCTAssertEqual(loaded.notes.map(\.id), [id])
        XCTAssertEqual(loaded.notes[0].markdown, "recovered orphan")
        try await repository.save(loaded)
        let again = try await StateRepository(url: url).load()
        XCTAssertEqual(again.notes.map(\.id), [id])
    }

    func testCoordinatedWriteRefusesSourceChangedAfterMergeRead() throws {
        let file = try directory().appendingPathComponent("note.md")
        let baseline = Data("baseline".utf8)
        let external = Data("external edit after merge read".utf8)
        try external.write(to: file)
        XCTAssertThrowsError(
            try LiveNoteIO.write(
                Data("local".utf8), to: file,
                expectedData: baseline, checkExpected: true)
        ) {
            XCTAssertEqual($0 as? StateError, .unwritable)
        }
        XCTAssertEqual(try Data(contentsOf: file), external)
    }

    func testMalformedUTF8GatesOverwriteAndPreservesIndexAndSource() async throws {
        let url = try directory().appendingPathComponent("state.json")
        let repository = StateRepository(url: url)
        let original = state("baseline")
        try await repository.save(original)
        let index = try Data(contentsOf: url)
        let sourceURL = await repository.noteFileURL(id: original.notes[0].id)
        let invalid = Data([0xFF, 0xFE])
        try invalid.write(to: sourceURL)
        do {
            _ = try await repository.saveMerging(original)
            XCTFail("Expected invalid UTF8")
        } catch { XCTAssertEqual(error as? StateError, .corrupt) }
        do {
            try await repository.save(original)
            XCTFail("Expected recovery gate")
        } catch { XCTAssertEqual(error as? StateError, .recoveryRequired) }
        XCTAssertEqual(try Data(contentsOf: url), index)
        XCTAssertEqual(try Data(contentsOf: sourceURL), invalid)
    }

    func testSymlinkSourceAndDirectoryAreRefusedWithoutChangingTarget() async throws {
        for replaceDirectory in [false, true] {
            let root = try directory()
            let url = root.appendingPathComponent("state.json")
            let repository = StateRepository(url: url)
            let original = state("baseline")
            try await repository.save(original)
            let index = try Data(contentsOf: url)
            let target = root.appendingPathComponent("target")
            if replaceDirectory {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
                let notesDirectory = await repository.notesDirectory
                try FileManager.default.removeItem(at: notesDirectory)
                try FileManager.default.createSymbolicLink(at: notesDirectory, withDestinationURL: target)
            } else {
                try Data("untouched target".utf8).write(to: target)
                let sourceURL = await repository.noteFileURL(id: original.notes[0].id)
                try FileManager.default.removeItem(at: sourceURL)
                try FileManager.default.createSymbolicLink(at: sourceURL, withDestinationURL: target)
            }
            do {
                _ = try await repository.saveMerging(original)
                XCTFail("Expected symlink refusal")
            } catch { XCTAssertEqual(error as? StateError, .unreadable) }
            XCTAssertEqual(try Data(contentsOf: url), index)
            if !replaceDirectory { XCTAssertEqual(try Data(contentsOf: target), Data("untouched target".utf8)) }
        }
    }

    func testMissingWholeNotesDirectoryDoesNotDeleteEveryNoteOrReplaceIndex() async throws {
        let url = try directory().appendingPathComponent("state.json")
        let repository = StateRepository(url: url)
        let original = state("baseline")
        try await repository.save(original)
        let index = try Data(contentsOf: url)
        let notesDirectory = await repository.notesDirectory
        try FileManager.default.moveItem(at: notesDirectory, to: notesDirectory.appendingPathExtension("moved"))
        do {
            _ = try await repository.saveMerging(original)
            XCTFail("Expected missing directory")
        } catch { XCTAssertEqual(error as? StateError, .unreadable) }
        XCTAssertEqual(try Data(contentsOf: url), index)
        XCTAssertFalse(FileManager.default.fileExists(atPath: notesDirectory.path))
        do {
            _ = try await StateRepository(url: url).load()
            XCTFail("Expected missing directory on restart")
        } catch { XCTAssertEqual(error as? StateError, .unreadable) }
    }

    func testRestorePublishesNewFolderAndPreservesOldFolderAndExactIndexBackup() async throws {
        let root = try directory()
        let url = root.appendingPathComponent("state.json")
        let repository = StateRepository(url: url)
        let original = state("old source")
        try await repository.save(original)
        let oldIndex = try Data(contentsOf: url)
        let oldDirectory = await repository.notesDirectory
        let oldSourceURL = await repository.noteFileURL(id: original.notes[0].id)
        let replacement = state("restored source")
        let result = try await repository.restore(replacement)
        XCTAssertEqual(result.state, replacement)
        let newDirectory = await repository.notesDirectory
        XCTAssertNotEqual(newDirectory, oldDirectory)
        XCTAssertTrue(newDirectory.lastPathComponent.hasPrefix("notes-"))
        XCTAssertEqual(try Data(contentsOf: oldSourceURL), Data("old source".utf8))
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        let backup = try XCTUnwrap(files.first { $0.lastPathComponent.contains("before-restore-") })
        XCTAssertEqual(try Data(contentsOf: backup), oldIndex)
        let restarted = StateRepository(url: url)
        let reloaded = try await restarted.load()
        XCTAssertEqual(reloaded, replacement)
        let reloadedDirectory = await restarted.notesDirectory
        XCTAssertEqual(reloadedDirectory, newDirectory)
    }

    func testUnsupportedRestoreAndUnsafeDirectoryPointerPreserveExistingData() async throws {
        let url = try directory().appendingPathComponent("state.json")
        let repository = StateRepository(url: url)
        try await repository.save(state("original"))
        let originalIndex = try Data(contentsOf: url)
        var unsupported = state("replacement")
        unsupported.schemaVersion = 999
        do {
            _ = try await repository.restore(unsupported)
            XCTFail("Expected unsupported restore")
        } catch { XCTAssertEqual(error as? StateError, .unsupportedVersion(999)) }
        XCTAssertEqual(try Data(contentsOf: url), originalIndex)
        var index = try XCTUnwrap(JSONSerialization.jsonObject(with: originalIndex) as? [String: Any])
        index["notesDirectoryName"] = "../outside"
        let malformed = try JSONSerialization.data(withJSONObject: index)
        try malformed.write(to: url)
        let unsafe = StateRepository(url: url)
        do {
            _ = try await unsafe.load()
            XCTFail("Expected unsafe pointer refusal")
        } catch { XCTAssertEqual(error as? StateError, .corrupt) }
        do {
            try await unsafe.save(state())
            XCTFail("Expected recovery gate")
        } catch { XCTAssertEqual(error as? StateError, .recoveryRequired) }
        XCTAssertEqual(try Data(contentsOf: url), malformed)
    }
}
