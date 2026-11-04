import Foundation

/// A section's cards in board order: pinned cards first, then the rest, each part most recently updated first.
public func pinnedFirst(_ cards: [PullRequestSnapshot], pins: [PullRequestReference]) -> [PullRequestSnapshot] {
    let pinned = Set(pins.map(\.id))
    let newestFirst = cards.sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
    return newestFirst.filter { pinned.contains($0.reference.id) }
        + newestFirst.filter { !pinned.contains($0.reference.id) }
}

extension BoardLayout {
    /// The cards that show before Show more, in the order given: every pinned card, plus unpinned cards up to the
    /// section's limit. `hidden` counts the unpinned cards after Show more.
    public func visibleCards(
        _ cards: [PullRequestSnapshot], pins: [PullRequestReference], expanded: Bool
    ) -> (shown: [PullRequestSnapshot], hidden: Int) {
        let pinned = Set(pins.map(\.id))
        let unpinned = cards.filter { !pinned.contains($0.reference.id) }.count
        let limit = shownPullRequests(of: unpinned, expanded: expanded)
        var unpinnedShown = 0
        let shown = cards.filter { card in
            if pinned.contains(card.reference.id) { return true }
            guard unpinnedShown < limit else { return false }
            unpinnedShown += 1
            return true
        }
        return (shown, cards.count - shown.count)
    }
}
