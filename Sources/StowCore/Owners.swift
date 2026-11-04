import Foundation

// Owner rules. These only decide what is visible; they never touch classification, refresh, dismissals, or pins.
// Owners compare ignoring case and display as GitHub spells them on the cards.

public struct OwnerSummary: Equatable, Sendable {
    public var owner: String
    public var cardCount: Int
    public var isSelected: Bool

    public init(owner: String, cardCount: Int, isSelected: Bool) {
        self.owner = owner
        self.cardCount = cardCount
        self.isSelected = isSelected
    }
}

private func ownerKey(_ owner: String) -> String { owner.lowercased() }

private func ownerPrecedes(_ lhs: String, _ rhs: String) -> Bool {
    let result = lhs.localizedCaseInsensitiveCompare(rhs)
    return result == .orderedSame ? lhs < rhs : result == .orderedAscending
}

private func isPinned(_ reference: PullRequestReference, in pins: [PullRequestReference]) -> Bool {
    pins.contains { $0.id == reference.id }
}

/// Known owners come from cached cards, pins, and the selection. Counts cover cards that are not dismissed.
public func ownerSummaries(
    pullRequests: [PullRequestSnapshot], pins: [PullRequestReference], dismissedIDs: [String],
    selection: OwnerSelection, order: BoardLayout.OwnerOrder
) -> [OwnerSummary] {
    let dismissed = Set(dismissedIDs)
    var spelling: [String: String] = [:]
    var counts: [String: Int] = [:]
    // Card spelling wins, then pins, then the stored selection.
    for card in pullRequests {
        let key = ownerKey(card.reference.owner)
        if spelling[key] == nil { spelling[key] = card.reference.owner }
        if !dismissed.contains(card.id) { counts[key, default: 0] += 1 }
    }
    for owner in pins.map(\.owner) + selection.owners where spelling[ownerKey(owner)] == nil {
        spelling[ownerKey(owner)] = owner
    }
    let summaries = spelling.map { key, owner in
        OwnerSummary(owner: owner, cardCount: counts[key] ?? 0, isSelected: selection.contains(owner))
    }
    return summaries.sorted { lhs, rhs in
        if order == .mostCards, lhs.cardCount != rhs.cardCount { return lhs.cardCount > rhs.cardCount }
        return ownerPrecedes(lhs.owner, rhs.owner)
    }
}

/// A card shows when no owner is selected, its owner is selected, or it is pinned.
public func isShown(_ snapshot: PullRequestSnapshot, selection: OwnerSelection, pins: [PullRequestReference]) -> Bool {
    selection.isAll || selection.contains(snapshot.reference.owner) || isPinned(snapshot.reference, in: pins)
}

/// Groups keep the cards' order within each owner and use the first card's spelling of the owner.
public func groupedByOwner(
    _ cards: [PullRequestSnapshot], order: BoardLayout.OwnerOrder
) -> [(owner: String, cards: [PullRequestSnapshot])] {
    var groups: [(owner: String, cards: [PullRequestSnapshot])] = []
    var indexes: [String: Int] = [:]
    for card in cards {
        let key = ownerKey(card.reference.owner)
        if let index = indexes[key] {
            groups[index].cards.append(card)
        } else {
            indexes[key] = groups.count
            groups.append((card.reference.owner, [card]))
        }
    }
    return groups.sorted { lhs, rhs in
        if order == .mostCards, lhs.cards.count != rhs.cards.count { return lhs.cards.count > rhs.cards.count }
        return ownerPrecedes(lhs.owner, rhs.owner)
    }
}

/// What a profile that keeps only its selected owners on disk retains: those owners' cards, plus pins.
public func retainingSelectedOwners(
    _ snapshots: [PullRequestSnapshot], selection: OwnerSelection, pins: [PullRequestReference]
) -> [PullRequestSnapshot] {
    snapshots.filter { isShown($0, selection: selection, pins: pins) }
}

/// The control shows whenever a filter is active, so a selection never hides cards silently.
public func showsOwnerControl(
    githubEnabled: Bool, pullRequests: [PullRequestSnapshot], selection: OwnerSelection, alwaysShow: Bool
) -> Bool {
    guard githubEnabled else { return false }
    if alwaysShow || !selection.isAll { return true }
    return Set(pullRequests.map { ownerKey($0.reference.owner) }).count > 1
}

/// Standalone notes always show. Linked notes hide only when the setting is on and their owner is not selected.
public func isNoteShown(_ note: Note, selection: OwnerSelection, hidesLinkedNotes: Bool) -> Bool {
    guard hidesLinkedNotes, let reference = note.pullRequest else { return true }
    return selection.isAll || selection.contains(reference.owner)
}
