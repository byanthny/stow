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
}
