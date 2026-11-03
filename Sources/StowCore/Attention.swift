import Foundation

public enum AttentionSection: String, Codable, Equatable, Sendable {
    case needsYou
    case waiting
}

public struct AttentionClassification: Equatable, Sendable {
    public var section: AttentionSection
    public var reason: String
    public init(section: AttentionSection, reason: String) {
        self.section = section
        self.reason = reason
    }
}

/// Classifies only observed facts. Unknown or incomplete readiness never means ready.
public func classify(_ snapshot: PullRequestSnapshot, isPinned: Bool = false) -> AttentionClassification {
    func waiting(_ reason: String) -> AttentionClassification { .init(section: .waiting, reason: reason) }
    func needs(_ reason: String) -> AttentionClassification { .init(section: .needsYou, reason: reason) }
    if snapshot.state == "CLOSED" { return waiting("Closed") }
    if snapshot.state == "MERGED" { return waiting("Merged") }
    if snapshot.isViewerAuthor == true, snapshot.isDraft == true { return waiting("Draft") }
    if snapshot.isUnavailable { return waiting("Unavailable") }
    guard snapshot.state == "OPEN" else { return waiting("Readiness unknown") }
    guard snapshot.isViewerAuthor == true else {
        if snapshot.hasDirectReviewRequest == true { return needs("Review requested") }
        return waiting(isPinned ? "Watching" : "Waiting for review")
    }
    if snapshot.mergeable == "CONFLICTING" || snapshot.mergeStateStatus == "DIRTY" {
        return needs("Resolve conflicts")
    }
    if snapshot.reviewDecision == "CHANGES_REQUESTED" { return needs("Changes requested") }
    if snapshot.checksState == "FAILURE" || snapshot.checksState == "ERROR" { return needs("Checks failing") }
    if !snapshot.isStale, !snapshot.isUnavailable, snapshot.isDraft == false, snapshot.readinessIsComplete,
        snapshot.mergeable == "MERGEABLE", snapshot.mergeStateStatus == "CLEAN",
        snapshot.checksKnown, snapshot.checksState == nil || snapshot.checksState == "SUCCESS",
        snapshot.reviewDecision == nil || snapshot.reviewDecision == "APPROVED"
    {
        return needs("Ready to merge")
    }
    if snapshot.mergeStateStatus == "BEHIND" { return waiting("Behind base branch") }
    if snapshot.checksState == "PENDING" || snapshot.checksState == "EXPECTED" { return waiting("Checks pending") }
    if snapshot.reviewDecision == "REVIEW_REQUIRED" { return waiting("Review required") }
    return waiting("Readiness unknown")
}
