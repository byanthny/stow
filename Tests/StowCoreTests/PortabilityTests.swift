import Foundation
import XCTest

@testable import StowCore

@MainActor
final class PortabilityTests: XCTestCase {
    private let time = Date(timeIntervalSince1970: 1_700_000_000)
    private let markdown =
        "\u{FEFF}\r\n# caf\u{0065}\u{0301} 🐈\r\n\r\n- **exact**\tbytes  \r\n```swift\r\nlet x = \"日本語\"\r\n```\r\n"

    private func fixture() -> AppState {
        let reference = PullRequestReference(owner: "synthetic", repository: "portability", number: 7)
        let note = Note(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000007")!, markdown: markdown,
            pullRequest: reference, isDetached: true, isAlwaysOnTop: false,
            frame: .init(x: 50, y: 80, width: 350, height: 450), createdAt: time, updatedAt: time)
        var state = AppState()
        state.notes = [note]
        state.pins = [reference]
        state.dismissedIDs = ["synthetic-dismissed-id"]
        state.pullRequests = [
            .init(
                reference: reference, title: "Synthetic cache", isViewerAuthor: true,
                isDraft: false, fetchedAt: time, observedStateSince: time,
                details: .init(latestComment: "Synthetic comment", fetchedAt: time))
        ]
        state.boardFrame = .init(x: 100, y: 200, width: 700, height: 800)
        state.boardAlwaysOnTop = false
        state.githubEnabled = false
        state.ghExecutablePath = "/synthetic/bin/gh"
        state.viewerLogin = "synthetic-viewer"
        state.lastRefreshAt = time
        state.extensionInstances = [
            .init(
                moduleID: "missing.synthetic.module", slot: .noteAccessory,
                noteID: note.id, isEnabled: true, configurationVersion: 99,
                configuration: .object([
                    "future": .array([
                        .string("retained"), .null,
                        .object(["nested": .number(8)]),
                    ])
                ]))
        ]
        state.appearance = .paper
        state.appearance.editorFontName = "Synthetic Font"
        state.collapsedSections = ["waiting", "future.module.section"]
        return state
    }

    func testCompleteBackupRoundTripRetainsNotesSettingsAndUnavailableModuleConfiguration() throws {
        let original = fixture()
        let data = try StowBackup.encode(original, createdAt: time)
        let restored = try StowBackup.decode(data)
        // Everything round-trips except settings that describe the source Mac.
        XCTAssertEqual(restored, original.keepingMachineLocalSettings(from: AppState()))
        XCTAssertNil(restored.ghExecutablePath)
        XCTAssertEqual(Data(restored.notes[0].markdown.utf8), Data(markdown.utf8))
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(envelope["formatVersion"] as? Int, 1)
        XCTAssertEqual(envelope["createdAt"] as? String, "2023-11-14T22:13:20Z")
        XCTAssertEqual(try StowBackup.encode(original, createdAt: time), data)
    }

    func testMarkdownExportPreservesExactUTF8WithoutFrontmatterAndStrictImportRoundTrips() throws {
        let note = fixture().notes[0]
        let file = try XCTUnwrap(MarkdownTransfer.files(for: [note]).first)
        XCTAssertEqual(Data(file.source.utf8), Data(markdown.utf8))
        let imported = try MarkdownTransfer.decodeNote(Data(file.source.utf8))
        XCTAssertEqual(Data(imported.utf8), Data(markdown.utf8))
        XCTAssertEqual(try MarkdownTransfer.decodeNote(Data()), "")
    }

    func testFilenamesAreSafeStableAndUniqueForDuplicateOrSanitizedTitles() {
        let titles = [
            "../../secret", "..\\..\\secret", "\n \n# Repeated title", "# Repeated title",
            ".hidden", "日本語🐈", "", String(repeating: "x", count: 500),
        ]
        let notes = titles.enumerated().map { index, title in
            Note(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!, markdown: title)
        }
        let files = MarkdownTransfer.files(for: notes)
        XCTAssertEqual(files, MarkdownTransfer.files(for: notes))
        XCTAssertEqual(Set(files.map(\.filename)).count, notes.count)
        for (note, file) in zip(notes, files) {
            XCTAssertTrue(file.filename.hasSuffix("\(note.id.uuidString.lowercased()).md"))
            XCTAssertFalse(file.filename.hasPrefix("."))
            XCTAssertFalse(file.filename.contains("/"))
            XCTAssertFalse(file.filename.contains("\\"))
            XCTAssertFalse(file.filename.contains(".."))
            XCTAssertLessThan(file.filename.utf8.count, 150)
            XCTAssertEqual(file.source, note.markdown)
        }
        let duplicatedID = MarkdownTransfer.files(for: [notes[0], notes[0]])
        XCTAssertEqual(Set(duplicatedID.map(\.filename)).count, 2)
    }

    func testBackupRejectsUnknownVersionsAndMalformedEnvelopesWithSanitizedErrors() throws {
        let data = try StowBackup.encode(fixture(), createdAt: time)
        var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        envelope["formatVersion"] = 99
        XCTAssertThrowsError(try StowBackup.decode(JSONSerialization.data(withJSONObject: envelope))) {
            XCTAssertEqual($0 as? PortabilityError, .unsupportedBackupVersion(99))
        }
        envelope["formatVersion"] = 1
        var state = try XCTUnwrap(envelope["state"] as? [String: Any])
        state["schemaVersion"] = 77
        envelope["state"] = state
        XCTAssertThrowsError(try StowBackup.decode(JSONSerialization.data(withJSONObject: envelope))) {
            XCTAssertEqual($0 as? PortabilityError, .unsupportedStateVersion(77))
        }
        for invalid in [Data(), Data("not JSON sensitive content".utf8), Data(#"{"formatVersion":1}"#.utf8)] {
            XCTAssertThrowsError(try StowBackup.decode(invalid)) {
                XCTAssertEqual($0 as? PortabilityError, .invalidBackup)
                XCTAssertFalse($0.localizedDescription.contains("sensitive content"))
            }
        }
        var unsupported = fixture()
        unsupported.schemaVersion = 77
        XCTAssertThrowsError(try StowBackup.encode(unsupported, createdAt: time)) {
            XCTAssertEqual($0 as? PortabilityError, .unsupportedStateVersion(77))
        }
        state["schemaVersion"] = 1
        state["notes"] = "damaged"
        envelope["state"] = state
        XCTAssertThrowsError(try StowBackup.decode(JSONSerialization.data(withJSONObject: envelope))) {
            XCTAssertEqual($0 as? PortabilityError, .invalidBackup)
        }
    }

    func testSizeBoundsAndMalformedUTF8AreRejected() throws {
        XCTAssertThrowsError(try StowBackup.decode(Data(count: StowBackup.maximumByteCount + 1))) {
            XCTAssertEqual($0 as? PortabilityError, .backupTooLarge)
        }
        XCTAssertThrowsError(try MarkdownTransfer.decodeNote(Data(count: MarkdownTransfer.maximumNoteByteCount + 1))) {
            XCTAssertEqual($0 as? PortabilityError, .noteTooLarge)
        }
        let limit = Data(repeating: 0x61, count: MarkdownTransfer.maximumNoteByteCount)
        XCTAssertEqual(try MarkdownTransfer.decodeNote(limit).utf8.count, limit.count)
        for invalid in [Data([0xFF]), Data([0xC3, 0x28]), Data([0xED, 0xA0, 0x80]), Data([0xE2, 0x82])] {
            XCTAssertThrowsError(try MarkdownTransfer.decodeNote(invalid)) {
                XCTAssertEqual($0 as? PortabilityError, .invalidUTF8)
            }
        }
    }

    func testBackupRejectsDuplicateNoteIDsAndOversizeSingleNote() throws {
        var duplicate = fixture()
        duplicate.notes.append(duplicate.notes[0])
        XCTAssertThrowsError(try StowBackup.encode(duplicate, createdAt: time)) {
            XCTAssertEqual($0 as? PortabilityError, .invalidBackup)
        }
        let valid = try StowBackup.encode(fixture(), createdAt: time)
        var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: valid) as? [String: Any])
        var state = try XCTUnwrap(envelope["state"] as? [String: Any])
        let notes = try XCTUnwrap(state["notes"] as? [[String: Any]])
        state["notes"] = notes + notes
        envelope["state"] = state
        XCTAssertThrowsError(try StowBackup.decode(JSONSerialization.data(withJSONObject: envelope))) {
            XCTAssertEqual($0 as? PortabilityError, .invalidBackup)
        }
        var oversized = fixture()
        oversized.notes[0].markdown = String(repeating: "a", count: MarkdownTransfer.maximumNoteByteCount + 1)
        XCTAssertThrowsError(try StowBackup.encode(oversized, createdAt: time)) {
            XCTAssertEqual($0 as? PortabilityError, .noteTooLarge)
        }
    }

    func testBackupRejectsMalformedReferencesBeforeTheyCanReachURLActions() throws {
        for reference in [
            PullRequestReference(owner: "synthetic", repository: "repo", number: 0),
            PullRequestReference(host: "github.com.evil.test", owner: "synthetic", repository: "repo", number: 1),
            PullRequestReference(owner: "../../outside", repository: "repo", number: 1),
            PullRequestReference(owner: "synthetic", repository: "../outside", number: 1),
        ] {
            var invalid = fixture()
            invalid.pins = [reference]
            XCTAssertThrowsError(try StowBackup.encode(invalid, createdAt: time)) {
                XCTAssertEqual($0 as? PortabilityError, .invalidBackup)
            }
        }
    }

    func testBackupsNeverCarryTheSourceMacsGitHubCLILocation() throws {
        let data = try StowBackup.encode(fixture(), createdAt: time)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("/synthetic/bin/gh"))
        XCTAssertNil(try StowBackup.decode(data).ghExecutablePath)
    }

    func testRestoreKeepsThisMacsGitHubSettingsFromACraftedBackup() throws {
        // Another tool can write any value into a backup; the codec still accepts the envelope.
        let valid = try StowBackup.encode(fixture(), createdAt: time)
        var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: valid) as? [String: Any])
        var state = try XCTUnwrap(envelope["state"] as? [String: Any])
        state["ghExecutablePath"] = "/bin/sh"
        state["githubEnabled"] = true
        var instances = try XCTUnwrap(state["extensionInstances"] as? [[String: Any]])
        for index in instances.indices { instances[index]["isEnabled"] = true }
        state["extensionInstances"] = instances
        envelope["state"] = state
        let crafted = try StowBackup.decode(JSONSerialization.data(withJSONObject: envelope))
        XCTAssertEqual(crafted.ghExecutablePath, "/bin/sh")

        var local = AppState()
        local.ghExecutablePath = "/synthetic/local/gh"
        local.githubEnabled = false
        let restored = crafted.keepingMachineLocalSettings(from: local)
        XCTAssertEqual(restored.ghExecutablePath, "/synthetic/local/gh")
        XCTAssertFalse(restored.githubEnabled)
        // Accessories keep their configuration but stay off until enabled on this Mac.
        XCTAssertTrue(crafted.extensionInstances.contains { $0.isEnabled })
        XCTAssertFalse(restored.extensionInstances.contains { $0.isEnabled })
        XCTAssertEqual(restored.extensionInstances.map(\.configuration), crafted.extensionInstances.map(\.configuration))
        // The portable setup itself still comes from the backup.
        XCTAssertEqual(restored.notes, crafted.notes)
        XCTAssertEqual(restored.pins, crafted.pins)
        XCTAssertEqual(restored.appearance, crafted.appearance)
    }

    func testBackupEncodingRejectsOversizeOutput() throws {
        var state = AppState()
        state.notes = (0..<8).map { _ in
            .init(
                markdown: String(repeating: "a", count: MarkdownTransfer.maximumNoteByteCount),
                createdAt: time, updatedAt: time)
        }
        XCTAssertThrowsError(try StowBackup.encode(state, createdAt: time)) {
            XCTAssertEqual($0 as? PortabilityError, .backupTooLarge)
        }
    }
}
