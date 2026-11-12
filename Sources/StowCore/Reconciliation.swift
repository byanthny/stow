import Foundation

/// How long an unpinned merged or closed card stays on the board, counted from when Stow first saw it so.
public enum TerminalCardKeepTime: String, Codable, CaseIterable, Sendable {
    case dontKeep, hour, day, week

    public static let `default` = TerminalCardKeepTime.day

    public var interval: TimeInterval {
        switch self {
        case .dontKeep: 0
        case .hour: 60 * 60
        case .day: 24 * 60 * 60
        case .week: 7 * 24 * 60 * 60
        }
    }
}

/// The cards that stay: pinned cards and open ones always, and merged or closed ones until their keep time ends.
public func droppingExpiredTerminalCards(
    _ cards: [PullRequestSnapshot], pins: [PullRequestReference], keepTime: TerminalCardKeepTime, now: Date
) -> [PullRequestSnapshot] {
    let pinnedIDs = Set(pins.map(\.id))
    return cards.filter { card in
        guard card.isTerminal, !pinnedIDs.contains(card.id), let first = card.terminalObservedAt else { return true }
        return now.timeIntervalSince(first) < keepTime.interval
    }
}

/// Missing results are stale observations, not proof that a pull request has vanished.
public func reconcileSnapshots(
    previous: [PullRequestSnapshot], incoming: [PullRequestSnapshot],
    pins: [PullRequestReference], now: Date, keepTime: TerminalCardKeepTime = .default
) -> [PullRequestSnapshot] {
    let pinnedIDs = Set(pins.map(\.id))
    var previousByID: [String: PullRequestSnapshot] = [:]
    for snapshot in previous { previousByID[snapshot.id] = snapshot }
    var incomingByID: [String: PullRequestSnapshot] = [:]
    var order: [String] = []
    for snapshot in incoming {
        if incomingByID[snapshot.id] == nil { order.append(snapshot.id) }
        incomingByID[snapshot.id] = snapshot
    }
    for snapshot in previous where incomingByID[snapshot.id] == nil && !order.contains(snapshot.id) {
        order.append(snapshot.id)
    }
    let cards = order.compactMap { id -> PullRequestSnapshot? in
        let old = previousByID[id]
        var result: PullRequestSnapshot
        if let fresh = incomingByID[id] {
            if fresh.isUnavailable, var preserved = old {
                preserved.isUnavailable = true
                preserved.isStale = true
                preserved.fetchedAt = fresh.fetchedAt
                result = preserved
            } else {
                result = fresh
                // Detailed data is lazily fetched; absence in a list response does not erase it.
                if result.details == nil { result.details = old?.details }
            }
        } else if var preserved = old {
            preserved.isStale = true
            result = preserved
        } else {
            return nil
        }
        // A provider timestamp cannot establish when this app first observed a terminal state.
        result.terminalObservedAt = result.isTerminal ? old?.terminalObservedAt ?? now : nil
        let currentClassification = classify(result, isPinned: pinnedIDs.contains(id))
        if let old, classify(old, isPinned: pinnedIDs.contains(id)) == currentClassification {
            result.observedStateSince = old.observedStateSince
        } else {
            result.observedStateSince = now
        }
        return result
    }
    return droppingExpiredTerminalCards(cards, pins: pins, keepTime: keepTime, now: now)
}
