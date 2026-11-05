import Foundation
import StowCore
import StowExtensionSDK
import StowGitHub
import XCTest

@testable import Stow

@MainActor
final class AppStoreCancellationTests: XCTestCase {
    func testDisablingGitHubCancelsDetailsAndRejectsLateSuccessOrFailure() async throws {
        for outcome in [CancelledDetailClient.Outcome.success, .failure] {
            let directory = try makeDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let client = CancelledDetailClient(outcome: outcome)
            // An existing installation that already opted in to GitHub.
            var initial = AppState()
            initial.githubEnabled = true
            try await StateRepository(url: stateURL(directory)).save(initial)
            let store = AppStore(stateURL: stateURL(directory), githubClient: client, accessoryProviders: [])
            await store.start()
            // Background timers are unnecessary for this controlled in-flight detail request. Pausing quiets them
            // and keeps the store saving, which a stopped store no longer does.
            store.isPaused = true
            defer { store.stop() }
            XCTAssertTrue(store.state.githubEnabled)
            XCTAssertFalse(store.offersGitHubSetup)
            let reference = PullRequestReference(owner: "example", repository: "synthetic", number: 42)
            store.state.pullRequests = [.init(reference: reference, title: "Synthetic cached card")]
            store.toggleDetails(reference)
            let started = await waitUntil { await client.didStart }
            XCTAssertTrue(started)
            XCTAssertTrue(store.loadingDetails.contains(reference.id))

            store.setGitHubEnabled(false)
            store.githubMessage = "Current session message"
            let saved = await store.flush()
            XCTAssertTrue(saved)
            let savedBeforeCompletion = try Data(contentsOf: stateURL(directory))
            let completed = await waitUntil { await client.didFinish }
            XCTAssertTrue(completed)
            let cancellationObserved = await client.didObserveCancellation
            XCTAssertTrue(cancellationObserved)
            // Allow any incorrectly scheduled debounced write from a late callback to run.
            try await Task.sleep(for: .milliseconds(350))
            XCTAssertFalse(store.state.githubEnabled)
            XCTAssertFalse(store.loadingDetails.contains(reference.id))
            XCTAssertNil(store.state.pullRequests.first?.details)
            XCTAssertEqual(store.githubMessage, "Current session message")
            XCTAssertEqual(try Data(contentsOf: stateURL(directory)), savedBeforeCompletion)
            let persisted = try await StateRepository(url: stateURL(directory)).load()
            XCTAssertNil(persisted.pullRequests.first?.details)
        }
    }

    func testNewInstallationAsksBeforeUsingTheGitHubCLILogin() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = CancelledDetailClient(outcome: .failure)
        let store = AppStore(stateURL: stateURL(directory), githubClient: client, accessoryProviders: [])
        await store.start()
        store.stop()
        defer { store.stop() }
        XCTAssertFalse(store.state.githubEnabled, "A new installation must not use an existing gh login unasked")
        XCTAssertTrue(store.offersGitHubSetup)
        store.answerGitHubSetup(useGitHub: false)
        XCTAssertFalse(store.offersGitHubSetup)
        XCTAssertFalse(store.state.githubEnabled)

        // The first launch saved the choice, so a relaunch is no longer a new installation.
        let relaunched = AppStore(stateURL: stateURL(directory), githubClient: client, accessoryProviders: [])
        await relaunched.start()
        relaunched.stop()
        defer { relaunched.stop() }
        XCTAssertFalse(relaunched.offersGitHubSetup)
        XCTAssertFalse(relaunched.state.githubEnabled)

        let fresh = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: fresh) }
        let accepting = AppStore(stateURL: stateURL(fresh), githubClient: client, accessoryProviders: [])
        await accepting.start()
        accepting.stop()
        defer { accepting.stop() }
        accepting.answerGitHubSetup(useGitHub: true)
        XCTAssertTrue(accepting.state.githubEnabled)
        XCTAssertFalse(accepting.offersGitHubSetup)
    }

    func testBoardNotesStartCollapsedOpenOneAtATimeAndOpenWhenFocused() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var initial = AppState()
        initial.githubEnabled = false
        initial.notes = [Note(markdown: "# First"), Note(markdown: "Second"), Note(markdown: "Third")]
        try await StateRepository(url: stateURL(directory)).save(initial)
        let store = AppStore(stateURL: stateURL(directory), accessoryProviders: [])
        await store.start()
        // Pausing quiets background timers and keeps the store saving, which a stopped store no longer does.
        store.isPaused = true
        defer { store.stop() }
        let ids = store.state.notes.map(\.id)
        XCTAssertTrue(store.expandedNoteIDs.isEmpty, "Board notes start as one-line rows")
        store.toggleNoteExpanded(ids[0])
        store.toggleNoteExpanded(ids[1])
        XCTAssertEqual(store.expandedNoteIDs, [ids[0], ids[1]], "Several notes can stay open")
        store.toggleNoteExpanded(ids[0])
        XCTAssertEqual(store.expandedNoteIDs, [ids[1]], "Folding one leaves the others open")
        let created = store.addNote("New thought")
        XCTAssertEqual(store.expandedNoteIDs, [ids[1], created], "A new note opens ready to type")
        store.requestFocus(ids[0])
        XCTAssertTrue(store.isNoteExpanded(ids[0]))
        store.deleteNote(ids[0])
        XCTAssertFalse(store.isNoteExpanded(ids[0]))

        store.setNotesStartCollapsed(false)
        let saved = await store.flush()
        XCTAssertTrue(saved)
        let relaunched = AppStore(stateURL: stateURL(directory), accessoryProviders: [])
        await relaunched.start()
        relaunched.stop()
        defer { relaunched.stop() }
        XCTAssertEqual(
            relaunched.expandedNoteIDs.count, relaunched.state.notes.count, "Expanded start opens every note")
    }

    func testDisablingQueuedAccessoryPreventsItsProviderFromStarting() async throws {
        try await checkQueuedAccessoryRemoval(deleteOwner: false)
    }

    func testDeletingQueuedAccessoryOwnerPreventsItsProviderFromStarting() async throws {
        try await checkQueuedAccessoryRemoval(deleteOwner: true)
    }

    func testCheckSymbolsDistinguishPendingUnknownFailureAndSuccess() {
        XCTAssertEqual(checkSymbol("PENDING"), "clock")
        XCTAssertEqual(checkSymbol("IN_PROGRESS"), "clock")
        XCTAssertEqual(checkSymbol("future-state"), "questionmark.circle")
        XCTAssertEqual(checkSymbol("SUCCESS"), "checkmark.circle")
        XCTAssertEqual(checkSymbol("FAILURE"), "xmark.circle")
    }

    private func checkQueuedAccessoryRemoval(deleteOwner: Bool) async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var initial = AppState()
        initial.githubEnabled = false
        try await StateRepository(url: stateURL(directory)).save(initial)
        let firstNote = Note(markdown: "Synthetic blocking accessory owner")
        let secondNote = Note(markdown: "Synthetic queued accessory owner")
        let first = ExtensionInstanceState(
            moduleID: "org.stow.sample", slot: .noteAccessory,
            noteID: firstNote.id, isEnabled: true)
        let second = ExtensionInstanceState(
            moduleID: "org.stow.sample", slot: .noteAccessory,
            noteID: secondNote.id, isEnabled: true)
        let provider = QueuedAccessoryProvider(blockingID: first.id)
        let store = AppStore(stateURL: stateURL(directory), accessoryProviders: [provider])
        await store.start()
        store.stop()
        defer { store.stop() }
        store.state.notes = [firstNote, secondNote]
        store.state.extensionInstances = [first, second]
        let refresh = Task { await store.refreshAccessories() }
        defer { refresh.cancel() }
        let started = await waitUntil { await provider.hasStarted(first.id) }
        XCTAssertTrue(started)
        let secondStartedEarly = await provider.hasStarted(second.id)
        XCTAssertFalse(secondStartedEarly)

        if deleteOwner { store.deleteNote(secondNote.id) } else { store.toggleSample(noteID: secondNote.id) }
        await provider.release()
        await refresh.value
        // Disable schedules a concurrent refresh; join it so the assertion covers both callers.
        await store.refreshAccessories()
        let startedIDs = await provider.startedIDs
        XCTAssertTrue(startedIDs.contains(first.id))
        XCTAssertFalse(
            startedIDs.contains(second.id),
            "A stale loop snapshot must not start a now-disabled or removed accessory")
        XCTAssertNil(store.accessoryResults[second.id])
        XCTAssertEqual(store.sampleEnabled(noteID: secondNote.id), false)
        if deleteOwner {
            XCTAssertNil(store.note(secondNote.id))
            XCTAssertFalse(store.state.extensionInstances.contains { $0.id == second.id })
        } else {
            XCTAssertEqual(store.state.extensionInstances.first { $0.id == second.id }?.isEnabled, false)
        }
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "StowCancellationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func stateURL(_ directory: URL) -> URL { directory.appendingPathComponent("state.json") }

    private func waitUntil(_ predicate: @MainActor () async -> Bool) async -> Bool {
        for _ in 0..<50 {
            if await predicate() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await predicate()
    }
}

private actor CancelledDetailClient: GitHubClient {
    enum Outcome: Sendable { case success, failure }
    let outcome: Outcome
    private(set) var didStart = false
    private(set) var didObserveCancellation = false
    private(set) var didFinish = false

    init(outcome: Outcome) { self.outcome = outcome }

    func refresh(pins: [PullRequestReference], previous: [PullRequestSnapshot], expectedViewerLogin: String?)
        async throws -> GitHubRefreshResult
    {
        .init(viewerLogin: "synthetic-viewer", snapshots: [])
    }

    func details(for reference: PullRequestReference) async throws -> PullRequestDetails {
        didStart = true
        do { try await Task.sleep(for: .seconds(30)) } catch is CancellationError { didObserveCancellation = true }
        didFinish = true
        // Deliberately return or throw after cancellation to exercise AppStore's late-callback guard.
        switch outcome {
        case .success: return .init(latestComment: "Synthetic late comment must never be applied")
        case .failure: throw GitHubError.requestFailed
        }
    }
}

private actor QueuedAccessoryProvider: AccessoryProvider {
    nonisolated let descriptor = AccessoryDescriptor(
        id: "org.stow.sample", name: "Synthetic controlled provider", supportedSlots: [.noteAccessory])
    let blockingID: UUID
    private var isReleased = false
    private(set) var startedIDs: [UUID] = []

    init(blockingID: UUID) { self.blockingID = blockingID }
    func hasStarted(_ id: UUID) -> Bool { startedIDs.contains(id) }
    func release() { isReleased = true }

    func snapshot(for request: AccessoryRequest) async throws -> AccessorySnapshot {
        startedIDs.append(request.instanceID)
        if request.instanceID == blockingID {
            while !isReleased { try await Task.sleep(for: .milliseconds(10)) }
        }
        try Task.checkCancellation()
        return .init(primaryText: "Synthetic accessory result")
    }
}
