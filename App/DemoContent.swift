import Foundation
import StowCore

/// Synthetic content is only used by the explicit debug verification launch argument.
enum DemoContent {
    static func state() -> AppState {
        var state = AppState()
        let first = PullRequestReference(owner: "example", repository: "desktop", number: 24)
        let second = PullRequestReference(owner: "example", repository: "desktop", number: 27)
        let third = PullRequestReference(owner: "example", repository: "toolkit", number: 8)
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
                    reviews: [.init(author: "reviewer", state: "APPROVED")], unresolvedThreadCount: 1)),
            .init(
                reference: third, title: "Add keyboard shortcuts", authorLogin: "developer", isViewerAuthor: true,
                isDraft: false, mergeable: "MERGEABLE", mergeStateStatus: "BLOCKED", reviewDecision: "REVIEW_REQUIRED",
                checksState: "SUCCESS", checksKnown: true, readinessIsComplete: true,
                updatedAt: .now.addingTimeInterval(-7200)),
        ]
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
