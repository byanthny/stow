import Foundation
import XCTest

@testable import StowCore

@MainActor
final class AttentionTests: XCTestCase {
    private func ready() -> PullRequestSnapshot {
        .init(
            reference: .init(owner: "sample", repository: "project", number: 1), title: "Synthetic",
            isViewerAuthor: true, isDraft: false, mergeable: "MERGEABLE", mergeStateStatus: "CLEAN",
            reviewDecision: "APPROVED", checksState: "SUCCESS", checksKnown: true, readinessIsComplete: true)
    }

    func testOwnAttentionPriorityAndDraftTerminalOverrides() {
        var snapshot = ready()
        XCTAssertEqual(classify(snapshot), .init(section: .needsYou, reason: "Ready to merge"))
        snapshot.checksState = "ERROR"
        XCTAssertEqual(classify(snapshot).reason, "Checks failing")
        snapshot.reviewDecision = "CHANGES_REQUESTED"
        XCTAssertEqual(classify(snapshot).reason, "Changes requested")
        snapshot.mergeStateStatus = "DIRTY"
        XCTAssertEqual(classify(snapshot).reason, "Resolve conflicts")
        snapshot.isDraft = true
        XCTAssertEqual(classify(snapshot), .init(section: .waiting, reason: "Draft"))
        snapshot.state = "MERGED"
        XCTAssertEqual(classify(snapshot).reason, "Merged")
        snapshot.state = "CLOSED"
        XCTAssertEqual(classify(snapshot).reason, "Closed")
    }

    func testStaleSuccessWaitsButKnownFailuresAndConflictsRemainActionable() {
        var snapshot = ready()
        snapshot.isStale = true
        XCTAssertEqual(classify(snapshot).section, .waiting)
        snapshot.checksState = "FAILURE"
        XCTAssertEqual(classify(snapshot), .init(section: .needsYou, reason: "Checks failing"))
        snapshot.mergeable = "CONFLICTING"
        XCTAssertEqual(classify(snapshot), .init(section: .needsYou, reason: "Resolve conflicts"))
    }

    func testKnownEmptyChecksAndReviewsPermitReadiness() {
        var snapshot = ready()
        snapshot.checksState = nil
        snapshot.reviewDecision = nil
        XCTAssertEqual(classify(snapshot).reason, "Ready to merge")
        snapshot.checksKnown = false
        XCTAssertEqual(classify(snapshot).section, .waiting)
        snapshot.checksKnown = true
        snapshot.readinessIsComplete = false
        XCTAssertEqual(classify(snapshot).section, .waiting)
    }

    func testUnknownAndIncompleteValuesNeverBecomeReady() {
        let mutations: [(inout PullRequestSnapshot) -> Void] = [
            { $0.state = "FUTURE" }, { $0.isDraft = nil }, { $0.mergeable = nil },
            { $0.mergeable = "UNKNOWN" }, { $0.mergeStateStatus = "FUTURE" },
            { $0.reviewDecision = "FUTURE" }, { $0.reviewDecision = "REVIEW_REQUIRED" },
            { $0.checksState = "FUTURE" }, { $0.checksKnown = false },
            { $0.readinessIsComplete = false }, { $0.isUnavailable = true },
        ]
        for mutation in mutations {
            var snapshot = ready()
            mutation(&snapshot)
            XCTAssertEqual(classify(snapshot).section, .waiting, "Unexpected readiness: \(snapshot)")
        }
    }

    func testOtherAuthorsAndUnknownOwnershipNeedDirectReview() {
        for author: Bool? in [false, nil] {
            var snapshot = ready()
            snapshot.isViewerAuthor = author
            snapshot.hasDirectReviewRequest = false
            snapshot.checksState = "FAILURE"
            snapshot.reviewDecision = "CHANGES_REQUESTED"
            XCTAssertEqual(classify(snapshot).section, .waiting)
            XCTAssertEqual(classify(snapshot, isPinned: true).reason, "Watching")
            snapshot.hasDirectReviewRequest = nil
            XCTAssertEqual(classify(snapshot).section, .waiting)
            snapshot.hasDirectReviewRequest = true
            XCTAssertEqual(classify(snapshot), .init(section: .needsYou, reason: "Review requested"))
        }
    }

    func testBehindIsInformationalAndConflictCanUseEitherField() {
        var snapshot = ready()
        snapshot.mergeStateStatus = "BEHIND"
        XCTAssertEqual(classify(snapshot), .init(section: .waiting, reason: "Behind base branch"))
        snapshot.mergeable = "CONFLICTING"
        XCTAssertEqual(classify(snapshot).reason, "Resolve conflicts")
        snapshot.mergeable = "MERGEABLE"
        snapshot.checksState = "FAILURE"
        XCTAssertEqual(classify(snapshot).reason, "Checks failing")
    }

    func testReviewAndChecksOutrankBeingBehind() {
        var snapshot = ready()
        snapshot.mergeStateStatus = "BEHIND"
        snapshot.reviewDecision = "REVIEW_REQUIRED"
        XCTAssertEqual(classify(snapshot), .init(section: .waiting, reason: "Review required"))
        snapshot.checksState = "PENDING"
        XCTAssertEqual(classify(snapshot), .init(section: .waiting, reason: "Checks pending"))
    }

    func testChecksShowGitHubStyleStatus() {
        let cases: [(String?, Bool, String, AttentionTone?)] = [
            ("SUCCESS", true, "Checks passed", .success), ("FAILURE", true, "Checks failing", .failure),
            ("ERROR", true, "Checks failing", .failure), ("PENDING", true, "Checks running", .pending),
            ("EXPECTED", true, "Checks running", .pending), (nil, true, "No checks", nil),
            (nil, false, "Checks unknown", nil),
        ]
        for (state, known, label, tone) in cases {
            var pullRequest = ready()
            pullRequest.checksState = state
            pullRequest.checksKnown = known
            XCTAssertEqual(pullRequest.checksStatus, ChecksStatus(label: label, tone: tone), state ?? "none")
        }
        XCTAssertEqual(checkTone("SUCCESS"), .success)
        XCTAssertEqual(checkTone("TIMED_OUT"), .failure)
        XCTAssertEqual(checkTone("IN_PROGRESS"), .pending)
        XCTAssertEqual(checkTone("SKIPPED"), .neutral)
    }

    func testCardsKeepChecksBelowAndNeverRepeatTheState() {
        let passed = ChecksStatus(label: "Checks passed", tone: .success)
        let failingChecks = ChecksStatus(label: "Checks failing", tone: .failure)

        // Failing checks move to the checks line, and the state line shows the review.
        var failing = ready()
        failing.checksState = "FAILURE"
        failing.reviewDecision = "APPROVED"
        XCTAssertEqual(
            failing.cardStatus(under: classify(failing)),
            CardStatus(headline: "Approved", tone: .success, notes: [], checks: failingChecks))
        failing.reviewDecision = nil
        XCTAssertNil(failing.cardStatus(under: classify(failing)).headline)

        var changes = ready()
        changes.reviewDecision = "CHANGES_REQUESTED"
        XCTAssertEqual(
            changes.cardStatus(under: classify(changes)),
            CardStatus(headline: "Changes requested", tone: .failure, notes: [], checks: passed))

        var conflicts = ready()
        conflicts.mergeable = "CONFLICTING"
        conflicts.reviewDecision = "APPROVED"
        conflicts.mergeStateStatus = "BEHIND"
        XCTAssertEqual(
            conflicts.cardStatus(under: classify(conflicts)),
            CardStatus(
                headline: "Resolve conflicts", tone: .failure, notes: ["Approved", "Behind base"], checks: passed))

        var behind = ready()
        behind.mergeStateStatus = "BEHIND"
        XCTAssertFalse(
            behind.cardStatus(under: classify(behind)).notes.contains("Behind base"), "It's already the headline")
    }

    func testStatusTonesFollowGitHubColors() {
        let tones: [(String, AttentionTone)] = [
            ("Ready to merge", .success), ("Checks failing", .failure), ("Resolve conflicts", .failure),
            ("Changes requested", .failure), ("Closed", .failure), ("Review requested", .pending),
            ("Review required", .pending), ("Waiting for review", .pending), ("Checks pending", .pending),
            ("Behind base branch", .pending), ("Draft", .neutral), ("Watching", .neutral), ("Merged", .neutral),
            ("Unavailable", .neutral), ("Readiness unknown", .neutral),
        ]
        for (reason, tone) in tones {
            XCTAssertEqual(AttentionClassification(section: .waiting, reason: reason).tone, tone, reason)
        }
        XCTAssertEqual(classify(ready()).tone, .success)
        var draft = ready()
        draft.isDraft = true
        XCTAssertEqual(classify(draft).tone, .neutral)
    }
}

@MainActor
final class PasteTests: XCTestCase {
    func testCanonicalURLAndOptionalText() {
        let reference = PullRequestReference(owner: "example", repository: "sample.repo", number: 42)
        XCTAssertEqual(parsePaste("https://github.com/example/sample.repo/pull/42"), .pin(reference, note: nil))
        XCTAssertEqual(
            parsePaste(
                " https://github.com/example/sample.repo/pull/42/?tab=files#discussion\n\nCheck this tomorrow. "),
            .pin(reference, note: "Check this tomorrow."))
        XCTAssertEqual(PullRequestReference.parse("https://GITHUB.com/example/sample.repo/pull/42/"), reference)
    }

    func testUnrecognizedAndAmbiguousPasteRemainsIntact() {
        let cases = [
            "a normal note", "", "https://github.com.evil.test/o/r/pull/1",
            "https://evil.github.com/o/r/pull/1", "http://github.com/o/r/pull/1",
            "https://github.com@evil.test/o/r/pull/1", "https://user@github.com/o/r/pull/1",
            "https://github.com:443/o/r/pull/1", "https://github.com/o/r/pull/0",
            "https://github.com/o/r/pull/-1", "https://github.com/o/r/pull/99999999999999999999999999",
            "https://github.com/o/r/issues/1", "please see https://github.com/o/r/pull/1",
            "https://github.com/o/r/pull/1\nhttps://github.com/o/r/pull/2",
            "https://github.com/o/r/pull/1 note https://example.test",
            "https://github.com/o/r/pull/1 note www.example.test",
            "https://github.com/o/r/pull/1/files", "https://github.com/o/r/pull/1,",
            "https://github.com/o/r%2Fother/pull/1", "https://github.com/o/../pull/1",
        ]
        for input in cases { XCTAssertEqual(parsePaste(input), .note(input), input) }
    }
}

@MainActor
final class StateRepositoryTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "StowCoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func state(_ markdown: String) -> AppState {
        var state = AppState()
        let time = Date(timeIntervalSince1970: 1_700_000_000)
        state.notes = [
            .init(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, markdown: markdown,
                pullRequest: .init(owner: "fixture", repository: "synthetic", number: 6),
                createdAt: time, updatedAt: time)
        ]
        state.pins = [.init(owner: "fixture", repository: "synthetic", number: 6)]
        state.boardFrame = .init(x: 1, y: 2, width: 300, height: 500)
        return state
    }

    func testRoundTripAndLastEditWins() async throws {
        let url = try directory().appendingPathComponent("owned/state.json")
        let repository = StateRepository(url: url)
        let empty = try await repository.load()
        XCTAssertEqual(empty, AppState())
        try await repository.save(state("first"))
        try await repository.save(state("last edit"))
        let result = try await StateRepository(url: url).load()
        XCTAssertEqual(result, state("last edit"))
        let json = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(json.contains("2023-11-14T22:13:20Z"))
        XCTAssertFalse(json.contains("last edit"), "The index must not duplicate Markdown source")
        let sourceURL = await repository.noteFileURL(id: result.notes[0].id)
        XCTAssertEqual(try Data(contentsOf: sourceURL), Data("last edit".utf8))
    }

    func testSaveAndCloseKeepsFinalSnapshotWhenOlderQueuedWriteArrivesLater() async throws {
        let url = try directory().appendingPathComponent("state.json")
        let repository = StateRepository(url: url)
        let older = state("older captured edit")
        let final = state("final quit edit")
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        let queuedOlderWrite = Task.detached {
            for await _ in stream {
                try await repository.save(older)
                break
            }
        }
        try await repository.saveAndClose(final)
        continuation.yield(())
        continuation.finish()
        try await queuedOlderWrite.value
        try await repository.saveAndClose(older)
        let persisted = try await StateRepository(url: url).load()
        XCTAssertEqual(persisted, final)
    }

    func testFailedSaveAndCloseRemainsOpenForEditsAndRetry() async throws {
        let url = try directory().appendingPathComponent("state.json")
        let repository = StateRepository(url: url)
        try await repository.save(state("before failed close"))
        var invalid = state("invalid quit snapshot")
        invalid.boardFrame = .init(x: .nan, y: 0, width: 300, height: 500)
        do {
            try await repository.saveAndClose(invalid)
            XCTFail("Expected failed close")
        } catch { XCTAssertEqual(error as? StateError, .unwritable) }
        try await repository.save(state("kept open edit"))
        let keptOpen = try await StateRepository(url: url).load()
        XCTAssertEqual(keptOpen, state("kept open edit"))
        try await repository.saveAndClose(state("successful retry"))
        try await repository.save(state("must not overwrite final"))
        let persisted = try await StateRepository(url: url).load()
        XCTAssertEqual(persisted, state("successful retry"))
    }

    func testNewStoragePermissionsAndExistingDirectoryPreserved() async throws {
        let root = try directory()
        let newURL = root.appendingPathComponent("created/state.json")
        try await StateRepository(url: newURL).save(state("private"))
        func permissions(_ url: URL) throws -> Int {
            (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber).intValue
                & 0o777
        }
        XCTAssertEqual(try permissions(newURL.deletingLastPathComponent()), 0o700)
        XCTAssertEqual(try permissions(newURL), 0o600)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        try await StateRepository(url: root.appendingPathComponent("state.json")).save(state("existing parent"))
        XCTAssertEqual(try permissions(root), 0o755)
    }

    func testReplacementIsPrivateAndFailedEncodingPreservesOriginalWithoutTemporaryFiles() async throws {
        let root = try directory()
        let url = root.appendingPathComponent("state.json")
        let repository = StateRepository(url: url)
        try await repository.save(state("original"))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        try await repository.save(state("private replacement"))
        let mode = (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber).intValue
        XCTAssertEqual(mode & 0o777, 0o600)
        let original = try Data(contentsOf: url)
        var invalid = state("must not replace")
        invalid.boardFrame = .init(x: .nan, y: 0, width: 300, height: 500)
        do {
            try await repository.save(invalid)
            XCTFail("Expected nonfinite JSON encode failure")
        } catch { XCTAssertEqual(error as? StateError, .unwritable) }
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(), ["notes", "state.json"])
    }

    func testCorruptStatePreservedAndExplicitBackupAllowsRecovery() async throws {
        let url = try directory().appendingPathComponent("state.json")
        let corrupt = Data("{not-json".utf8)
        try corrupt.write(to: url)
        let repository = StateRepository(url: url)
        do {
            _ = try await repository.load()
            XCTFail("Expected corruption")
        } catch { XCTAssertEqual(error as? StateError, .corrupt) }
        do {
            try await repository.save(state("replacement"))
            XCTFail("Expected recovery gate")
        } catch { XCTAssertEqual(error as? StateError, .recoveryRequired) }
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
        let backup = try await repository.recoverByBackingUp()
        XCTAssertNotNil(backup)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(backup)), corrupt)
        try await repository.save(state("recovered"))
        let recovered = try await repository.load()
        XCTAssertEqual(recovered, state("recovered"))
    }

    func testNewerSchemaRefusesOverwriteEvenWithoutPriorLoad() async throws {
        let url = try directory().appendingPathComponent("state.json")
        let newer = Data(#"{"schemaVersion":999,"future":"data"}"#.utf8)
        try newer.write(to: url)
        let repository = StateRepository(url: url)
        do {
            try await repository.save(state("replace"))
            XCTFail("Expected unsupported schema")
        } catch { XCTAssertEqual(error as? StateError, .unsupportedVersion(999)) }
        do {
            try await repository.save(state("again"))
            XCTFail("Expected recovery gate")
        } catch { XCTAssertEqual(error as? StateError, .recoveryRequired) }
        XCTAssertEqual(try Data(contentsOf: url), newer)
    }

    func testDeterministicWriteFailureUsesSanitizedError() async throws {
        let blocker = try directory().appendingPathComponent("regular-file")
        try Data("blocker".utf8).write(to: blocker)
        let repository = StateRepository(url: blocker.appendingPathComponent("state.json"))
        do {
            try await repository.save(state("cannot write"))
            XCTFail("Expected failure")
        } catch {
            XCTAssertEqual(error as? StateError, .unwritable)
            XCTAssertFalse(error.localizedDescription.contains(blocker.path))
        }
        XCTAssertEqual(try String(contentsOf: blocker, encoding: .utf8), "blocker")
    }
}

@MainActor
final class ReconciliationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private func snapshot(_ state: String = "OPEN") -> PullRequestSnapshot {
        .init(
            reference: .init(owner: "sample", repository: "synthetic", number: 1), title: "Last good title",
            isViewerAuthor: true, state: state, isDraft: false, fetchedAt: now,
            observedStateSince: now.addingTimeInterval(-500))
    }

    func testTerminalObservedAtStartsAtFirstObservationAndExpiresAfter24Hours() throws {
        let initial = reconcileSnapshots(previous: [], incoming: [snapshot("MERGED")], pins: [], now: now)
        XCTAssertEqual(initial.first?.terminalObservedAt, now)
        let next = reconcileSnapshots(
            previous: initial, incoming: [snapshot("MERGED")], pins: [], now: now.addingTimeInterval(3600))
        XCTAssertEqual(next.first?.terminalObservedAt, now)
        XCTAssertEqual(next.first?.observedStateSince, now)
        XCTAssertEqual(
            reconcileSnapshots(previous: next, incoming: [], pins: [], now: now.addingTimeInterval(86_399)).count, 1)
        XCTAssertTrue(
            reconcileSnapshots(previous: next, incoming: [], pins: [], now: now.addingTimeInterval(86_400)).isEmpty)
    }

    func testPinnedTerminalRetainedAndReopenedClearsTerminalDate() {
        var old = snapshot("CLOSED")
        old.terminalObservedAt = now.addingTimeInterval(-200_000)
        let retained = reconcileSnapshots(previous: [old], incoming: [], pins: [old.reference], now: now)
        XCTAssertEqual(retained.count, 1)
        XCTAssertEqual(retained.first?.terminalObservedAt, old.terminalObservedAt)
        let reopened = reconcileSnapshots(previous: [old], incoming: [snapshot()], pins: [], now: now)
        XCTAssertNil(reopened.first?.terminalObservedAt)
        XCTAssertEqual(reopened.first?.observedStateSince, now)
    }

    func testMissingAndUnavailablePreserveLastGoodContent() {
        var old = snapshot()
        old.details = .init(latestComment: "Synthetic comment", fetchedAt: now)
        let missing = reconcileSnapshots(previous: [old], incoming: [], pins: [], now: now)
        XCTAssertEqual(missing.first?.title, old.title)
        XCTAssertEqual(missing.first?.details, old.details)
        XCTAssertEqual(missing.first?.isStale, true)
        XCTAssertEqual(missing.first?.observedStateSince, old.observedStateSince)
        var unavailable = snapshot()
        unavailable.title = "Unavailable placeholder"
        unavailable.isUnavailable = true
        unavailable.fetchedAt = now.addingTimeInterval(60)
        let result = reconcileSnapshots(
            previous: [old], incoming: [unavailable], pins: [], now: now.addingTimeInterval(60))
        XCTAssertEqual(result.first?.title, old.title)
        XCTAssertEqual(result.first?.details, old.details)
        XCTAssertEqual(result.first?.isUnavailable, true)
        XCTAssertEqual(result.first?.isStale, true)
        XCTAssertEqual(result.first?.observedStateSince, now.addingTimeInterval(60))
    }

    func testOnlyMeaningfulClassificationChangesResetObservedAge() {
        let old = snapshot()
        var renamed = old
        renamed.title = "New synthetic title"
        renamed.updatedAt = now
        renamed.fetchedAt = now
        var result = reconcileSnapshots(previous: [old], incoming: [renamed], pins: [], now: now)
        XCTAssertEqual(result.first?.observedStateSince, old.observedStateSince)
        renamed.checksState = "FAILURE"
        result = reconcileSnapshots(previous: [old], incoming: [renamed], pins: [], now: now)
        XCTAssertEqual(result.first?.observedStateSince, now)
        var secondFailure = renamed
        secondFailure.title = "Still failed"
        result = reconcileSnapshots(
            previous: result, incoming: [secondFailure], pins: [], now: now.addingTimeInterval(100))
        XCTAssertEqual(result.first?.observedStateSince, now)
    }

    func testProviderTerminalTimestampCannotInventObservationAndDuplicateIDsAreSafe() {
        var incoming = snapshot("CLOSED")
        incoming.terminalObservedAt = now.addingTimeInterval(-500_000)
        let result = reconcileSnapshots(previous: [], incoming: [incoming, incoming], pins: [], now: now)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.terminalObservedAt, now)
    }
}

final class ReferenceIdentityTests: XCTestCase {
    func testGitHubReferenceIdentityIsCaseInsensitive() {
        let pasted = PullRequestReference(owner: "Example", repository: "Desktop", number: 42)
        let fetched = PullRequestReference(owner: "example", repository: "desktop", number: 42)
        XCTAssertEqual(pasted, fetched)
        XCTAssertTrue([pasted].contains(fetched))
        XCTAssertEqual(Set([pasted, fetched]).count, 1)
    }
}
