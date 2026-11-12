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

    /// How the status reads at a glance, close to GitHub's colors.
    public var tone: AttentionTone {
        switch reason {
        case "Ready to merge": .success
        case "Checks failing", "Resolve conflicts", "Changes requested", "Closed": .failure
        case "Review requested", "Review required", "Waiting for review", "Checks pending", "Behind base branch":
            .pending
        default: .neutral  // Draft, Watching, Merged, Unavailable, Readiness unknown.
        }
    }
}

/// A status color: green success, red failure, amber pending, and muted for everything else.
public enum AttentionTone: String, Equatable, Sendable {
    case success, failure, pending, neutral
}

/// The checks line on a pull request card: what it says, and its tone when it has an icon.
public struct ChecksStatus: Equatable, Sendable {
    public var label: String
    /// Nil when there are no checks or they're unknown, so no icon shows.
    public var tone: AttentionTone?
}

extension PullRequestSnapshot {
    public var checksStatus: ChecksStatus {
        switch checksState {
        case "SUCCESS": ChecksStatus(label: "Checks passed", tone: .success)
        case "FAILURE", "ERROR": ChecksStatus(label: "Checks failing", tone: .failure)
        case "PENDING", "EXPECTED": ChecksStatus(label: "Checks running", tone: .pending)
        default: ChecksStatus(label: checksKnown && checksState == nil ? "No checks" : "Checks unknown", tone: nil)
        }
    }

    /// Merged or closed, as last observed.
    public var isTerminal: Bool { state == "MERGED" || state == "CLOSED" }

    /// Merged, as last observed. A merge can't be undone, so a stale card that was seen merged still is.
    public var isMerged: Bool { state == "MERGED" }

    /// Open and approved on fresh data. A stale or unavailable approval doesn't count.
    public var isApproved: Bool { state == "OPEN" && reviewDecision == "APPROVED" && !isStale && !isUnavailable }
}

/// What a card says about a pull request: its state on one line, and its checks, always, on the line below.
public struct CardStatus: Equatable, Sendable {
    /// The state that matters most, in its tone's color. Nil when only the checks have something to say.
    public var headline: String?
    public var tone: AttentionTone
    /// Further facts beside the headline, never repeating it.
    public var notes: [String]
    public var checks: ChecksStatus
}

extension PullRequestSnapshot {
    /// The card's two lines. Checks always sit on their own line, so a status about checks moves there and the
    /// state line shows the review instead.
    public func cardStatus(under classification: AttentionClassification) -> CardStatus {
        let reason = classification.reason
        let review: (text: String, tone: AttentionTone)? = reviewDecision.map { decision in
            switch decision {
            case "APPROVED": ("Approved", .success)
            case "CHANGES_REQUESTED": ("Changes requested", .failure)
            default: ("Review pending", .pending)
            }
        }
        var status = CardStatus(headline: nil, tone: .neutral, notes: [], checks: checksStatus)
        if reason == "Checks failing" || reason == "Checks pending" {
            status.headline = review?.text
            status.tone = review?.tone ?? .neutral
        } else {
            status.headline = reason
            status.tone = classification.tone
            let aboutReview = ["Changes requested", "Review required", "Review requested", "Waiting for review"]
            let repeats = review?.text == reason || (aboutReview.contains(reason) && review?.text == "Review pending")
            if let review, !repeats { status.notes.append(review.text) }
        }
        if mergeStateStatus == "BEHIND", reason != "Behind base branch" { status.notes.append("Behind base") }
        return status
    }
}

/// One check's tone from its GitHub state: skipped and neutral checks stay muted.
public func checkTone(_ state: String) -> AttentionTone {
    switch state {
    case "SUCCESS": .success
    case "FAILURE", "ERROR", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE": .failure
    case "PENDING", "EXPECTED", "QUEUED", "IN_PROGRESS", "WAITING", "REQUESTED": .pending
    default: .neutral
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
    // Being behind the base branch matters only once nothing else is pending.
    if snapshot.checksState == "PENDING" || snapshot.checksState == "EXPECTED" { return waiting("Checks pending") }
    if snapshot.reviewDecision == "REVIEW_REQUIRED" { return waiting("Review required") }
    if snapshot.mergeStateStatus == "BEHIND" { return waiting("Behind base branch") }
    return waiting("Readiness unknown")
}
