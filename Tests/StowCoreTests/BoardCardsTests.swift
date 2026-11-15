import Foundation
import XCTest

@testable import StowCore

final class BoardCardsTests: XCTestCase {
    private func card(_ number: Int, updated minutesAgo: Double) -> PullRequestSnapshot {
        var snapshot = PullRequestSnapshot(
            reference: .init(owner: "example", repository: "desktop", number: number), title: "Synthetic \(number)")
        snapshot.updatedAt = Date(timeIntervalSince1970: 1_800_000_000 - minutesAgo * 60)
        return snapshot
    }

    func testPinnedCardsComeFirstAndEachPartKeepsNewestFirst() {
        let cards = [card(1, updated: 5), card(2, updated: 50), card(3, updated: 1), card(4, updated: 90)]
        let pins = [cards[3].reference, cards[1].reference]
        XCTAssertEqual(pinnedFirst(cards, pins: pins).map(\.reference.number), [2, 4, 3, 1])
        XCTAssertEqual(pinnedFirst(cards, pins: []).map(\.reference.number), [3, 1, 2, 4])
    }

    func testPinnedCardsCountTowardTheLimitButAlwaysShow() {
        let cards = (1...6).map { card($0, updated: Double($0)) }
        var layout = BoardLayout()
        layout.visiblePullRequests = 3
        // One pin leaves room for two more cards before Show more.
        let onePin = layout.visibleCards(cards, pins: [cards[5].reference], expanded: false)
        XCTAssertEqual(onePin.shown.map(\.reference.number), [1, 2, 6])
        XCTAssertEqual(onePin.hidden, 3)
        // More pins than the limit all show, and nothing else does until Show more.
        let manyPins = layout.visibleCards(cards, pins: cards[2...].map(\.reference), expanded: false)
        XCTAssertEqual(manyPins.shown.map(\.reference.number), [3, 4, 5, 6])
        XCTAssertEqual(manyPins.hidden, 2)
        let expanded = layout.visibleCards(cards, pins: [cards[5].reference], expanded: true)
        XCTAssertEqual(expanded.shown.count, 6)
        XCTAssertEqual(expanded.hidden, 0)
        layout.visiblePullRequests = 0
        XCTAssertEqual(layout.visibleCards(cards, pins: [], expanded: false).hidden, 0, "0 shows every card")
    }

    private func ownedCard(_ owner: String, _ number: Int) -> PullRequestSnapshot {
        PullRequestSnapshot(
            reference: .init(owner: owner, repository: "kit", number: number), title: "Synthetic card \(number)",
            updatedAt: Date(timeIntervalSinceReferenceDate: 800_000_000 - Double(number) * 60))
    }

    func testGroupingAddsOwnerSubheadingsAndShowMoreCountsPerSection() {
        // Waiting cards, newest first: beta, acme, beta, acme, beta.
        let waiting = pinnedFirst(
            [
                ownedCard("beta", 1), ownedCard("acme", 2), ownedCard("beta", 3), ownedCard("acme", 4),
                ownedCard("beta", 5),
            ], pins: [])
        XCTAssertEqual(waiting.map(\.reference.number), [1, 2, 3, 4, 5])
        func numbers(_ listed: SectionCards) -> [[Int]] { listed.groups.map { $0.cards.map(\.reference.number) } }
        var layout = BoardLayout()

        // Off by default: one list, three cards, and Show 2 more, as before.
        var listed = SectionCards(waiting, layout: layout, pins: [], expanded: false)
        XCTAssertEqual(listed.groups.map(\.owner), [nil])
        XCTAssertEqual(numbers(listed), [[1, 2, 3]])
        XCTAssertEqual(listed.moreCount, 2)

        layout.groupByOwner = true
        listed = SectionCards(waiting, layout: layout, pins: [], expanded: false)
        XCTAssertEqual(listed.groups.map(\.owner), ["acme", "beta"])
        XCTAssertEqual(listed.groups.map(\.count), [2, 3], "Each subheading counts its owner's cards in the section")
        XCTAssertEqual(numbers(listed), [[2, 4], [1]], "Cards keep their order within each owner")
        XCTAssertEqual(listed.moreCount, 2, "Show more still counts cards per section")
        listed = SectionCards(waiting, layout: layout, pins: [], expanded: true)
        XCTAssertEqual(numbers(listed), [[2, 4], [1, 3, 5]])
        XCTAssertEqual(listed.moreCount, 0)

        layout.ownerOrder = .mostCards
        listed = SectionCards(waiting, layout: layout, pins: [], expanded: false)
        XCTAssertEqual(
            listed.groups.map(\.owner), ["beta"], "An owner whose cards are all after Show more waits for it")
        XCTAssertEqual(numbers(listed), [[1, 3, 5]])
        XCTAssertEqual(listed.moreCount, 2)
    }

    func testPinnedCardsStayAboveShowMoreInSectionCards() {
        let cards = (1...5).map { ownedCard("acme", $0) }
        let pins = [cards[4].reference]
        let waiting = pinnedFirst(cards, pins: pins)
        XCTAssertEqual(waiting.map(\.reference.number), [5, 1, 2, 3, 4], "A pinned card moves to the top")
        let listed = SectionCards(waiting, layout: BoardLayout(), pins: pins, expanded: false)
        // The pin counts toward the three cards before Show more.
        XCTAssertEqual(listed.groups.flatMap { $0.cards.map(\.reference.number) }, [5, 1, 2])
        XCTAssertEqual(listed.moreCount, 2)
    }
}
