import Foundation
import StowCore

/// Synthetic content is only used by the explicit debug verification launch argument.
enum DemoContent {
    /// The card and note counts a `--stow-demo-load` launch asks for.
    @MainActor static var load: (cards: Int, notes: Int)?

    @MainActor static func state() -> AppState {
        if let load { return loadState(cards: load.cards, notes: load.notes) }
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
            state.pullRequests[index].markStale()
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

    /// Deterministic synthetic cards and notes for measuring: the first note is about 46 KB and detached with four others.
    @MainActor static func loadState(cards: Int, notes: Int) -> AppState {
        var state = AppState()
        let repositories = ["desktop", "toolkit", "site", "docs"]
        // A cycle of card states that spreads cards across the board's sections.
        let templates: [(merge: String, review: String?, checks: String, draft: Bool, mine: Bool, direct: Bool)] = [
            ("BLOCKED", "CHANGES_REQUESTED", "SUCCESS", false, true, false),
            ("UNSTABLE", "APPROVED", "FAILURE", false, true, false),
            ("BLOCKED", "REVIEW_REQUIRED", "SUCCESS", false, true, false),
            ("CLEAN", "APPROVED", "SUCCESS", false, true, false),
            ("DIRTY", "APPROVED", "SUCCESS", false, true, false),
            ("BLOCKED", "REVIEW_REQUIRED", "PENDING", false, false, true),
            ("DRAFT", nil, "PENDING", true, true, false),
            ("BEHIND", "APPROVED", "SUCCESS", false, true, false),
        ]
        state.pullRequests = (0..<cards).map { index in
            let template = templates[index % templates.count]
            let reference = PullRequestReference(
                owner: "example", repository: repositories[index % repositories.count], number: 100 + index)
            return PullRequestSnapshot(
                reference: reference, title: "Synthetic change \(index + 1)",
                authorLogin: template.mine ? "developer" : "teammate", isViewerAuthor: template.mine,
                isDraft: template.draft, mergeable: template.merge == "DIRTY" ? "CONFLICTING" : "MERGEABLE",
                mergeStateStatus: template.merge, reviewDecision: template.review, checksState: template.checks,
                checksKnown: true, hasDirectReviewRequest: template.direct, readinessIsComplete: true,
                updatedAt: .now.addingTimeInterval(-Double(600 * (index + 1))), isStale: true)
        }
        let detached: Set<Int> = [0, 4, 5, 6, 7]
        state.notes = (0..<notes).map { index in
            let reference = (1...3).contains(index) && index <= cards ? state.pullRequests[index - 1].reference : nil
            let frame = WindowFrame(x: 80 + Double(index) * 40, y: 120 + Double(index) * 40, width: 360, height: 400)
            return Note(
                markdown: index == 0 ? markdown(bytes: 46_000) : "Synthetic note \(index + 1)\n\n- one short line",
                pullRequest: reference, isDetached: detached.contains(index), frame: frame)
        }
        state.lastRefreshAt = .now
        return state
    }

    /// Varied Markdown of at least `bytes` UTF-8 bytes: headings, lists, code, links, and bold text.
    static func markdown(bytes: Int) -> String {
        var text = ""
        var section = 1
        while text.utf8.count < bytes {
            text += """
                ## Section \(section)

                A paragraph of **synthetic text** with a [link](https://example.com/section/\(section)) and `inline code`.
                Another sentence keeps the line long enough to wrap in a narrow note window.

                - first item of section \(section)
                - second item with *emphasis*
                - third item with a [reference](https://example.com/item/\(section))

                ```swift
                let value\(section) = \(section) * 2
                print(value\(section))
                ```


                """
            section += 1
        }
        return text
    }
}
