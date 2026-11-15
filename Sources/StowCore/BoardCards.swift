import Foundation

/// A section's cards in board order: pinned cards first, then the rest, each part most recently updated first.
public func pinnedFirst(_ cards: [PullRequestSnapshot], pins: [PullRequestReference]) -> [PullRequestSnapshot] {
    let pinned = Set(pins.map(\.id))
    let newestFirst = cards.sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
    return newestFirst.filter { pinned.contains($0.reference.id) }
        + newestFirst.filter { !pinned.contains($0.reference.id) }
}

extension BoardLayout {
    /// The cards that show before Show more, in the order given. Pinned cards count toward the section's limit but
    /// always show, and unpinned cards fill the room left. `hidden` counts the cards after Show more.
    public func visibleCards(
        _ cards: [PullRequestSnapshot], pins: [PullRequestReference], expanded: Bool
    ) -> (shown: [PullRequestSnapshot], hidden: Int) {
        let pinned = Set(pins.map(\.id))
        let pinnedCount = cards.filter { pinned.contains($0.reference.id) }.count
        var room = max(0, shownPullRequests(of: cards.count, expanded: expanded) - pinnedCount)
        let shown = cards.filter { card in
            if pinned.contains(card.reference.id) { return true }
            guard room > 0 else { return false }
            room -= 1
            return true
        }
        return (shown, cards.count - shown.count)
    }
}

/// A pull-request section's cards as the board lists them: under owner subheadings when Settings → Board groups by
/// owner, and only as many as show before Show more, which still counts cards per section.
public struct SectionCards: Sendable {
    public struct Group: Identifiable, Sendable {
        /// The subheading, or nil while the board does not group by owner.
        public let owner: String?
        /// The owner's cards in the section, counting those after Show more.
        public let count: Int
        /// The cards that show, in the section's order.
        public let cards: [PullRequestSnapshot]
        public var id: String { owner?.lowercased() ?? "" }
    }

    /// Groups with at least one card showing; an owner whose cards all come after Show more waits for it.
    public let groups: [Group]
    /// The cards after Show more.
    public let moreCount: Int

    /// Pinned cards always show and count toward the section's limit.
    public init(_ cards: [PullRequestSnapshot], layout: BoardLayout, pins: [PullRequestReference], expanded: Bool) {
        let owners: [(owner: String?, cards: [PullRequestSnapshot])] =
            layout.groupByOwner
            ? groupedByOwner(cards, order: layout.ownerOrder).map { ($0.owner, $0.cards) } : [(nil, cards)]
        let visible = layout.visibleCards(owners.flatMap { $0.cards }, pins: pins, expanded: expanded)
        let shownIDs = Set(visible.shown.map(\.id))
        moreCount = visible.hidden
        groups = owners.compactMap { owner, ownerCards in
            let shown = ownerCards.filter { shownIDs.contains($0.id) }
            return shown.isEmpty ? nil : Group(owner: owner, count: ownerCards.count, cards: shown)
        }
    }
}
