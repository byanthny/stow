import Foundation
import StowCore
import Testing

@testable import StowGitHub

private struct UnexpectedRequest: Error {}
private actor ScriptedTransport: GraphQLTransport {
    struct Step: Sendable {
        var contains: String
        var response: GraphQLResponse
        var cursor: String?
        init(_ contains: String, _ response: GraphQLResponse, cursor: String? = nil) {
            self.contains = contains
            self.response = response
            self.cursor = cursor
        }
    }
    var steps: [Step]
    private(set) var count = 0
    init(_ steps: [Step]) { self.steps = steps }
    func execute(query: String, variables: [String: GraphQLValue]) async throws -> GraphQLResponse {
        guard !steps.isEmpty else { throw UnexpectedRequest() }
        let step = steps.removeFirst()
        count += 1
        #expect(query.contains(step.contains))
        if let cursor = step.cursor { #expect(variables["cursor"] == .string(cursor)) }
        return step.response
    }
}

@Suite("StowGitHub synthetic transport tests")
struct GitHubTests {
    private func json(_ string: String, status: Int = 200, headers: [String: String] = [:], exit: Int32 = 0)
        -> GraphQLResponse
    {
        .init(body: Data(string.utf8), statusCode: status, headers: headers, exitCode: exit)
    }
    private func fixture() throws -> GraphQLValue {
        let url = try #require(Bundle.module.url(forResource: "null-checks", withExtension: "json"))
        return try JSONDecoder().decode(GraphQLValue.self, from: Data(contentsOf: url))
    }
    private func encoded(_ value: GraphQLValue, exit: Int32 = 0, headers: [String: String] = [:]) throws
        -> GraphQLResponse
    {
        .init(body: try JSONEncoder().encode(value), headers: headers, exitCode: exit)
    }
    private var emptySearch: GraphQLResponse {
        json(#"{"data":{"search":{"issueCount":0,"nodes":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}"#)
    }
    private func updatingNode(_ root: GraphQLValue, _ changes: [String: GraphQLValue]) -> GraphQLValue {
        var object = root.object
        var data = root["data"].object
        var viewer = root["data"]["viewer"].object
        var prs = root["data"]["viewer"]["pullRequests"].object
        var node = root["data"]["viewer"]["pullRequests"]["nodes"].array[0].object
        node.merge(changes) { _, new in new }
        prs["nodes"] = .array([.object(node)])
        viewer["pullRequests"] = .object(prs)
        data["viewer"] = .object(viewer)
        object["data"] = .object(data)
        return .object(object)
    }

    @Test func explicitNullRollupAndReviewDecisionAreKnown() async throws {
        let transport = ScriptedTransport([
            .init("StowViewer", try encoded(fixture())), .init("StowReviewRequests", emptySearch),
        ])
        let result = try await GHClient(transport: transport).refresh(pins: [], previous: [])
        let snapshot = try #require(result.snapshots.first)
        #expect(result.isComplete)
        #expect(snapshot.checksKnown)
        #expect(snapshot.checksState == nil)
        #expect(snapshot.reviewDecision == nil)
        #expect(snapshot.readinessIsComplete)
        #expect(!snapshot.isStale)
        #expect(snapshot.hasDirectReviewRequest == false)
    }

    @Test func cliIncludeHeadersPreserveNonzeroPartialBodies() throws {
        let raw = Data(
            "HTTP/2.0 403 Forbidden\r\nX-RateLimit-Remaining: 0\r\nRetry-After: 120\r\n\r\n{\"data\":{\"synthetic\":true},\"errors\":[{\"type\":\"RATE_LIMITED\"}]}"
                .utf8)
        let response = GHProcessTransport.decodeCLIOutput(raw, exitCode: 1)
        #expect(response.statusCode == 403)
        #expect(response.headers["x-ratelimit-remaining"] == "0")
        #expect(response.headers["retry-after"] == "120")
        #expect(response.exitCode == 1)
        let body = try JSONDecoder().decode(GraphQLValue.self, from: response.body)
        #expect(body["data"]["synthetic"].bool == true)
    }

    @Test func unknownEnumsRemainVerbatimAndCannotBecomeReady() async throws {
        let response = updatingNode(
            try fixture(), ["mergeStateStatus": .string("FUTURE_STATE"), "reviewDecision": .string("FUTURE_REVIEW")])
        let transport = ScriptedTransport([
            .init("StowViewer", try encoded(response)), .init("StowReviewRequests", emptySearch),
        ])
        let result = try await GHClient(transport: transport).refresh(pins: [], previous: [])
        let snapshot = try #require(result.snapshots.first)
        #expect(snapshot.mergeStateStatus == "FUTURE_STATE")
        #expect(snapshot.reviewDecision == "FUTURE_REVIEW")
        #expect(snapshot.isStale)
        #expect(!snapshot.readinessIsComplete)
    }

    @Test func authoredConnectionConfirmsViewerAuthorInsteadOfAssuming() async throws {
        let response = updatingNode(try fixture(), ["author": .object(["login": .string("somebody-else")])])
        let transport = ScriptedTransport([
            .init("StowViewer", try encoded(response)), .init("StowReviewRequests", emptySearch),
        ])
        let result = try await GHClient(transport: transport).refresh(pins: [], previous: [])
        #expect(result.isComplete)
        #expect(result.snapshots.isEmpty)
    }

    @Test func missingRollupDiffersFromExplicitNull() async throws {
        var root = try fixture().object
        var data = root["data"]!.object
        var viewer = root["data"]!["viewer"].object
        var connection = viewer["pullRequests"]!.object
        var node = connection["nodes"]!.array[0].object
        node.removeValue(forKey: "statusCheckRollup")
        connection["nodes"] = .array([.object(node)])
        viewer["pullRequests"] = .object(connection)
        data["viewer"] = .object(viewer)
        root["data"] = .object(data)
        let transport = ScriptedTransport([
            .init("StowViewer", try encoded(.object(root))), .init("StowReviewRequests", emptySearch),
        ])
        let result = try await GHClient(transport: transport).refresh(pins: [], previous: [])
        #expect(result.snapshots.first?.checksKnown == false)
        #expect(result.snapshots.first?.readinessIsComplete == false)
    }

    @Test func partialNonzeroGraphQLEnvelopeKeepsDataAndPreviousCards() async throws {
        var root = try fixture().object
        root["errors"] = .array([
            .object(["message": .string("Synthetic inaccessible field"), "path": .array([.string("viewer")])])
        ])
        let previous = PullRequestSnapshot(
            reference: .init(owner: "example", repository: "older", number: 2), title: "Previously known")
        let transport = ScriptedTransport([
            .init("StowViewer", try encoded(.object(root), exit: 1)), .init("StowReviewRequests", emptySearch),
        ])
        let result = try await GHClient(transport: transport).refresh(pins: [], previous: [previous])
        #expect(!result.isComplete)
        #expect(result.snapshots.count == 2)
        #expect(result.snapshots.allSatisfy { $0.isStale })
        #expect(result.snapshots.allSatisfy { !$0.readinessIsComplete })
    }

    @Test func onlyDirectUserRequestsCountAndReviewRequestsPaginate() async throws {
        let firstRequests = GraphQLValue.object([
            "nodes": .array([
                .object([
                    "requestedReviewer": .object([
                        "__typename": .string("Team"), "id": .string("viewer-synthetic"), "name": .string("Team"),
                    ])
                ])
            ]),
            "pageInfo": .object(["hasNextPage": .bool(true), "endCursor": .string("review-page-2")]),
        ])
        let response = updatingNode(try fixture(), ["reviewRequests": firstRequests])
        let page = json(
            #"{"data":{"node":{"reviewRequests":{"nodes":[{"requestedReviewer":{"__typename":"User","id":"viewer-synthetic","login":"synthetic-viewer"}}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}"#
        )
        let transport = ScriptedTransport([
            .init("StowViewer", try encoded(response)), .init("StowReviewRequests", emptySearch),
            .init("StowReviewerPage", page, cursor: "review-page-2"),
        ])
        let result = try await GHClient(transport: transport).refresh(pins: [], previous: [])
        #expect(result.isComplete)
        #expect(result.snapshots.first?.hasDirectReviewRequest == true)
        #expect(await transport.count == 3)
    }

    @Test func authoredAndSearchConnectionsPaginate() async throws {
        var root = try fixture().object
        var data = try fixture()["data"].object
        var viewer = data["viewer"]!.object
        var prs = viewer["pullRequests"]!.object
        prs["pageInfo"] = .object(["hasNextPage": .bool(true), "endCursor": .string("authored-2")])
        viewer["pullRequests"] = .object(prs)
        data["viewer"] = .object(viewer)
        root["data"] = .object(data)
        let authored = json(
            #"{"data":{"viewer":{"pullRequests":{"nodes":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}"#)
        let search = json(
            #"{"data":{"search":{"issueCount":101,"nodes":[],"pageInfo":{"hasNextPage":true,"endCursor":"search-2"}}}}"#
        )
        let transport = ScriptedTransport([
            .init("StowViewer", try encoded(.object(root))), .init("StowAuthored", authored, cursor: "authored-2"),
            .init("StowReviewRequests", search), .init("StowReviewRequests", emptySearch, cursor: "search-2"),
        ])
        let result = try await GHClient(transport: transport).refresh(pins: [], previous: [])
        #expect(result.isComplete)
        #expect(await transport.count == 4)
    }

    @Test func searchCapAndInaccessiblePinnedRequestsAreIncomplete() async throws {
        let search = json(
            #"{"data":{"search":{"issueCount":1001,"nodes":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}"#)
        let inaccessible = json(
            #"{"data":{"pr0":null},"errors":[{"type":"NOT_FOUND","message":"Synthetic hidden repository"}]}"#, exit: 1)
        let ref = PullRequestReference(owner: "example", repository: "hidden", number: 10)
        let transport = ScriptedTransport([
            .init("StowViewer", try encoded(fixture())), .init("StowReviewRequests", search),
            .init("StowPinned", inaccessible),
        ])
        let result = try await GHClient(transport: transport).refresh(pins: [ref], previous: [])
        #expect(!result.isComplete)
        let snapshot = try #require(result.snapshots.first { $0.id == ref.id })
        #expect(snapshot.isUnavailable && snapshot.isStale && !snapshot.readinessIsComplete)
    }

    @Test func http200RateErrorPreservesPartialDataAndPreventsManualBypass() async throws {
        var root = try fixture().object
        root["errors"] = .array([
            .object(["type": .string("RATE_LIMITED"), "message": .string("Synthetic rate limit")])
        ])
        let transport = ScriptedTransport([
            .init("StowViewer", try encoded(.object(root), exit: 1, headers: ["Retry-After": "120"]))
        ])
        let client = GHClient(transport: transport)
        let result = try await client.refresh(pins: [], previous: [])
        #expect(!result.isComplete)
        #expect(result.snapshots.count == 1)
        do {
            _ = try await client.refresh(pins: [], previous: [])
            Issue.record("Backoff was bypassed")
        } catch GitHubError.rateLimited(let until) { #expect(until.timeIntervalSinceNow > 100) }
        do {
            _ = try await client.details(for: .init(owner: "example", repository: "fixture", number: 1))
            Issue.record("Details bypassed backoff")
        } catch GitHubError.rateLimited {}
        #expect(await transport.count == 1)
    }

    @Test func lazyDetailsPaginateAllConnectionsAndPickNewestComment() async throws {
        let checks1 = json(
            #"{"data":{"repository":{"pullRequest":{"statusCheckRollup":{"contexts":{"nodes":[{"__typename":"CheckRun","name":"Build","status":"COMPLETED","conclusion":"SUCCESS","detailsUrl":"https://example.com/build"}],"pageInfo":{"hasNextPage":true,"endCursor":"checks-2"}}}}}}}"#
        )
        let checks2 = json(
            #"{"data":{"repository":{"pullRequest":{"statusCheckRollup":{"contexts":{"nodes":[{"__typename":"StatusContext","context":"Legacy","state":"SUCCESS","targetUrl":"https://example.com/status"}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}}}"#
        )
        let reviews1 = json(
            #"{"data":{"repository":{"pullRequest":{"latestReviews":{"nodes":[{"author":{"login":"reviewer"},"state":"APPROVED"}],"pageInfo":{"hasNextPage":true,"endCursor":"reviews-2"}}}}}}"#
        )
        let reviews2 = json(
            #"{"data":{"repository":{"pullRequest":{"latestReviews":{"nodes":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}}"#
        )
        let threads1 = json(
            #"{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"isResolved":false,"comments":{"nodes":[{"body":"Older synthetic comment","createdAt":"2026-01-01T00:00:00Z","author":{"login":"older"}}]}}],"pageInfo":{"hasNextPage":true,"endCursor":"threads-2"}}}}}}"#
        )
        let threads2 = json(
            #"{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"isResolved":true,"comments":{"nodes":[{"body":"Newest synthetic comment","createdAt":"2026-01-02T00:00:00Z","author":{"login":"newer"}}]}}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}}"#
        )
        let transport = ScriptedTransport([
            .init("contexts", checks1), .init("contexts", checks2, cursor: "checks-2"),
            .init("latestReviews", reviews1), .init("latestReviews", reviews2, cursor: "reviews-2"),
            .init("reviewThreads", threads1), .init("reviewThreads", threads2, cursor: "threads-2"),
        ])
        let details = try await GHClient(transport: transport).details(
            for: .init(owner: "example", repository: "fixture", number: 1))
        #expect(details.isComplete)
        #expect(details.checks.count == 2)
        #expect(details.reviews.count == 1)
        #expect(details.unresolvedThreadCount == 1)
        #expect(details.latestComment == "Newest synthetic comment")
        #expect(details.latestCommentAuthor == "newer")
    }

    @Test func inaccessibleDetailsAndUnsupportedHostsAreSafeErrors() async throws {
        let transport = ScriptedTransport([.init("StowDetails", json(#"{"data":{"repository":null}}"#))])
        let client = GHClient(transport: transport)
        await #expect(throws: GitHubError.unavailable) {
            try await client.details(for: .init(owner: "example", repository: "hidden", number: 1))
        }
        await #expect(throws: GitHubError.unsupportedHost) {
            try await client.details(for: .init(host: "example.com", owner: "example", repository: "hidden", number: 1))
        }
    }

    @Test func accountSwitchDiscardsPrivateTitlesDetailsAndUnpinnedReferences() async throws {
        let pinned = PullRequestReference(owner: "example", repository: "hidden-pinned", number: 7)
        let unpinned = PullRequestReference(owner: "example", repository: "hidden-unpinned", number: 8)
        let accessible = PullRequestReference(owner: "example", repository: "fixture", number: 1)
        let oldDetails = PullRequestDetails(latestComment: "Old account synthetic private comment")
        let previous = [pinned, unpinned, accessible].map {
            PullRequestSnapshot(reference: $0, title: "Old account synthetic private title", details: oldDetails)
        }
        let inaccessible = json(
            #"{"data":{"pr0":null},"errors":[{"type":"NOT_FOUND","message":"Synthetic hidden repository"}]}"#, exit: 1)
        let transport = ScriptedTransport([
            .init("StowViewer", try encoded(fixture())), .init("StowReviewRequests", emptySearch),
            .init("StowPinned", inaccessible),
        ])
        let result = try await GHClient(transport: transport).refresh(
            pins: [pinned], previous: previous, expectedViewerLogin: "old-account")
        #expect(result.viewerLogin == "synthetic-viewer")
        #expect(result.snapshots.count == 2)
        #expect(!result.snapshots.contains { $0.id == unpinned.id })
        #expect(result.snapshots.allSatisfy { $0.details == nil })
        #expect(result.snapshots.allSatisfy { $0.title != "Old account synthetic private title" })
        let unavailable = try #require(result.snapshots.first { $0.id == pinned.id })
        #expect(unavailable.isUnavailable)
        #expect(unavailable.title == pinned.displayName)
    }

    @Test func coordinatorFollowsUpWhenPinsChangeDuringFlight() async throws {
        let client = DelayedClient()
        let coordinator = RefreshCoordinator(client: client)
        let first = Task { try await coordinator.refresh(pins: [], previous: []) }
        try await Task.sleep(for: .milliseconds(10))
        let pin = PullRequestReference(owner: "example", repository: "new-pin", number: 10)
        let second = Task { try await coordinator.refresh(pins: [pin], previous: []) }
        _ = try await first.value
        _ = try await second.value
        #expect(await client.count == 2)
        #expect(await client.receivedPins == [[], [pin]])
    }

    @Test func coalescesOverlappingRefreshesAndSupportsCancellation() async throws {
        let client = DelayedClient()
        let coordinator = RefreshCoordinator(client: client)
        async let a = coordinator.refresh(pins: [], previous: [])
        async let b = coordinator.refresh(pins: [], previous: [])
        let (first, second) = try await (a, b)
        #expect(first.viewerLogin == second.viewerLogin)
        #expect(await client.count == 1)
        let task = Task { try await coordinator.refresh(pins: [], previous: []) }
        try await Task.sleep(for: .milliseconds(10))
        await coordinator.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}

private actor DelayedClient: GitHubClient {
    private(set) var count = 0
    private(set) var receivedPins: [[PullRequestReference]] = []
    func refresh(pins: [PullRequestReference], previous: [PullRequestSnapshot], expectedViewerLogin: String?)
        async throws -> GitHubRefreshResult
    {
        count += 1
        receivedPins.append(pins)
        try await Task.sleep(for: .milliseconds(70))
        return .init(viewerLogin: "synthetic-viewer", snapshots: [])
    }
    func details(for reference: PullRequestReference) async throws -> PullRequestDetails { .init() }
}
