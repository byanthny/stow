import Foundation
import StowCore

/// Synthetic content is only used by the explicit debug verification launch argument.
enum DemoContent {
    static func state() -> AppState {
        var state = AppState()
        let first = PullRequestReference(owner: "example", repository: "desktop", number: 24)
        let second = PullRequestReference(owner: "example", repository: "desktop", number: 27)
        let third = PullRequestReference(owner: "example", repository: "toolkit", number: 8)
        // Enough cards for Show more in Needs you and Waiting.
        state.pullRequests = [
            .init(
                reference: first, title: "Preserve window placement", authorLogin: "developer", isViewerAuthor: true,
                isDraft: false, mergeable: "MERGEABLE", mergeStateStatus: "BLOCKED",
                reviewDecision: "CHANGES_REQUESTED",
                checksState: "SUCCESS", checksKnown: true, readinessIsComplete: true,
                createdAt: .now.addingTimeInterval(-172800),
                updatedAt: .now.addingTimeInterval(-3600),
                details: .init(
                    reviews: [.init(author: "reviewer", state: "CHANGES_REQUESTED")],
                    unresolvedThreadCount: 2,
                    latestComment: "Could we restore the note to the nearest available display?",
                    latestCommentAuthor: "reviewer")),
            .init(
                reference: second, title: "Handle refresh retries", authorLogin: "developer", isViewerAuthor: true,
                isDraft: false, mergeable: "MERGEABLE", mergeStateStatus: "UNSTABLE", reviewDecision: "APPROVED",
                checksState: "FAILURE",
                checksKnown: true, readinessIsComplete: true, createdAt: .now.addingTimeInterval(-86400),
                updatedAt: .now.addingTimeInterval(-1200),
                details: .init(
                    checks: [
                        .init(
                            name: "macOS integration tests", state: "FAILURE",
                            url: URL(string: "https://github.com/example/desktop/actions"))
                    ],
                    reviews: [.init(author: "reviewer", state: "APPROVED")], unresolvedThreadCount: 1,
                    commits: [
                        .init(headline: "Retry refreshes with backoff", committedAt: .now.addingTimeInterval(-1300)),
                        .init(headline: "Show the retry count", committedAt: .now.addingTimeInterval(-5200)),
                        .init(headline: "Add refresh retry tests", committedAt: .now.addingTimeInterval(-9100)),
                    ])),
            .init(
                reference: third, title: "Add keyboard shortcuts", authorLogin: "developer", isViewerAuthor: true,
                isDraft: false, mergeable: "MERGEABLE", mergeStateStatus: "BLOCKED", reviewDecision: "REVIEW_REQUIRED",
                checksState: "SUCCESS", checksKnown: true, readinessIsComplete: true,
                updatedAt: .now.addingTimeInterval(-7200)),
            .init(
                reference: PullRequestReference(owner: "example", repository: "site", number: 12),
                title: "Refresh the landing page copy", authorLogin: "developer", isViewerAuthor: true,
                isDraft: false, mergeable: "MERGEABLE", mergeStateStatus: "CLEAN", reviewDecision: "APPROVED",
                checksState: "SUCCESS", checksKnown: true, readinessIsComplete: true,
                updatedAt: .now.addingTimeInterval(-5400)),
            .init(
                reference: PullRequestReference(owner: "example", repository: "toolkit", number: 15),
                title: "Fix menu shortcuts on Intel", authorLogin: "developer", isViewerAuthor: true,
                isDraft: false, mergeable: "CONFLICTING", mergeStateStatus: "DIRTY", reviewDecision: "APPROVED",
                checksState: "SUCCESS", checksKnown: true, readinessIsComplete: true,
                updatedAt: .now.addingTimeInterval(-9000)),
            .init(
                reference: PullRequestReference(owner: "example", repository: "site", number: 9),
                title: "Tidy the footer links", authorLogin: "teammate", isViewerAuthor: false,
                isDraft: false, mergeable: "MERGEABLE", mergeStateStatus: "BLOCKED", reviewDecision: "REVIEW_REQUIRED",
                checksState: "PENDING", checksKnown: true, hasDirectReviewRequest: true, readinessIsComplete: true,
                updatedAt: .now.addingTimeInterval(-600)),
            .init(
                reference: PullRequestReference(owner: "example", repository: "desktop", number: 31),
                title: "Sync window frames across displays", authorLogin: "developer", isViewerAuthor: true,
                isDraft: true, mergeable: "MERGEABLE", mergeStateStatus: "DRAFT",
                checksState: "PENDING", checksKnown: true, readinessIsComplete: true,
                updatedAt: .now.addingTimeInterval(-3000)),
            .init(
                reference: PullRequestReference(owner: "example", repository: "site", number: 14),
                title: "Add a changelog page", authorLogin: "developer", isViewerAuthor: true,
                isDraft: false, mergeable: "MERGEABLE", mergeStateStatus: "BLOCKED",
                checksState: "PENDING", checksKnown: true, readinessIsComplete: true,
                updatedAt: .now.addingTimeInterval(-1800)),
            .init(
                reference: PullRequestReference(owner: "example", repository: "toolkit", number: 19),
                title: "Update build tooling", authorLogin: "developer", isViewerAuthor: true,
                isDraft: false, mergeable: "MERGEABLE", mergeStateStatus: "BEHIND", reviewDecision: "APPROVED",
                checksState: "SUCCESS", checksKnown: true, readinessIsComplete: true,
                updatedAt: .now.addingTimeInterval(-14400)),
            // Shows the Merged group under Waiting.
            .init(
                reference: PullRequestReference(owner: "example", repository: "toolkit", number: 6),
                title: "Speed up launch", authorLogin: "developer", isViewerAuthor: true, state: "MERGED",
                isDraft: false, reviewDecision: "APPROVED", checksState: "SUCCESS", checksKnown: true,
                updatedAt: .now.addingTimeInterval(-2400), terminalObservedAt: .now),
        ]
        // Cards show as cached until a refresh, except one fresh approved card that shows the green outline.
        for index in state.pullRequests.indices where state.pullRequests[index].reference != second {
            state.pullRequests[index].isStale = true
            state.pullRequests[index].readinessIsComplete = false
        }
        state.notes = [
            Note(
                markdown:
                    "# A little room to think\n\n- keep the board quiet\n- bring the next action into view\n\n**Native notes**, alongside your work.\n\n`cmd+n` starts a new note."
            ),
            Note(markdown: "Check the window on the external display.", pullRequest: first),
        ]
        state.lastRefreshAt = .now
        return state
    }
}
