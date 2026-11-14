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
            "terminalCardKeepTime",
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
        XCTAssertEqual(decoded.terminalCardKeepTime, .day)
        XCTAssertEqual(decoded.boardLayout, BoardLayout())
        XCTAssertEqual(decoded, original)
    }

    func testKeepTimeDecodesLenientlyAndRoundTrips() throws {
        for keepTime in TerminalCardKeepTime.allCases {
            var state = fixture()
            state.terminalCardKeepTime = keepTime
            XCTAssertEqual(try decode(encode(state)).terminalCardKeepTime, keepTime)
        }
        XCTAssertEqual(
            TerminalCardKeepTime.allCases.map(\.rawValue), ["dontKeep", "hour", "day", "week"],
            "Saved names never change")
        let original = fixture()
        let damagedValues: [Any] = ["forever", "Day", "", 3_600, true, NSNull(), ["day"], ["value": "day"]]
        for value in damagedValues {
            var damaged = try object(original)
            damaged["terminalCardKeepTime"] = value
            let decoded = try decode(JSONSerialization.data(withJSONObject: damaged))
            XCTAssertEqual(decoded.terminalCardKeepTime, .day, "\(value)")
            XCTAssertEqual(decoded, original, "\(value)")
        }
    }

    /// A `state.json` as Stow 0.3.0 writes it, with every key it writes and no other.
    private static let version030Index = #"""
        {
          "metadata": {
            "appearance": {
              "backgroundOpacity": 1,
              "colorScheme": "dark",
              "colors": {
                "amber": "#D9A659", "background": "#0E0F11", "green": "#7DB38F", "muted": "#91969E",
                "note": "#1F2022", "red": "#E0736E", "surface": "#1B1C1F", "text": "#E8E8E6"
              },
              "editorFontSize": 13,
              "editorLineHeight": 1.3,
              "interfaceFontSize": 13,
              "name": "Stow",
              "schemaVersion": 1
            },
            "boardAlwaysOnTop": true,
            "boardLayout": {
              "alwaysShowOwnerControl": false, "groupByOwner": false, "hidesNotesForHiddenOwners": false,
              "notesStartCollapsed": true, "order": ["needsYou", "notes", "waiting"], "ownerOrder": "alphabetical",
              "showsTitle": true, "visiblePullRequests": 3
            },
            "collapsedSections": ["waiting"],
            "dismissedIDs": [],
            "extensionInstances": [],
            "githubEnabled": true,
            "hideKeepsAlwaysOnTopNotes": false,
            "hidesWhenSwitchingAway": true,
            "keepsOnlySelectedOwners": false,
            "lastRefreshAt": "2023-11-14T22:13:20Z",
            "notes": [
              {
                "createdAt": "2023-11-14T22:13:20Z", "id": "00000000-0000-0000-0000-000000000027",
                "isAlwaysOnTop": true, "isDetached": false, "markdown": "",
                "pullRequest": {
                  "host": "github.com", "number": 27, "owner": "synthetic", "repository": "compatibility"
                },
                "updatedAt": "2023-11-14T22:13:20Z"
              }
            ],
            "ownerSelection": {"owners": []},
            "pins": [],
            "pullRequests": [
              {
                "authorLogin": "synthetic-viewer", "checksKnown": false, "fetchedAt": "2023-11-14T22:13:20Z",
                "isDraft": false, "isStale": true, "isUnavailable": false, "isViewerAuthor": true,
                "observedStateSince": "2023-11-14T22:13:20Z", "readinessIsComplete": false,
                "reference": {"host": "github.com", "number": 27, "owner": "synthetic", "repository": "compatibility"},
                "state": "MERGED", "terminalObservedAt": "2023-11-14T22:13:20Z", "title": "Synthetic merged change",
                "updatedAt": "2023-11-14T22:13:20Z"
              }
            ],
            "schemaVersion": 1,
            "viewerLogin": "synthetic-viewer"
          },
          "notesDirectoryName": "notes",
          "schemaVersion": 2
        }
        """#

    func testA030StateFileRoundTripsAndNewFilesKeepEveryRequiredKeyInItsShape() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StowCompatibilityTests-\(UUID().uuidString)", isDirectory: true)
        let notes = directory.appendingPathComponent("notes", isDirectory: true)
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("state.json")
        try Data(Self.version030Index.utf8).write(to: url)
        try Data("Keep this synthetic note.".utf8).write(
            to: notes.appendingPathComponent("00000000-0000-0000-0000-000000000027.md"))
        let older = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(Self.version030Index.utf8)) as? [String: Any])

        let repository = StateRepository(url: url)
        var state = try await repository.load()
        XCTAssertEqual(state.terminalCardKeepTime, .day)
        XCTAssertEqual(state.notes.map(\.markdown), ["Keep this synthetic note."])
        XCTAssertEqual(state.pullRequests.map(\.state), ["MERGED"])
        XCTAssertEqual(state.collapsedSections, ["waiting"])
        try await repository.save(state)
        var written = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var metadata = try XCTUnwrap(written["metadata"] as? [String: Any])
        XCTAssertEqual(metadata.removeValue(forKey: "terminalCardKeepTime") as? String, "day")
        written["metadata"] = metadata
        XCTAssertEqual(written as NSDictionary, older as NSDictionary, "Only the keep time is added")

        // A file with the new key keeps every key 0.3.0 requires, in its shape.
        state.terminalCardKeepTime = .week
        try await repository.save(state)
        let rewritten = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let saved = try XCTUnwrap(rewritten["metadata"] as? [String: Any])
        XCTAssertEqual(saved["schemaVersion"] as? Int, AppState.currentVersion)
        XCTAssertEqual(AppState.currentVersion, 1)
        for key in ["notes", "pins", "dismissedIDs", "pullRequests", "extensionInstances"] {
            XCTAssertNotNil(saved[key] as? [Any], key)
        }
        XCTAssertEqual((saved["githubEnabled"] as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() }, true)
        XCTAssertEqual(saved["terminalCardKeepTime"] as? String, "week")
        XCTAssertEqual(Set(saved.keys).subtracting(metadata.keys), ["terminalCardKeepTime"])
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
