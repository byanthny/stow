import Foundation
import XCTest

@testable import StowCore

@MainActor
final class StateCompatibilityTests: XCTestCase {
    private func fixture() -> AppState {
        let reference = PullRequestReference(owner: "synthetic", repository: "compatibility", number: 27)
        let noteID = UUID(uuidString: "00000000-0000-0000-0000-000000000027")!
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        var state = AppState()
        state.notes = [
            .init(
                id: noteID, markdown: "Keep this synthetic note.", pullRequest: reference,
                createdAt: timestamp, updatedAt: timestamp)
        ]
        state.pins = [reference]
        state.extensionInstances = [
            .init(
                moduleID: "uninstalled.synthetic.module", slot: .noteAccessory, noteID: noteID,
                isEnabled: true, configurationVersion: 8,
                configuration: .object([
                    "futureSetting": .array([.string("keep"), .number(42), .bool(true), .null]),
                    "nested": .object(["unknown": .string("preserve")]),
                ]))
        ]
        return state
    }

    private func encode(_ state: AppState) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(state)
    }

    private func decode(_ data: Data) throws -> AppState {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(AppState.self, from: data)
    }

    private func object(_ state: AppState) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: encode(state)) as? [String: Any])
    }

    func testOlderStateDecodesNewFieldsWithDefaults() throws {
        let original = fixture()
        var legacy = try object(original)
        let added = [
            "ownerSelection", "keepsOnlySelectedOwners", "hideKeepsAlwaysOnTopNotes", "hidesWhenSwitchingAway",
        ]
        for key in added {
            legacy.removeValue(forKey: key)
        }
        var layout = try XCTUnwrap(legacy["boardLayout"] as? [String: Any])
        for key in ["groupByOwner", "ownerOrder", "alwaysShowOwnerControl", "hidesNotesForHiddenOwners"] {
            layout.removeValue(forKey: key)
        }
        legacy["boardLayout"] = layout
        let decoded = try decode(JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(decoded.ownerSelection, OwnerSelection())
        XCTAssertTrue(decoded.ownerSelection.isAll)
        XCTAssertFalse(decoded.keepsOnlySelectedOwners)
        XCTAssertFalse(decoded.hideKeepsAlwaysOnTopNotes)
        XCTAssertTrue(decoded.hidesWhenSwitchingAway)
        XCTAssertEqual(decoded.boardLayout, BoardLayout())
        XCTAssertEqual(decoded, original)
    }

    func testOwnerSelectionNormalizesAndIgnoresCase() throws {
        let selection = OwnerSelection(["acme", "Acme", "beta"])
        XCTAssertEqual(selection.owners, ["acme", "beta"])
        XCTAssertTrue(selection.contains("ACME"))
        XCTAssertFalse(selection.contains("gamma"))
        XCTAssertFalse(selection.isAll)
        XCTAssertEqual(OwnerSelection(["Zed", "alpha", "ZED"]).owners, ["alpha", "Zed"])
        var state = AppState()
        state.ownerSelection = selection
        XCTAssertEqual(try decode(encode(state)).ownerSelection, selection)
        let loose = Data(#"{"owners":["Beta","beta","Acme"]}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(OwnerSelection.self, from: loose).owners, ["Acme", "Beta"])
    }

    func testUntrustedOwnerPreferencesFallBackWithoutRejectingTheState() throws {
        var damaged = try object(fixture())
        var layout = try XCTUnwrap(damaged["boardLayout"] as? [String: Any])
        layout["ownerOrder"] = 5
        damaged["boardLayout"] = layout
        // Older logins can end in a hyphen or repeat one, and a managed user's login adds an underscore and a short
        // code. A name GitHub wouldn't accept today stays too, so damage narrows the selection instead of widening it.
        let owners: [Any] = [
            "acme", "", " ", "bad login", 5, NSNull(), ["acme"], "-edge", "a--b", "Other", "jo_acme", "old-login-",
            "zero\u{200B}width",
        ]
        damaged["ownerSelection"] = ["owners": owners]
        let decoded = try decode(JSONSerialization.data(withJSONObject: damaged))
        XCTAssertEqual(decoded.boardLayout.ownerOrder, .alphabetical)
        XCTAssertEqual(decoded.ownerSelection.owners, ["-edge", "a--b", "acme", "jo_acme", "old-login-", "Other"])
        XCTAssertEqual(decoded.notes, fixture().notes)
        let onlyUnusable = Data(#"{"owners":["", " ", 5, null]}"#.utf8)
        XCTAssertTrue(try JSONDecoder().decode(OwnerSelection.self, from: onlyUnusable).isAll)
        let onlyUnknown = Data(#"{"owners":["x y", "_"]}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(OwnerSelection.self, from: onlyUnknown).owners, ["_"])
    }

    func testLoginValidation() {
        for valid in ["a", "acme-labs", "A1", "a-b-c", String(repeating: "a", count: 39)] {
            XCTAssertTrue(OwnerSelection.isValidLogin(valid), valid)
        }
        let invalid = ["", "-acme", "acme-", "a--b", "a_b", "a b", "caf\u{E9}", String(repeating: "a", count: 40)]
        for login in invalid { XCTAssertFalse(OwnerSelection.isValidLogin(login), login) }
    }

    func testEarlierVersionOneStateDefaultsOnlyNewPreferencesAndPreservesData() throws {
        let original = fixture()
        var legacy = try object(original)
        legacy.removeValue(forKey: "appearance")
        legacy.removeValue(forKey: "collapsedSections")
        let decoded = try decode(JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(decoded.notes, original.notes)
        XCTAssertEqual(decoded.pins, original.pins)
        XCTAssertEqual(decoded.extensionInstances, original.extensionInstances)
        XCTAssertEqual(decoded.appearance, .default)
        XCTAssertTrue(decoded.collapsedSections.isEmpty)
        XCTAssertEqual(decoded, original)
    }

    func testUnknownSectionIDsAndUninstalledModuleConfigurationRoundTrip() throws {
        var original = fixture()
        original.collapsedSections = ["needsYou", "waiting", "future.extension.section"]
        original.appearance = .paper
        let decoded = try decode(encode(original))
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.collapsedSections, ["needsYou", "waiting", "future.extension.section"])
        XCTAssertEqual(decoded.extensionInstances, original.extensionInstances)
    }

    func testInvalidNewPreferenceTypesThrowInsteadOfDiscardingNotes() throws {
        let malformed: [(String, Any)] = [
            ("appearance", "not-an-appearance-object"),
            ("appearance", ["schemaVersion": "not-a-version"]),
            ("collapsedSections", 42),
            ("collapsedSections", ["waiting", 42]),
        ]
        for (key, invalidValue) in malformed {
            var damaged = try object(fixture())
            damaged[key] = invalidValue
            let bytes = try JSONSerialization.data(withJSONObject: damaged)
            XCTAssertThrowsError(try decode(bytes), "Invalid \(key) must reject the whole state")
        }
    }

    func testInvalidPreferencesMakeRepositoryPreserveOriginalAndRefuseOverwrite() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StowCompatibilityTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("state.json")
        var damaged = try object(fixture())
        damaged["collapsedSections"] = "invalid-type"
        let original = try JSONSerialization.data(withJSONObject: damaged)
        try original.write(to: url)
        let repository = StateRepository(url: url)
        do {
            _ = try await repository.load()
            XCTFail("Expected corrupt state")
        } catch { XCTAssertEqual(error as? StateError, .corrupt) }
        do {
            try await repository.save(AppState())
            XCTFail("Expected preserved corrupt state")
        } catch { XCTAssertEqual(error as? StateError, .recoveryRequired) }
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testTruncatedLegacyStateCannotSilentlyDecodeToEmptyNotes() throws {
        XCTAssertThrowsError(try decode(Data(#"{"schemaVersion":1}"#.utf8)))
        for requiredKey in ["notes", "pins", "dismissedIDs", "pullRequests", "githubEnabled", "extensionInstances"] {
            var damaged = try object(fixture())
            damaged.removeValue(forKey: requiredKey)
            XCTAssertThrowsError(
                try decode(JSONSerialization.data(withJSONObject: damaged)),
                "Historically required field \(requiredKey) must remain required")
        }
    }
}
