import Foundation
import StowCore
import XCTest

@testable import Stow

/// Tests the same draft/import path used by the native sheet, without opening panels or touching the clipboard.
@MainActor
final class ThemeConfigIntegrationTests: XCTestCase {
    func testInvalidPastedDraftPreservesAppearanceAndCanBeCorrectedThenPersisted() async throws {
        let priorGlobal = ThemeController.shared.settings
        defer { ThemeController.shared.apply(priorGlobal) }
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await makeStore(directory)
        defer { store.stop() }
        let beforeAppearance = store.state.appearance
        let beforeNotes = store.state.notes
        let savedBefore = try Data(contentsOf: stateURL(directory))
        let draft = ThemeConfigDraft()
        draft.begin(beforeAppearance)
        XCTAssertNil(draft.error)
        XCTAssertEqual(try ThemeConfigTransfer.decode(Data(draft.source.utf8)), beforeAppearance)
        draft.source += "\nunknown-setting = should fail\n"
        let invalidSource = draft.source
        XCTAssertFalse(draft.apply(to: store))
        XCTAssertNotNil(draft.error, "The sheet needs a visible error while leaving its source editable")
        XCTAssertEqual(draft.source, invalidSource)
        XCTAssertEqual(store.state.appearance, beforeAppearance)
        XCTAssertEqual(ThemeController.shared.settings, beforeAppearance)
        XCTAssertEqual(store.state.notes, beforeNotes)
        XCTAssertEqual(try Data(contentsOf: stateURL(directory)), savedBefore)

        var corrected = beforeAppearance
        corrected.name = "Synthetic message theme"
        corrected.backgroundOpacity = 0.61
        corrected.editorFontSize = 17
        corrected.editorLineHeight = 1.55
        corrected.colors.text = "#E1E2E3"
        draft.source = try corrected.encodedConfig()
        XCTAssertTrue(draft.apply(to: store))
        XCTAssertNil(draft.error)
        XCTAssertEqual(store.state.appearance, corrected)
        XCTAssertEqual(ThemeController.shared.settings, corrected)
        XCTAssertEqual(store.state.notes, beforeNotes)
        let saved = await store.flush()
        XCTAssertTrue(saved)
        store.stop()
        ThemeController.shared.apply(.default)
        let restored = AppStore(stateURL: stateURL(directory), isDemo: true)
        await restored.start()
        defer { restored.stop() }
        XCTAssertEqual(restored.state.appearance, corrected)
        XCTAssertEqual(ThemeController.shared.settings, corrected)
        XCTAssertEqual(restored.state.notes, beforeNotes)
    }

    func testLegacyJSONPastedIntoTheSameDraftAppliesWithoutChangingNotes() async throws {
        let priorGlobal = ThemeController.shared.settings
        defer { ThemeController.shared.apply(priorGlobal) }
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await makeStore(directory)
        defer { store.stop() }
        let notes = store.state.notes
        var legacy = AppearanceSettings.paper
        legacy.editorFontSize = 18
        let draft = ThemeConfigDraft()
        draft.source = " \n\t" + String(decoding: try legacy.encodedTheme(), as: UTF8.self)
        XCTAssertTrue(draft.apply(to: store))
        XCTAssertNil(draft.error)
        XCTAssertEqual(store.state.appearance, legacy)
        XCTAssertEqual(store.state.notes, notes)
    }

    func testLocalImportBoundsAndEncodingMatchPastedConfigValidation() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("synthetic-theme.conf")
        let config = try AppearanceSettings.graphite.encodedConfig()
        try Data(config.utf8).write(to: url)
        XCTAssertEqual(try ThemeConfigTransfer.decode(ThemeConfigTransfer.read(url)), .graphite)
        XCTAssertThrowsError(try ThemeConfigTransfer.decode(Data([0xFF, 0xFE, 0xFF])))
        let oversized = Data(repeating: 0x20, count: ThemeConfigTransfer.maximumBytes + 1)
        XCTAssertThrowsError(try ThemeConfigTransfer.decode(oversized))
        try oversized.write(to: url)
        XCTAssertThrowsError(try ThemeConfigTransfer.read(url))
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "StowThemeConfigTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func stateURL(_ directory: URL) -> URL { directory.appendingPathComponent("state.json") }

    private func makeStore(_ directory: URL) async throws -> AppStore {
        var initial = AppState()
        initial.githubEnabled = false
        initial.appearance = .graphite
        initial.notes = [Note(markdown: "Synthetic private note; theming must not rewrite this.")]
        try await StateRepository(url: stateURL(directory)).save(initial)
        let store = AppStore(stateURL: stateURL(directory), isDemo: true)
        await store.start()
        store.stop()
        return store
    }
}
