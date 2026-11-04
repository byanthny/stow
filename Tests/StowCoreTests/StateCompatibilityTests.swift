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
