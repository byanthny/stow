import Foundation
import XCTest

@testable import StowCore

@MainActor
final class BoardPreferencesTests: XCTestCase {
    private func fixture() -> AppState {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        var state = AppState()
        state.notes = [
            .init(
                markdown: "Synthetic note survives board preferences.",
                createdAt: timestamp, updatedAt: timestamp)
        ]
        return state
    }

    private func encodedObject(_ state: AppState) throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(state)) as? [String: Any])
    }

    private func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StowBoardPreferencesTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    func testLegacyStateDefaultsBoardToAlwaysOnTopAndPreservesNotes() throws {
        let original = fixture()
        XCTAssertTrue(original.boardAlwaysOnTop)
        var legacy = try encodedObject(original)
        legacy.removeValue(forKey: "boardAlwaysOnTop")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(AppState.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertTrue(decoded.boardAlwaysOnTop)
        XCTAssertEqual(decoded.notes, original.notes)
        XCTAssertEqual(decoded, original)
    }

    func testUnpinnedBoardPreferencePersistsIndependentlyOfNotes() async throws {
        let url = try directory().appendingPathComponent("state.json")
        var original = fixture()
        original.notes[0].isAlwaysOnTop = true
        original.boardAlwaysOnTop = false
        try await StateRepository(url: url).save(original)
        let decoded = try await StateRepository(url: url).load()
        XCTAssertFalse(decoded.boardAlwaysOnTop)
        XCTAssertTrue(decoded.notes[0].isAlwaysOnTop)
        XCTAssertEqual(decoded, original)
    }

    private func decoded(_ object: [String: Any]) throws -> AppState {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(AppState.self, from: JSONSerialization.data(withJSONObject: object))
    }

    func testBoardLayoutDefaultsToNeedsYouNotesWaitingWithThreeCards() throws {
        var legacy = try encodedObject(fixture())
        legacy.removeValue(forKey: "boardLayout")
        let layout = try decoded(legacy).boardLayout
        XCTAssertEqual(layout.order, [.needsYou, .notes, .waiting])
        XCTAssertEqual(layout.visiblePullRequests, 3)
        XCTAssertFalse(layout.notesCanCollapse)
        XCTAssertTrue(layout.notesStartCollapsed)
        XCTAssertTrue(layout.oneNoteOpenAtATime)
        XCTAssertTrue(layout.showsTitle)
        XCTAssertFalse(layout.groupByOwner)
        XCTAssertEqual(layout.ownerOrder, .alphabetical)
        XCTAssertFalse(layout.alwaysShowOwnerControl)
        XCTAssertFalse(layout.hidesNotesForHiddenOwners)
        XCTAssertEqual(layout, BoardLayout(), "A missing layout decodes to the layout Reset restores")
    }

    func testBoardLayoutKeepsEachKnownSectionOnceInSavedOrder() throws {
        var object = try encodedObject(fixture())
        object["boardLayout"] = [
            "order": ["waiting", "future-section", "waiting"], "visiblePullRequests": 0, "notesCanCollapse": true,
        ]
        let layout = try decoded(object).boardLayout
        XCTAssertEqual(layout.order, [.waiting, .needsYou, .notes])
        XCTAssertEqual(layout.shownPullRequests(of: 40, expanded: false), 40, "0 shows every card")
        XCTAssertTrue(layout.notesCanCollapse)
    }

    func testBoardLayoutMovesOnePlaceAndCapsCardsUntilExpanded() {
        var layout = BoardLayout()
        layout.move(.notes, by: -1)
        XCTAssertEqual(layout.order, [.notes, .needsYou, .waiting])
        layout.move(.notes, by: -1)
        XCTAssertEqual(layout.order, [.notes, .needsYou, .waiting], "The first section cannot move up")
        layout.move(.needsYou, by: 5)
        XCTAssertEqual(layout.order, [.notes, .waiting, .needsYou], "Moves go one place at a time")
        XCTAssertEqual(layout.shownPullRequests(of: 8, expanded: false), 3)
        XCTAssertEqual(layout.shownPullRequests(of: 2, expanded: false), 2)
        XCTAssertEqual(layout.shownPullRequests(of: 8, expanded: true), 8)
    }

    func testUnknownOwnerOrderFallsBackToAlphabetical() throws {
        let decoder = JSONDecoder()
        let future = try decoder.decode(BoardLayout.self, from: Data(#"{"ownerOrder":"newestFirst"}"#.utf8))
        XCTAssertEqual(future.ownerOrder, .alphabetical)
        let known = try decoder.decode(
            BoardLayout.self, from: Data(#"{"ownerOrder":"mostCards","groupByOwner":true}"#.utf8))
        XCTAssertEqual(known.ownerOrder, .mostCards)
        XCTAssertTrue(known.groupByOwner)
        var changed = BoardLayout()
        changed.groupByOwner = true
        changed.ownerOrder = .mostCards
        changed.alwaysShowOwnerControl = true
        changed.hidesNotesForHiddenOwners = true
        XCTAssertNotEqual(changed, BoardLayout())
        XCTAssertEqual(try decoder.decode(BoardLayout.self, from: JSONEncoder().encode(changed)), changed)
    }

    func testBoardLayoutPersistsAndRejectsOutOfRangeCounts() async throws {
        let url = try directory().appendingPathComponent("state.json")
        var original = fixture()
        original.boardLayout = BoardLayout(
            order: [.notes, .waiting, .needsYou], visiblePullRequests: 10, notesCanCollapse: true,
            notesStartCollapsed: false, oneNoteOpenAtATime: false, showsTitle: false)
        original.boardLayout.groupByOwner = true
        original.boardLayout.ownerOrder = .mostCards
        original.boardLayout.alwaysShowOwnerControl = true
        original.boardLayout.hidesNotesForHiddenOwners = true
        try await StateRepository(url: url).save(original)
        let loaded = try await StateRepository(url: url).load()
        XCTAssertEqual(loaded.boardLayout, original.boardLayout)

        let damagedURL = try directory().appendingPathComponent("state.json")
        var damaged = try encodedObject(fixture())
        damaged["boardLayout"] = ["visiblePullRequests": 500]
        try JSONSerialization.data(withJSONObject: damaged).write(to: damagedURL)
        do {
            _ = try await StateRepository(url: damagedURL).load()
            XCTFail("An out-of-range card count must reject the state")
        } catch { XCTAssertEqual(error as? StateError, .corrupt) }
    }

    func testMalformedBoardPreferencePreservesSavedBytesAndBlocksReplacement() async throws {
        let url = try directory().appendingPathComponent("state.json")
        var damaged = try encodedObject(fixture())
        damaged["boardAlwaysOnTop"] = "false"
        let originalBytes = try JSONSerialization.data(withJSONObject: damaged)
        try originalBytes.write(to: url)
        let repository = StateRepository(url: url)
        do {
            _ = try await repository.load()
            XCTFail("A non-Bool board preference must reject the state")
        } catch { XCTAssertEqual(error as? StateError, .corrupt) }
        do {
            try await repository.save(AppState())
            XCTFail("Malformed preferences must not discard notes")
        } catch { XCTAssertEqual(error as? StateError, .recoveryRequired) }
        XCTAssertEqual(try Data(contentsOf: url), originalBytes)
    }
}
