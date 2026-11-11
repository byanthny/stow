import Foundation

/// Missing results are stale observations, not proof that a pull request has vanished.
public func reconcileSnapshots(
    previous: [PullRequestSnapshot], incoming: [PullRequestSnapshot],
    pins: [PullRequestReference], now: Date
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
    return order.compactMap { id in
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
        if result.state == "CLOSED" || result.state == "MERGED" {
            // An unpinned card that an earlier refresh already showed merged or closed leaves now.
            if let first = old?.terminalObservedAt, first != now, !pinnedIDs.contains(id) { return nil }
            // A provider timestamp cannot establish when this app first observed a terminal state.
            result.terminalObservedAt = old?.terminalObservedAt ?? now
        } else {
            result.terminalObservedAt = nil
        }
        let currentClassification = classify(result, isPinned: pinnedIDs.contains(id))
        if let old, classify(old, isPinned: pinnedIDs.contains(id)) == currentClassification {
            result.observedStateSince = old.observedStateSince
        } else {
            result.observedStateSince = now
        }
        return result
    }
}
