import Foundation
import XCTest

@testable import StowCore

final class OwnerTests: XCTestCase {
    private func ref(_ owner: String, _ repo: String = "repo", _ number: Int = 1) -> PullRequestReference {
        PullRequestReference(owner: owner, repository: repo, number: number)
    }

    private func card(_ owner: String, _ repo: String = "repo", _ number: Int = 1) -> PullRequestSnapshot {
        PullRequestSnapshot(reference: ref(owner, repo, number), title: "\(owner) \(number)")
    }

    func testSummariesCountUndismissedCardsAndKeepSelectedOwnersWithoutCards() {
        let cards = [card("acme", "a", 1), card("acme", "a", 2), card("beta", "b", 1)]
        let summaries = ownerSummaries(
            pullRequests: cards, pins: [], dismissedIDs: [cards[1].id],
            selection: OwnerSelection(["gone"]), order: .alphabetical)
        XCTAssertEqual(
            summaries,
            [
                OwnerSummary(owner: "acme", cardCount: 1, isSelected: false),
                OwnerSummary(owner: "beta", cardCount: 1, isSelected: false),
                OwnerSummary(owner: "gone", cardCount: 0, isSelected: true),
            ])
    }

    func testPinOwnersAreKnownWithZeroCards() {
        let summaries = ownerSummaries(
            pullRequests: [], pins: [ref("Pinned")], dismissedIDs: [], selection: OwnerSelection(),
            order: .alphabetical)
        XCTAssertEqual(summaries, [OwnerSummary(owner: "Pinned", cardCount: 0, isSelected: false)])
    }

    func testOwnerMatchingIgnoresCase() {
        let acme = card("Acme")
        let selection = OwnerSelection(["acme"])
        XCTAssertTrue(isShown(acme, selection: selection, pins: []))
        XCTAssertFalse(isShown(card("Other"), selection: selection, pins: []))
        let summaries = ownerSummaries(
            pullRequests: [acme, card("ACME", "x", 2)], pins: [ref("acme")], dismissedIDs: [],
            selection: selection, order: .alphabetical)
        XCTAssertEqual(summaries, [OwnerSummary(owner: "Acme", cardCount: 2, isSelected: true)])
    }

    func testPinsAlwaysShow() {
        let other = card("other")
        let selection = OwnerSelection(["acme"])
        XCTAssertFalse(isShown(other, selection: selection, pins: []))
        XCTAssertTrue(isShown(other, selection: selection, pins: [ref("OTHER")]))
        XCTAssertTrue(isShown(other, selection: OwnerSelection(), pins: []))
    }

    func testGroupingKeepsCardOrderAndSortsOwners() {
        let cards = [
            card("zed", "r", 1), card("Amy", "r", 2), card("zed", "r", 3), card("bob", "r", 4),
            card("AMY", "r", 5), card("bob", "r", 6), card("zed", "r", 7),
        ]
        let alphabetical = groupedByOwner(cards, order: .alphabetical)
        XCTAssertEqual(alphabetical.map(\.owner), ["Amy", "bob", "zed"])
        XCTAssertEqual(alphabetical[0].cards.map(\.reference.number), [2, 5])
        XCTAssertEqual(alphabetical[2].cards.map(\.reference.number), [1, 3, 7])
        let most = groupedByOwner(cards, order: .mostCards)
        XCTAssertEqual(most.map(\.owner), ["zed", "Amy", "bob"])
    }

    func testRetainingKeepsPinsAndSelectedOwners() {
        let cards = [card("acme", "r", 1), card("beta", "r", 2), card("gamma", "r", 3)]
        let kept = retainingSelectedOwners(cards, selection: OwnerSelection(["ACME"]), pins: [ref("gamma", "r", 3)])
        XCTAssertEqual(kept.map(\.reference.number), [1, 3])
        XCTAssertEqual(retainingSelectedOwners(cards, selection: OwnerSelection(), pins: []), cards)
    }

    func testSavedOlderLoginKeepsOnlyItsCards() throws {
        // An older login can end in a hyphen. Loading it must not widen the selection to every owner, or a profile
        // that keeps only selected owners on disk would save everyone's cards.
        let selection = try JSONDecoder().decode(OwnerSelection.self, from: Data(#"{"owners":["old-login-"]}"#.utf8))
        XCTAssertEqual(selection.owners, ["old-login-"])
        XCTAssertEqual(try JSONDecoder().decode(OwnerSelection.self, from: JSONEncoder().encode(selection)), selection)
        let cards = [card("old-login-", "r", 1), card("acme", "r", 2)]
        XCTAssertEqual(retainingSelectedOwners(cards, selection: selection, pins: []).map(\.reference.number), [1])
    }

    func testOwnerControlVisibility() {
        let one = [card("acme", "r", 1), card("Acme", "r", 2)]
        let two = one + [card("beta")]
        let all = OwnerSelection()
        XCTAssertFalse(showsOwnerControl(githubEnabled: true, pullRequests: one, selection: all, alwaysShow: false))
        XCTAssertTrue(showsOwnerControl(githubEnabled: true, pullRequests: two, selection: all, alwaysShow: false))
        XCTAssertTrue(
            showsOwnerControl(githubEnabled: true, pullRequests: one, selection: OwnerSelection(["x"]), alwaysShow: false))
        XCTAssertFalse(showsOwnerControl(githubEnabled: false, pullRequests: two, selection: all, alwaysShow: true))
        XCTAssertFalse(
            showsOwnerControl(githubEnabled: false, pullRequests: two, selection: OwnerSelection(["x"]), alwaysShow: false))
        XCTAssertTrue(showsOwnerControl(githubEnabled: true, pullRequests: [], selection: all, alwaysShow: true))
    }

    func testLinkedNotesHideOnlyWhenEnabled() {
        let selection = OwnerSelection(["acme"])
        let linkedOut = Note(markdown: "x", pullRequest: ref("other"))
        let linkedIn = Note(markdown: "x", pullRequest: ref("ACME"))
        let standalone = Note(markdown: "x")
        XCTAssertTrue(isNoteShown(linkedOut, selection: selection, hidesLinkedNotes: false))
        XCTAssertFalse(isNoteShown(linkedOut, selection: selection, hidesLinkedNotes: true))
        XCTAssertTrue(isNoteShown(linkedIn, selection: selection, hidesLinkedNotes: true))
        XCTAssertTrue(isNoteShown(standalone, selection: selection, hidesLinkedNotes: true))
        XCTAssertTrue(isNoteShown(linkedOut, selection: OwnerSelection(), hidesLinkedNotes: true))
    }
}
