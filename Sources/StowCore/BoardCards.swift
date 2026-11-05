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
