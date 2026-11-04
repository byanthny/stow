import AppKit
import Foundation
import StowCore
import StowGitHub
import XCTest

@testable import Stow

/// The owner selection on the board: what it hides and never hides, the owner control, grouping by owner, keeping
/// only selected owners on disk, and the notes setting. Synthetic state in temporary folders and a synthetic client.
@MainActor
final class OwnerViewTests: XCTestCase {
    func testSelectionHidesOtherOwnersButNotPinsOrWarnings() async throws {
        let review = card("Acme", "app", 1, "Synthetic acme review", reviewRequested: true)
        let waiting = card("beta", "lib", 2, "Synthetic beta card")
        let pinned = card("beta", "kit", 3, "Synthetic pinned beta card")
        let (store, client) = try await startStore(cards: [review, waiting, pinned]) { $0.pins = [pinned.reference] }
        await store.refresh()
        XCTAssertEqual(store.cards(in: .needsYou).map(\.id), [review.id])
        XCTAssertEqual(store.cards(in: .waiting).map(\.id), [waiting.id, pinned.id])

        store.setOwnerSelection(OwnerSelection(["acme"]))
        XCTAssertEqual(store.cards(in: .needsYou).map(\.id), [review.id], "Owners match ignoring case")
        XCTAssertEqual(store.cards(in: .waiting).map(\.id), [pinned.id], "A pinned card shows whatever the selection")
        XCTAssertTrue(store.showsOwnerControl)
        XCTAssertEqual(
            store.ownerSummaries,
            [
                OwnerSummary(owner: "Acme", cardCount: 1, isSelected: true),
                OwnerSummary(owner: "beta", cardCount: 2, isSelected: false),
            ])
        let saved = await store.flush()
        XCTAssertTrue(saved)
        let persisted = try await StateRepository(url: store.stateURL).load()
        XCTAssertEqual(persisted.ownerSelection.owners, ["acme"])

        // Refreshes still reach every owner's cards, and their warnings show whatever the selection.
        await client.answer(isComplete: false, warning: "Synthetic incomplete-data warning")
        await store.refresh()
        XCTAssertEqual(store.githubMessage, "Synthetic incomplete-data warning")
        XCTAssertEqual(Set(store.state.pullRequests.map(\.id)), [review.id, waiting.id, pinned.id])
        XCTAssertEqual(store.cards(in: .waiting).map(\.id), [pinned.id])
        // Dismissing still applies to every card, shown or not.
        store.dismiss(waiting.reference)
        XCTAssertEqual(store.ownerSummaries.map(\.cardCount), [1, 1])
        // Another account still pauses the profile and shows its banner, whatever the selection.
        await client.answer(as: "synthetic-other-account")
        await store.refresh()
        XCTAssertEqual(store.accountMismatch, "synthetic-other-account")
        XCTAssertEqual(store.cards(in: .needsYou).map(\.id), [review.id])
    }

    func testClassificationIsUnchangedUnderSelection() async throws {
        func authored(_ owner: String, _ number: Int, _ change: (inout PullRequestSnapshot) -> Void)
            -> PullRequestSnapshot
        {
            var snapshot = card(owner, "app", number, "Synthetic \(owner) change \(number)")
            snapshot.isViewerAuthor = true
            snapshot.isDraft = false
            change(&snapshot)
            return snapshot
        }
        let pinned = card("beta", "kit", 7, "Synthetic pinned beta card")
        let cards = [
            authored("acme", 1) {
                $0.mergeable = "MERGEABLE"
                $0.mergeStateStatus = "CLEAN"
                $0.checksKnown = true
                $0.checksState = "SUCCESS"
                $0.reviewDecision = "APPROVED"
                $0.readinessIsComplete = true
            },
            authored("beta", 2) { $0.reviewDecision = "CHANGES_REQUESTED" },
            authored("acme", 3) { $0.checksState = "FAILURE" },
            authored("beta", 4) { $0.isDraft = true },
            card("acme", "lib", 5, "Synthetic acme review", reviewRequested: true),
            card("beta", "lib", 6, "Synthetic beta card"),
            pinned,
            authored("acme", 8) { $0.state = "MERGED" },
        ]
        let (store, _) = try await startStore(cards: cards) { $0.pins = [pinned.reference] }
        await store.refresh()
        let sections: [AttentionSection] = [.needsYou, .waiting]
        var everything: [AttentionSection: [PullRequestSnapshot]] = [:]
        var reasons: [String: String] = [:]
        for section in sections {
            everything[section] = store.cards(in: section)
            for card in store.cards(in: section) {
                reasons[card.id] = classify(card, isPinned: store.state.pins.contains(card.reference)).reason
            }
        }
        XCTAssertEqual(reasons.count, cards.count)
        XCTAssertEqual(
            Set(reasons.values),
            [
                "Ready to merge", "Changes requested", "Checks failing", "Draft", "Review requested",
                "Waiting for review", "Watching", "Merged",
            ])
        let cached = store.state.pullRequests

        for owners in [["acme"], ["BETA"], ["acme", "beta"], ["synthetic-gamma"]] {
            store.setOwnerSelection(OwnerSelection(owners))
            let selection = store.state.ownerSelection
            for section in sections {
                // The same cards in the same order, less other owners' unpinned cards.
                let expected = (everything[section] ?? []).filter {
                    selection.contains($0.reference.owner) || $0.id == pinned.id
                }
                XCTAssertEqual(store.cards(in: section), expected, "\(owners) in \(section)")
                for card in store.cards(in: section) {
                    let classification = classify(card, isPinned: store.state.pins.contains(card.reference))
                    XCTAssertEqual(classification.section, section)
                    XCTAssertEqual(classification.reason, reasons[card.id])
                }
            }
            XCTAssertEqual(store.state.pullRequests, cached, "A selection never changes the cached cards")
        }
    }

    func testKeepOnlySelectedOwnersPrunesStateAndBackup() async throws {
        let acme = card("acme", "app", 1, "Synthetic acme title")
        let beta = card("beta", "lib", 2, "Synthetic beta-only title")
        let pinned = card("beta", "kit", 3, "Synthetic pinned beta title")
        let (store, client) = try await startStore(cards: [acme, beta, pinned]) { state in
            state.pins = [pinned.reference]
            state.ownerSelection = OwnerSelection(["acme"])
            state.pullRequests = [acme, beta, pinned]
        }
        let shownBefore = store.cards(in: .waiting).map(\.id)

        store.setKeepsOnlySelectedOwners(true)
        XCTAssertEqual(Set(store.state.pullRequests.map(\.id)), [acme.id, pinned.id])
        XCTAssertEqual(
            store.cards(in: .waiting).map(\.id), shownBefore, "Pruning changes what is saved, not what shows")
        // The owner control still counts the other owner's cards, from memory.
        XCTAssertEqual(store.ownerSummaries.map(\.owner), ["acme", "beta"])
        XCTAssertEqual(store.ownerSummaries.map(\.cardCount), [1, 2])
        let saved = await store.flush()
        XCTAssertTrue(saved)
        var file = try String(contentsOf: store.stateURL, encoding: .utf8)
        XCTAssertFalse(file.contains("Synthetic beta-only title"))
        XCTAssertTrue(file.contains("Synthetic pinned beta title"), "Pins stay on disk")
        XCTAssertTrue(file.contains("Synthetic acme title"))
        let backup = try String(decoding: StowBackup.encode(await store.portableSnapshot()), as: UTF8.self)
        XCTAssertFalse(backup.contains("Synthetic beta-only title"))
        XCTAssertTrue(backup.contains("Synthetic pinned beta title"))

        // A refresh keeps other owners' cards in memory only.
        await store.refresh()
        XCTAssertEqual(Set(store.state.pullRequests.map(\.id)), [acme.id, pinned.id])
        XCTAssertEqual(store.ownerSummaries.map(\.cardCount), [1, 2])
        _ = await store.flush()
        file = try String(contentsOf: store.stateURL, encoding: .utf8)
        XCTAssertFalse(file.contains("Synthetic beta-only title"))

        // Unpinning lets a card of an owner outside the selection leave the disk too, and pinning brings it back
        // from memory with its title.
        store.togglePin(pinned.reference)
        XCTAssertEqual(store.state.pullRequests.map(\.id), [acme.id])
        XCTAssertEqual(store.ownerSummaries.map(\.cardCount), [1, 2])
        var refreshes = await client.refreshes
        store.togglePin(pinned.reference)
        XCTAssertEqual(Set(store.state.pullRequests.map(\.id)), [acme.id, pinned.id])
        XCTAssertEqual(store.state.pullRequests.first { $0.id == pinned.id }?.title, "Synthetic pinned beta title")
        var refreshed = await waitUntil { await client.refreshes > refreshes && !store.isRefreshing }
        XCTAssertTrue(refreshed, "Pinning refreshes")

        // Adding an owner shows its cards at once and refreshes; so does taking one out.
        refreshes = await client.refreshes
        store.setOwnerSelection(OwnerSelection(["acme", "beta"]))
        XCTAssertEqual(Set(store.cards(in: .waiting).map(\.id)), [acme.id, beta.id, pinned.id])
        refreshed = await waitUntil { await client.refreshes > refreshes && !store.isRefreshing }
        XCTAssertTrue(refreshed)
        refreshes = await client.refreshes
        store.setOwnerSelection(OwnerSelection(["acme"]))
        XCTAssertEqual(Set(store.state.pullRequests.map(\.id)), [acme.id, pinned.id])
        refreshed = await waitUntil { await client.refreshes > refreshes && !store.isRefreshing }
        XCTAssertTrue(refreshed)
        XCTAssertEqual(Set(store.state.pullRequests.map(\.id)), [acme.id, pinned.id])
        _ = await store.flush()

        // Reopened, the profile knows other owners only from what it kept: its pins.
        store.stop()
        let reopened = AppStore(stateURL: store.stateURL, githubClient: client, accessoryProviders: [])
        await reopened.start()
        defer { reopened.stop() }
        XCTAssertTrue(reopened.state.keepsOnlySelectedOwners)
        XCTAssertEqual(Set(reopened.state.pullRequests.map(\.id)), [acme.id, pinned.id])
        XCTAssertEqual(reopened.ownerSummaries.map(\.cardCount), [1, 1])

        // Turning the setting off saves every owner's cards again from the next refresh on.
        await reopened.refresh()
        XCTAssertEqual(reopened.ownerSummaries.map(\.cardCount), [1, 2])
        reopened.setKeepsOnlySelectedOwners(false)
        XCTAssertEqual(Set(reopened.state.pullRequests.map(\.id)), [acme.id, beta.id, pinned.id])
        _ = await reopened.flush()
        XCTAssertTrue(try String(contentsOf: store.stateURL, encoding: .utf8).contains("Synthetic beta-only title"))
    }

    func testLinkedNotesHiddenOnlyWithSetting() async throws {
        let acme = card("acme", "app", 1, "Synthetic acme card")
        let beta = card("beta", "lib", 2, "Synthetic beta card")
        let pinned = card("beta", "kit", 3, "Synthetic pinned beta card")
        let standalone = Note(markdown: "Synthetic standalone note")
        let acmeNote = Note(markdown: "Synthetic acme note", pullRequest: acme.reference)
        let betaNote = Note(markdown: "Synthetic beta note", pullRequest: beta.reference)
        let detached = Note(markdown: "Synthetic detached beta note", pullRequest: beta.reference, isDetached: true)
        let pinnedNote = Note(markdown: "Synthetic pinned beta note", pullRequest: pinned.reference)
        let notes = [standalone, acmeNote, betaNote, detached, pinnedNote]
        let (_, session, _) = try await startProfile(cards: [acme, beta, pinned]) { state in
            state.notes = notes
            state.pins = [pinned.reference]
            state.pullRequests = [acme, beta, pinned]
            state.ownerSelection = OwnerSelection(["acme"])
        }
        let store = session.store
        XCTAssertEqual(session.noteWindows[detached.id]?.isVisible, true)

        // Off by default: the selection never hides notes.
        XCTAssertEqual(store.visibleNotes.map(\.id), notes.map(\.id))
        XCTAssertEqual(NotesHeading(store: store), NotesHeading(count: 5, hiddenCount: 0))
        XCTAssertNil(NotesHeading(store: store).detail)

        store.setHidesNotesForHiddenOwners(true)
        // Standalone notes always show, and so do notes on pinned cards, which show whatever the selection.
        XCTAssertEqual(store.visibleNotes.map(\.id), [standalone.id, acmeNote.id, pinnedNote.id])
        XCTAssertEqual(NotesHeading(store: store), NotesHeading(count: 3, hiddenCount: 2))
        XCTAssertEqual(NotesHeading(store: store).detail, "2 hidden")
        // Hiding a board note keeps the note, and a detached note's window stays open.
        XCTAssertEqual(store.state.notes.map(\.id), notes.map(\.id))
        XCTAssertEqual(session.noteWindows[detached.id]?.isVisible, true)
        let saved = await store.flush()
        XCTAssertTrue(saved)
        let persisted = try await StateRepository(url: store.stateURL).load()
        XCTAssertTrue(persisted.boardLayout.hidesNotesForHiddenOwners)
        XCTAssertEqual(persisted.notes.count, notes.count)

        // All owners hides nothing.
        store.setOwnerSelection(OwnerSelection())
        XCTAssertEqual(store.visibleNotes.map(\.id), notes.map(\.id))
        XCTAssertNil(NotesHeading(store: store).detail)
        // Without GitHub there is no owner control to show the filter, so it hides nothing.
        store.setOwnerSelection(OwnerSelection(["acme"]))
        XCTAssertEqual(store.visibleNotes.count, 3)
        store.setGitHubEnabled(false)
        XCTAssertEqual(store.visibleNotes.map(\.id), notes.map(\.id))
    }

    func testOwnerControlAppearsWithSeveralOwnersAndChangesTheSelection() async throws {
        let acme = card("acme", "app", 1, "Synthetic acme card")
        let beta = card("beta", "lib", 2, "Synthetic beta card")
        let (_, session, client) = try await startProfile(cards: [acme]) { $0.pullRequests = [acme] }
        let store = session.store
        // One profile and one owner: the header is as it was, with no owner control.
        let laidOut = await layOut(session)
        XCTAssertTrue(laidOut)
        XCTAssertFalse(store.showsOwnerControl)
        XCTAssertTrue(subviews(of: OwnerMenuButtonView.self, in: session.board.contentView).isEmpty)

        await client.answer(with: [acme, beta])
        await store.refresh()
        XCTAssertTrue(store.showsOwnerControl)
        let button = try await ownerButton(in: session)
        XCTAssertEqual(button.accessibilityIdentifier(), "board.ownerMenu")
        XCTAssertEqual(button.accessibilityLabel(), "Owners")
        XCTAssertEqual(button.accessibilityValue() as? String, "All owners")
        XCTAssertEqual(button.toolTip, "Owners")
        XCTAssertEqual(menuTitles(button), ["All owners", "", "acme (1)", "beta (1)", "", "Add owner…"])
        XCTAssertEqual(menuStates(button), [.on, .off, .off, .off])

        perform("beta (1)", in: button)
        XCTAssertEqual(store.state.ownerSelection.owners, ["beta"])
        XCTAssertEqual(store.cards(in: .waiting).map(\.id), [beta.id])
        XCTAssertEqual(menuStates(button), [.off, .off, .on, .off])
        let described = await waitUntil {
            session.board.contentView?.layoutSubtreeIfNeeded()
            return button.accessibilityValue() as? String == "beta"
        }
        XCTAssertTrue(described)
        XCTAssertEqual(button.toolTip, "Owners: beta")
        perform("acme (1)", in: button)
        XCTAssertEqual(store.state.ownerSelection.owners, ["acme", "beta"])
        perform("beta (1)", in: button)
        XCTAssertEqual(store.state.ownerSelection.owners, ["acme"])
        perform("All owners", in: button)
        XCTAssertTrue(store.state.ownerSelection.isAll)
        XCTAssertEqual(menuStates(button), [.on, .off, .off, .off])

        // Owners follow the owner order, which grouping also uses.
        await client.answer(with: [acme, beta, card("beta", "kit", 3, "Synthetic second beta card")])
        await store.refresh()
        store.setOwnerOrder(.mostCards)
        XCTAssertEqual(menuTitles(button), ["All owners", "", "beta (2)", "acme (1)", "", "Add owner…"])
    }

    func testGroupingAddsOwnerSubheadingsAndShowMoreCountsPerSection() async throws {
        // Waiting cards, newest first: beta, acme, beta, acme, beta.
        let cards = [
            card("beta", "one", 1, "Synthetic card 1"), card("acme", "two", 2, "Synthetic card 2"),
            card("beta", "three", 3, "Synthetic card 3"), card("acme", "four", 4, "Synthetic card 4"),
            card("beta", "five", 5, "Synthetic card 5"),
        ]
        let (store, _) = try await startStore(cards: cards)
        await store.refresh()
        let waiting = store.cards(in: .waiting)
        XCTAssertEqual(waiting.map(\.reference.number), [1, 2, 3, 4, 5])
        func numbers(_ listed: SectionCards) -> [[Int]] { listed.groups.map { $0.cards.map(\.reference.number) } }

        // Off by default: one list, three cards, and Show 2 more, as before.
        var listed = SectionCards(waiting, layout: store.state.boardLayout, expanded: false)
        XCTAssertEqual(listed.groups.map(\.owner), [nil])
        XCTAssertEqual(numbers(listed), [[1, 2, 3]])
        XCTAssertEqual(listed.moreCount, 2)

        store.setGroupByOwner(true)
        listed = SectionCards(waiting, layout: store.state.boardLayout, expanded: false)
        XCTAssertEqual(listed.groups.map(\.owner), ["acme", "beta"])
        XCTAssertEqual(listed.groups.map(\.count), [2, 3], "Each subheading counts its owner's cards in the section")
        XCTAssertEqual(numbers(listed), [[2, 4], [1]], "Cards keep their order within each owner")
        XCTAssertEqual(listed.moreCount, 2, "Show more still counts cards per section")
        listed = SectionCards(waiting, layout: store.state.boardLayout, expanded: true)
        XCTAssertEqual(numbers(listed), [[2, 4], [1, 3, 5]])
        XCTAssertEqual(listed.moreCount, 0)

        store.setOwnerOrder(.mostCards)
        listed = SectionCards(waiting, layout: store.state.boardLayout, expanded: false)
        XCTAssertEqual(
            listed.groups.map(\.owner), ["beta"], "An owner whose cards are all after Show more waits for it")
        XCTAssertEqual(numbers(listed), [[1, 3, 5]])
        XCTAssertEqual(listed.moreCount, 2)
        let saved = await store.flush()
        XCTAssertTrue(saved)
        let persisted = try await StateRepository(url: store.stateURL).load()
        XCTAssertTrue(persisted.boardLayout.groupByOwner)
        XCTAssertEqual(persisted.boardLayout.ownerOrder, .mostCards)
    }

    func testAddOwnerTakesOnlyGitHubLoginsAndRefreshesWhenKeepingOnlySelectedOwners() async throws {
        let invalid = ["", "-acme", "acme-", "a--b", "a_b", "acme labs", "ácme", String(repeating: "a", count: 40)]
        for login in invalid { XCTAssertNotNil(AddOwnerPrompt.problem(with: login), login) }
        for login in ["a", "acme-labs", "Acme2", String(repeating: "a", count: 39)] {
            XCTAssertNil(AddOwnerPrompt.problem(with: login), login)
        }
        XCTAssertEqual(AddOwnerPrompt.problem(with: ""), "Enter the owner’s GitHub login.")
        XCTAssertEqual(
            AddOwnerPrompt.problem(with: "a_b"), "A GitHub login uses only letters from A to Z, numbers, and hyphens.")
        XCTAssertEqual(
            AddOwnerPrompt.problem(with: String(repeating: "a", count: 40)), "A GitHub login has at most 39 characters."
        )
        XCTAssertEqual(
            AddOwnerPrompt.problem(with: "a--b"),
            "A GitHub login can’t start or end with a hyphen or have two hyphens in a row.")

        XCTAssertEqual(OwnerSelection(["acme"]).adding("Beta").owners, ["acme", "Beta"])
        XCTAssertEqual(OwnerSelection(["acme"]).adding("ACME").owners, ["acme"])
        XCTAssertEqual(OwnerSelection(["acme", "beta"]).toggling("ACME").owners, ["beta"])
        XCTAssertTrue(OwnerSelection(["acme"]).toggling("acme").isAll, "Taking out the last owner selects All owners")

        // An owner added before it has cards lists with a count of zero. Keeping only selected owners on disk,
        // adding one refreshes at once so its cards arrive.
        let acme = card("acme", "app", 1, "Synthetic acme card")
        let (store, client) = try await startStore(cards: [acme]) { state in
            state.pullRequests = [acme]
            state.ownerSelection = OwnerSelection(["acme"])
            state.keepsOnlySelectedOwners = true
        }
        let refreshes = await client.refreshes
        store.setOwnerSelection(store.state.ownerSelection.adding("synthetic-gamma"))
        XCTAssertEqual(store.state.ownerSelection.owners, ["acme", "synthetic-gamma"])
        XCTAssertEqual(
            store.ownerSummaries.last, OwnerSummary(owner: "synthetic-gamma", cardCount: 0, isSelected: true))
        let refreshed = await waitUntil { await client.refreshes > refreshes && !store.isRefreshing }
        XCTAssertTrue(refreshed)
    }

    // MARK: helpers

    /// An open pull request by someone else, newest first by number.
    private func card(
        _ owner: String, _ repository: String, _ number: Int, _ title: String, reviewRequested: Bool = false
    ) -> PullRequestSnapshot {
        PullRequestSnapshot(
            reference: PullRequestReference(owner: owner, repository: repository, number: number), title: title,
            isViewerAuthor: false, state: "OPEN", hasDirectReviewRequest: reviewRequested,
            updatedAt: Date(timeIntervalSinceReferenceDate: 800_000_000 - Double(number) * 60))
    }

    /// A started store with GitHub on, in a new folder, answered by a client that holds `cards`.
    private func startStore(
        cards: [PullRequestSnapshot], _ configure: (inout AppState) -> Void = { _ in }
    ) async throws -> (AppStore, OwnerClient) {
        let folder = try makeDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        try await seed(folder, configure)
        let client = OwnerClient(cards: cards)
        let store = AppStore(
            stateURL: folder.appendingPathComponent("state.json"), githubClient: client, accessoryProviders: [])
        await store.start()
        addTeardownBlock { @MainActor in store.stop() }
        return (store, client)
    }

    /// A started profile with its board, GitHub on, answered by a client that holds `cards`.
    private func startProfile(
        cards: [PullRequestSnapshot], _ configure: (inout AppState) -> Void = { _ in }
    ) async throws -> (ProfileManager, ProfileSession, OwnerClient) {
        let folder = try makeDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        try await seed(folder, configure)
        let client = OwnerClient(cards: cards)
        let manager = ProfileManager(
            dataFolder: folder, isDemo: false, githubOverride: { _ in client }, accessoryProviders: [])
        manager.confirmClosingWithoutSaving = { entry in
            XCTFail("Unexpected question about closing \(entry.name) without saving")
            return false
        }
        manager.reportOpenElsewhere = { entry in XCTFail("Unexpected report that \(entry.name) is open elsewhere") }
        let started = await manager.start()
        XCTAssertTrue(started)
        addTeardownBlock { @MainActor in
            for session in manager.sessions.values { session.stop() }
        }
        return (manager, try XCTUnwrap(manager.activeSession), client)
    }

    private func seed(_ folder: URL, _ configure: (inout AppState) -> Void) async throws {
        var state = AppState()
        state.githubEnabled = true
        state.viewerLogin = "synthetic-viewer"
        configure(&state)
        try await StateRepository(url: folder.appendingPathComponent("state.json")).save(state)
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "StowOwnerViewTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Waits until SwiftUI has laid out the board, which always has the profile menu button.
    private func layOut(_ session: ProfileSession) async -> Bool {
        await waitUntil {
            session.board.contentView?.layoutSubtreeIfNeeded()
            return !self.subviews(of: ProfileSwitcherButton.self, in: session.board.contentView).isEmpty
        }
    }

    /// The board header's owner menu button, once SwiftUI has laid it out.
    private func ownerButton(
        in session: ProfileSession, file: StaticString = #filePath, line: UInt = #line
    ) async throws -> OwnerMenuButtonView {
        var found: OwnerMenuButtonView?
        _ = await waitUntil {
            session.board.contentView?.layoutSubtreeIfNeeded()
            found = self.subviews(of: OwnerMenuButtonView.self, in: session.board.contentView).first
            return found != nil
        }
        return try XCTUnwrap(found, "The board header has no owner menu button", file: file, line: line)
    }

    private func subviews<View: NSView>(of type: View.Type, in root: NSView?) -> [View] {
        guard let root else { return [] }
        return ((root as? View).map { [$0] } ?? []) + root.subviews.flatMap { subviews(of: type, in: $0) }
    }

    /// The menu's items as it opens, after the button's own face item; separators read "".
    private func menuTitles(_ button: NSPopUpButton) -> [String] {
        guard let menu = button.menu else { return [] }
        menu.delegate?.menuNeedsUpdate?(menu)
        return menu.items.dropFirst().map(\.title)
    }

    /// The marks of the menu's items as it opens, leaving out separators.
    private func menuStates(_ button: NSPopUpButton) -> [NSControl.StateValue] {
        guard let menu = button.menu else { return [] }
        menu.delegate?.menuNeedsUpdate?(menu)
        return menu.items.dropFirst().filter { !$0.isSeparatorItem }.map(\.state)
    }

    private func perform(
        _ title: String, in button: NSPopUpButton, file: StaticString = #filePath, line: UInt = #line
    ) {
        guard let menu = button.menu else { return XCTFail("The button has no menu", file: file, line: line) }
        menu.delegate?.menuNeedsUpdate?(menu)
        guard let index = menu.items.firstIndex(where: { $0.title == title }) else {
            return XCTFail("The menu has no item \(title)", file: file, line: line)
        }
        menu.performActionForItem(at: index)
    }

    private func waitUntil(_ predicate: @MainActor () async -> Bool) async -> Bool {
        for _ in 0..<100 {
            if await predicate() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await predicate()
    }
}

/// Answers each refresh with the cards it holds, as the login it is set to, and counts refreshes. Like `GHClient`,
/// it throws when it answers as a login other than the expected one.
private actor OwnerClient: GitHubClient {
    private var cards: [PullRequestSnapshot]
    private var login = "synthetic-viewer"
    private var isComplete = true
    private var warning: String?
    private(set) var refreshes = 0

    init(cards: [PullRequestSnapshot]) { self.cards = cards }

    func answer(with cards: [PullRequestSnapshot]) { self.cards = cards }
    func answer(as login: String) { self.login = login }

    func answer(isComplete: Bool, warning: String?) {
        self.isComplete = isComplete
        self.warning = warning
    }

    func refresh(pins: [PullRequestReference], previous: [PullRequestSnapshot], expectedViewerLogin: String?)
        async throws -> GitHubRefreshResult
    {
        refreshes += 1
        if let expectedViewerLogin, expectedViewerLogin.caseInsensitiveCompare(login) != .orderedSame {
            throw GitHubError.accountMismatch(actualLogin: login)
        }
        return .init(viewerLogin: login, snapshots: cards, isComplete: isComplete, warning: warning)
    }

    func details(for reference: PullRequestReference) async throws -> PullRequestDetails {
        throw GitHubError.requestFailed
    }
}
