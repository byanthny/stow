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

    func testPinnedCardsAlwaysShowAndTheLimitCountsOnlyUnpinnedCards() {
        let cards = (1...6).map { card($0, updated: Double($0)) }
        var layout = BoardLayout()
        layout.visiblePullRequests = 3
        // A pinned card after the limit still shows, and Show more counts only the hidden unpinned cards.
        let pinnedLast = layout.visibleCards(cards, pins: [cards[5].reference], expanded: false)
        XCTAssertEqual(pinnedLast.shown.map(\.reference.number), [1, 2, 3, 6])
        XCTAssertEqual(pinnedLast.hidden, 2)
        let expanded = layout.visibleCards(cards, pins: [cards[5].reference], expanded: true)
        XCTAssertEqual(expanded.shown.count, 6)
        XCTAssertEqual(expanded.hidden, 0)
        layout.visiblePullRequests = 0
        XCTAssertEqual(layout.visibleCards(cards, pins: [], expanded: false).hidden, 0, "0 shows every card")
    }
}
