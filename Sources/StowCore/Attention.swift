import Foundation

public enum AttentionSection: String, Codable, Equatable, Sendable {
    case needsYou
    case waiting
}

/// Why a card sits where it does, in the words the card shows.
public enum AttentionReason: String, CaseIterable, Sendable {
    case readyToMerge = "Ready to merge"
    case checksFailing = "Checks failing"
    case resolveConflicts = "Resolve conflicts"
    case changesRequested = "Changes requested"
    case closed = "Closed"
    case reviewRequested = "Review requested"
    case reviewRequired = "Review required"
    case waitingForReview = "Waiting for review"
    case checksPending = "Checks pending"
    case behindBaseBranch = "Behind base branch"
    case draft = "Draft"
    case watching = "Watching"
    case merged = "Merged"
    case unavailable = "Unavailable"
    case readinessUnknown = "Readiness unknown"

    /// How the status reads at a glance, close to GitHub's colors.
    public var tone: AttentionTone {
        switch self {
        case .readyToMerge: .success
        case .checksFailing, .resolveConflicts, .changesRequested, .closed: .failure
        case .reviewRequested, .reviewRequired, .waitingForReview, .checksPending, .behindBaseBranch: .pending
        case .draft, .watching, .merged, .unavailable, .readinessUnknown: .neutral
        }
    }

    /// A status about the checks, which a card shows on its checks line.
    public var isAboutChecks: Bool { self == .checksFailing || self == .checksPending }

    /// A status about review, which a pending review only repeats.
    public var isAboutReview: Bool {
        switch self {
        case .changesRequested, .reviewRequired, .reviewRequested, .waitingForReview: true
        default: false
        }
    }
}

public struct AttentionClassification: Equatable, Sendable {
    public var section: AttentionSection
    public var reason: AttentionReason
    public init(section: AttentionSection, reason: AttentionReason) {
        self.section = section
        self.reason = reason
    }

    /// How the status reads at a glance, close to GitHub's colors.
    public var tone: AttentionTone { reason.tone }
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
        if reason.isAboutChecks {
            status.headline = review?.text
            status.tone = review?.tone ?? .neutral
        } else {
            status.headline = reason.rawValue
            status.tone = classification.tone
            let repeats = review?.text == reason.rawValue || (reason.isAboutReview && review?.text == "Review pending")
            if let review, !repeats { status.notes.append(review.text) }
        }
        if mergeStateStatus == "BEHIND", reason != .behindBaseBranch { status.notes.append("Behind base") }
        return status
    }
}

/// One check's outcome from its GitHub state. Skipped and neutral checks are muted, not passed.
public enum CheckOutcome: Equatable, Sendable {
    case success, failure, pending, neutral, unknown

    public init(githubState state: String) {
        switch state {
        case "SUCCESS": self = .success
        case "FAILURE", "ERROR", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE": self = .failure
        case "PENDING", "EXPECTED", "QUEUED", "IN_PROGRESS", "WAITING", "REQUESTED": self = .pending
        case "NEUTRAL", "SKIPPED": self = .neutral
        default: self = .unknown
        }
    }

    public var tone: AttentionTone {
        switch self {
        case .success: .success
        case .failure: .failure
        case .pending: .pending
        case .neutral, .unknown: .neutral
        }
    }

    /// The SF Symbol name shown beside the check.
    public var symbol: String {
        switch self {
        case .success: "checkmark.circle"
        case .failure: "xmark.circle"
        case .pending: "clock"
        case .neutral: "minus.circle"
        case .unknown: "questionmark.circle"
        }
    }

    public var isPassing: Bool { self == .success }

    /// Failing, running, or unknown checks, which are kept first when a long list is cut.
    public var mayNeedAttention: Bool { self == .failure || self == .pending || self == .unknown }
}

extension CheckSummary {
    public var outcome: CheckOutcome { CheckOutcome(githubState: state) }
}

/// Classifies only observed facts. Unknown or incomplete readiness never means ready.
public func classify(_ snapshot: PullRequestSnapshot, isPinned: Bool = false) -> AttentionClassification {
    func waiting(_ reason: AttentionReason) -> AttentionClassification { .init(section: .waiting, reason: reason) }
    func needs(_ reason: AttentionReason) -> AttentionClassification { .init(section: .needsYou, reason: reason) }
    if snapshot.state == "CLOSED" { return waiting(.closed) }
    if snapshot.state == "MERGED" { return waiting(.merged) }
    if snapshot.isViewerAuthor == true, snapshot.isDraft == true { return waiting(.draft) }
    if snapshot.isUnavailable { return waiting(.unavailable) }
    guard snapshot.state == "OPEN" else { return waiting(.readinessUnknown) }
    guard snapshot.isViewerAuthor == true else {
        if snapshot.hasDirectReviewRequest == true { return needs(.reviewRequested) }
        return waiting(isPinned ? .watching : .waitingForReview)
    }
    if snapshot.mergeable == "CONFLICTING" || snapshot.mergeStateStatus == "DIRTY" {
        return needs(.resolveConflicts)
    }
    if snapshot.reviewDecision == "CHANGES_REQUESTED" { return needs(.changesRequested) }
    if snapshot.checksState == "FAILURE" || snapshot.checksState == "ERROR" { return needs(.checksFailing) }
    if !snapshot.isStale, !snapshot.isUnavailable, snapshot.isDraft == false, snapshot.readinessIsComplete,
        snapshot.mergeable == "MERGEABLE", snapshot.mergeStateStatus == "CLEAN",
        snapshot.checksKnown, snapshot.checksState == nil || snapshot.checksState == "SUCCESS",
        snapshot.reviewDecision == nil || snapshot.reviewDecision == "APPROVED"
    {
        return needs(.readyToMerge)
    }
    // Being behind the base branch matters only once nothing else is pending.
    if snapshot.checksState == "PENDING" || snapshot.checksState == "EXPECTED" { return waiting(.checksPending) }
    if snapshot.reviewDecision == "REVIEW_REQUIRED" { return waiting(.reviewRequired) }
    if snapshot.mergeStateStatus == "BEHIND" { return waiting(.behindBaseBranch) }
    return waiting(.readinessUnknown)
}
