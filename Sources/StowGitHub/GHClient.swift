import Darwin
import Foundation
import StowCore

public protocol GitHubClient: Sendable {
    func refresh(pins: [PullRequestReference], previous: [PullRequestSnapshot], expectedViewerLogin: String?)
        async throws -> GitHubRefreshResult
    func details(for reference: PullRequestReference) async throws -> PullRequestDetails
}

extension GitHubClient {
    public func refresh(pins: [PullRequestReference], previous: [PullRequestSnapshot]) async throws
        -> GitHubRefreshResult
    {
        try await refresh(pins: pins, previous: previous, expectedViewerLogin: nil)
    }
}

extension GHClient {
    public func details(for reference: PullRequestReference) async throws -> PullRequestDetails {
        guard reference.host.lowercased() == "github.com" else { throw GitHubError.unsupportedHost }
        let selectors: [String: String] = [
            "contexts":
                "statusCheckRollup { contexts(first:100, after:$cursor) { nodes { __typename ... on CheckRun { name conclusion status detailsUrl } ... on StatusContext { context state targetUrl } } \(Self.pageInfo) } }",
            "latestReviews":
                "latestReviews(first:100, after:$cursor) { nodes { author { login } state body submittedAt } \(Self.pageInfo) }",
            "reviewThreads":
                "reviewThreads(first:100, after:$cursor) { nodes { isResolved comments(last:1) { nodes { body createdAt author { login } } } } \(Self.pageInfo) }",
        ]
        var checks: [CheckSummary] = []
        var reviews: [ReviewSummary] = []
        var unresolved = 0
        var complete = true
        var threadsKnown = false
        var successfulPages = 0
        var firstFailure: (any Error)?
        var newestComment: (date: Date, body: String, author: String?)?
        var commits: [CommitSummary]?
        // Fetch each connection independently so a failed or large connection cannot hide the others.
        for name in ["contexts", "latestReviews", "reviewThreads"] {
            guard let selection = selectors[name] else { continue }
            var cursor: String?
            var seen = Set<String>()
            var pages = 0
            var connectionComplete = true
            do {
                repeat {
                    // The first reviews page also carries the last three commits.
                    let fields =
                        name == "latestReviews" && pages == 0 ? "\(selection) \(Self.recentCommits)" : selection
                    let page = try await request(
                        """
                        query StowDetails($owner:String!,$repository:String!,$number:Int!,$cursor:String) {
                          repository(owner:$owner,name:$repository) { pullRequest(number:$number) { \(fields) } }
                        }
                        """,
                        [
                            "owner": .string(reference.owner), "repository": .string(reference.repository),
                            "number": .integer(reference.number), "cursor": cursor.map(GraphQLValue.string) ?? .null,
                        ])
                    let pr = page.data["repository"]["pullRequest"]
                    if pr.isNull { throw GitHubError.unavailable }
                    successfulPages += 1
                    complete = complete && !page.hasErrors
                    connectionComplete = connectionComplete && !page.hasErrors
                    if name == "contexts", pr.object.keys.contains("statusCheckRollup"), pr["statusCheckRollup"].isNull
                    {
                        break
                    }
                    let connection = name == "contexts" ? pr["statusCheckRollup"]["contexts"] : pr[name]
                    if !Self.validConnection(connection) {
                        complete = false
                        connectionComplete = false
                        break
                    }
                    if name == "reviewThreads" { threadsKnown = true }
                    if name == "latestReviews", pages == 0, case .array = pr["commits"]["nodes"] {
                        commits = pr["commits"]["nodes"].array.reversed().compactMap { node in
                            node["commit"]["messageHeadline"].string.map {
                                CommitSummary(
                                    headline: Self.displayName($0),
                                    committedAt: node["commit"]["committedDate"].string.flatMap(Self.date))
                            }
                        }
                    }
                    for node in connection["nodes"].array {
                        switch name {
                        case "contexts":
                            if node["__typename"].string == "CheckRun", let checkName = node["name"].string {
                                let state = node["conclusion"].string ?? node["status"].string ?? "UNKNOWN"
                                checks.append(
                                    .init(
                                        name: Self.displayName(checkName), state: state,
                                        url: Self.safeURL(node["detailsUrl"].string)))
                                if state == "UNKNOWN" { complete = false }
                            } else if node["__typename"].string == "StatusContext",
                                let checkName = node["context"].string
                            {
                                checks.append(
                                    .init(
                                        name: Self.displayName(checkName), state: node["state"].string ?? "UNKNOWN",
                                        url: Self.safeURL(node["targetUrl"].string)))
                                if node["state"].string == nil { complete = false }
                            } else {
                                complete = false
                            }
                        case "latestReviews":
                            reviews.append(
                                .init(
                                    author: Self.displayName(node["author"]["login"].string ?? "Deleted user"),
                                    state: node["state"].string ?? "UNKNOWN"))
                            if node["state"].string == nil { complete = false }
                        default:
                            if let resolved = node["isResolved"].bool {
                                if !resolved { unresolved += 1 }
                            } else {
                                complete = false
                                connectionComplete = false
                            }
                            guard case .array = node["comments"]["nodes"] else {
                                complete = false
                                connectionComplete = false
                                continue
                            }
                            for comment in node["comments"]["nodes"].array {
                                if let body = comment["body"].string,
                                    let date = comment["createdAt"].string.flatMap(Self.date),
                                    newestComment == nil || date > newestComment!.date
                                {
                                    newestComment = (date, String(body.prefix(500)), comment["author"]["login"].string)
                                }
                            }
                        }
                    }
                    pages += 1
                    if connection["pageInfo"]["hasNextPage"].bool != true { break }
                    // Details are display-only; a few pages bound process launches for very large PRs.
                    guard pages < Self.maxDetailPages, let next = connection["pageInfo"]["endCursor"].string,
                        seen.insert(next).inserted
                    else {
                        complete = false
                        connectionComplete = false
                        break
                    }
                    cursor = next
                } while true
            } catch is CancellationError { throw CancellationError() } catch GitHubError.unavailable {
                throw GitHubError.unavailable
            } catch {
                complete = false
                connectionComplete = false
                firstFailure = firstFailure ?? error
            }
            if name == "reviewThreads" && !connectionComplete { threadsKnown = false }
        }
        if successfulPages == 0, let firstFailure { throw firstFailure }
        // Cached details are saved with every index write, so keep them bounded.
        if checks.count > Self.maxDetailItems {
            // Keep checks that may need attention when the list must be cut.
            let passing: Set = ["SUCCESS", "NEUTRAL", "SKIPPED"]
            checks = Array(
                (checks.filter { !passing.contains($0.state) } + checks.filter { passing.contains($0.state) })
                    .prefix(Self.maxDetailItems))
            complete = false
        }
        if reviews.count > Self.maxDetailItems {
            reviews = Array(reviews.prefix(Self.maxDetailItems))
            complete = false
        }
        return .init(
            checks: checks, reviews: reviews, unresolvedThreadCount: threadsKnown ? unresolved : nil,
            latestComment: newestComment?.body, latestCommentAuthor: newestComment?.author, commits: commits,
            fetchedAt: .now, isComplete: complete)
    }
    static let maxDetailPages = 3
    static let maxDetailItems = 100
    private static func displayName(_ name: String) -> String { String(name.prefix(200)) }
    private static func safeURL(_ string: String?) -> URL? {
        guard let string, string.utf8.count <= 2_048, let url = URL(string: string),
            url.isWebLink
        else {
            return nil
        }
        return url
    }
}

public struct GitHubRefreshResult: Sendable {
    public var viewerLogin: String
    public var snapshots: [PullRequestSnapshot]
    public var isComplete: Bool
    public var warning: String?
    public var fetchedAt: Date
    public init(
        viewerLogin: String, snapshots: [PullRequestSnapshot], isComplete: Bool = true,
        warning: String? = nil, fetchedAt: Date = .now
    ) {
        self.viewerLogin = viewerLogin
        self.snapshots = snapshots
        self.isComplete = isComplete
        self.warning = warning
        self.fetchedAt = fetchedAt
    }
}

/// Coalesces overlapping refreshes, including requests from timer, focus and manual refresh.
/// Cancellation of any waiter cancels the shared request; partial results must never replace newer data.
public actor RefreshCoordinator {
    private let client: any GitHubClient
    private struct Inputs: Equatable, Sendable {
        var pins: [PullRequestReference]
        var previous: [PullRequestSnapshot]
        var expectedViewerLogin: String?
    }
    private struct Flight {
        var id: UUID
        var inputs: Inputs
        var task: Task<GitHubRefreshResult, any Error>
    }
    private var flight: Flight?
    public init(client: any GitHubClient) { self.client = client }
    public func cancel() {
        flight?.task.cancel()
        flight = nil
    }
    public func refresh(
        pins: [PullRequestReference], previous: [PullRequestSnapshot], expectedViewerLogin: String? = nil
    ) async throws -> GitHubRefreshResult {
        let inputs = Inputs(pins: pins, previous: previous, expectedViewerLogin: expectedViewerLogin)
        let current: Flight
        let needsFollowup: Bool
        if let flight {
            current = flight
            needsFollowup = flight.inputs != inputs
        } else {
            let client = client
            current = Flight(
                id: UUID(), inputs: inputs,
                task: Task {
                    try await client.refresh(pins: pins, previous: previous, expectedViewerLogin: expectedViewerLogin)
                })
            needsFollowup = false
            flight = current
        }
        do {
            let result = try await withTaskCancellationHandler {
                try await current.task.value
            } onCancel: {
                current.task.cancel()
            }
            if flight?.id == current.id { flight = nil }
            try Task.checkCancellation()
            if needsFollowup {
                return try await refresh(pins: pins, previous: previous, expectedViewerLogin: expectedViewerLogin)
            }
            return result
        } catch {
            if flight?.id == current.id { flight = nil }
            throw error
        }
    }
}

public actor GHClient: GitHubClient {
    private let transport: (any GraphQLTransport)?
    private var retryAt: Date?
    private let maxPages = 200
    /// Without a usable `gh` outside `folder`, every request fails with `executableNotFound`.
    public init(executableURL: URL? = nil, excluding folder: URL? = nil) {
        transport = (executableURL ?? Self.discoverExecutable(excluding: folder)).map {
            GHProcessTransport(executableURL: $0, excluding: folder)
        }
    }
    public init(transport: any GraphQLTransport) { self.transport = transport }

    public nonisolated static func discoverExecutable(preferredPath: String? = nil, excluding folder: URL? = nil)
        -> URL?
    {
        let explicit = preferredPath.map { [$0] } ?? []
        let paths =
            explicit + ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
            + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/gh" }
        return paths.first { isUsableExecutable(atPath: $0, excluding: folder) }.map { URL(fileURLWithPath: $0) }
    }

    /// Stow launches only an absolute path named `gh` that resolves to a regular executable file whose permission
    /// bits allow no writes by its group or other users and no setuid or setgid, outside `folder` both where it is
    /// and where it leads. Anything else is ignored, whatever saved state or a restore says.
    public nonisolated static func isUsableExecutable(atPath path: String, excluding folder: URL? = nil) -> Bool {
        checkedExecutable(atPath: path, excluding: folder) != nil
    }

    /// The file `path` resolves to, when `isUsableExecutable` accepts it.
    nonisolated static func checkedExecutable(atPath path: String, excluding folder: URL?) -> URL? {
        guard path.hasPrefix("/"), (path as NSString).lastPathComponent == "gh" else { return nil }
        // A link named gh must also lead to a program named gh, as Homebrew and installer links do.
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        var info = stat()
        guard (resolved as NSString).lastPathComponent == "gh",
            resolved.withCString({ Darwin.lstat($0, &info) }) == 0,
            (info.st_mode & S_IFMT) == S_IFREG,
            info.st_mode & (S_IWGRP | S_IWOTH | S_ISUID | S_ISGID) == 0
        else { return nil }
        if let folder, [path, resolved].contains(where: { URL(fileURLWithPath: $0).isInside(folder) }) {
            return nil
        }
        return FileManager.default.isExecutableFile(atPath: resolved) ? URL(fileURLWithPath: resolved) : nil
    }

    private struct Envelope {
        var data: GraphQLValue
        var hasErrors: Bool
        var isRateLimited: Bool
    }

    private func request(_ query: String, _ variables: [String: GraphQLValue] = [:]) async throws -> Envelope {
        try Task.checkCancellation()
        if let retryAt, retryAt > .now { throw GitHubError.rateLimited(until: retryAt) }
        guard let transport else { throw GitHubError.executableNotFound }
        let response = try await transport.execute(query: query, variables: variables)
        try Task.checkCancellation()
        let headers = Dictionary(
            response.headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { _, last in last })
        let root = try? JSONDecoder().decode(GraphQLValue.self, from: response.body)
        let errors = root?["errors"].array ?? []
        let rateError =
            errors.contains { e in
                let type = e["type"].string ?? e["extensions"]["type"].string ?? e["extensions"]["code"].string ?? ""
                let message = e["message"].string?.lowercased() ?? ""
                return type.uppercased().contains("RATE") || message.contains("rate limit")
                    || message.contains("secondary rate")
            } || root?["message"].string?.lowercased().contains("rate limit") == true
        // Only a refusal backs off, never a rate-limit header alone.
        let limited =
            response.statusCode == 429 || rateError || (response.statusCode == 403 && headers["retry-after"] != nil)
        if limited {
            let reset = headers["x-ratelimit-reset"].flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
            let after =
                headers["retry-after"].flatMap(Double.init).map { Date.now.addingTimeInterval($0) }
                ?? headers["retry-after"].flatMap(Self.httpDate)
            let graphReset = root?["data"]["rateLimit"]["resetAt"].string.flatMap(Self.date)
            retryAt = [reset, after, graphReset, Date.now.addingTimeInterval(60)].compactMap { $0 }.max()
        }
        if response.statusCode == 401 { throw GitHubError.authenticationRequired }
        guard let root else {
            if limited, let retryAt { throw GitHubError.rateLimited(until: retryAt) }
            throw GitHubError.invalidResponse
        }
        let data = root["data"]
        if data.isNull {
            if limited, let retryAt { throw GitHubError.rateLimited(until: retryAt) }
            if response.statusCode == 401 || errors.contains(where: { $0["type"].string == "UNAUTHORIZED" }) {
                throw GitHubError.authenticationRequired
            }
            throw GitHubError.requestFailed
        }
        // gh exits nonzero for GraphQL errors even when useful partial data is present.
        return Envelope(
            data: data, hasErrors: !errors.isEmpty || response.statusCode >= 400 || response.exitCode != 0,
            isRateLimited: limited)
    }

    private static let pageInfo = "pageInfo { hasNextPage endCursor }"
    private static let recentCommits = "commits(last:3) { nodes { commit { messageHeadline committedDate } } }"
    /// Authored pull requests per page.
    static let authoredPageSize = 25
    /// Review requests per pull request in a list; `StowReviewerPage` fetches the rest.
    private static let reviewRequests =
        "reviewRequests(first:10) { nodes { requestedReviewer { __typename ... on User { id login } ... on Team { id name } } } \(pageInfo) }"
    private static let fields = """
        id number title url state isDraft mergeable mergeStateStatus reviewDecision createdAt updatedAt
        author { login } repository { name owner { login } }
        statusCheckRollup { state }
        \(reviewRequests)
        """

    public func refresh(
        pins: [PullRequestReference], previous: [PullRequestSnapshot], expectedViewerLogin: String? = nil
    ) async throws -> GitHubRefreshResult {
        let now = Date.now
        let first = try await request(
            """
            query StowViewer { viewer { id login pullRequests(first:\(Self.authoredPageSize), states:OPEN, orderBy:{field:UPDATED_AT,direction:DESC}) { nodes { \(Self.fields) } \(Self.pageInfo) } } }
            """)
        guard let login = first.data["viewer"]["login"].string, let viewerID = first.data["viewer"]["id"].string else {
            throw GitHubError.invalidResponse
        }
        // Another account's answer is never used: stop before resolving old refs or fetching more.
        if let expectedViewerLogin, expectedViewerLogin.caseInsensitiveCompare(login) != .orderedSame {
            throw GitHubError.accountMismatch(actualLogin: login)
        }
        var complete = !first.hasErrors
        var nodes: [String: (GraphQLValue, Bool)] = [:]
        func collect(_ values: [GraphQLValue], valid: Bool, authored: Bool = false) {
            for value in values {
                if authored && value["author"]["login"].string?.caseInsensitiveCompare(login) != .orderedSame {
                    continue
                }
                if let ref = Self.reference(value) { nodes[ref.id] = (value, valid) }
            }
        }
        collect(first.data["viewer"]["pullRequests"]["nodes"].array, valid: !first.hasErrors, authored: true)
        do {
            var connection = first.data["viewer"]["pullRequests"]
            var pages = 1
            var seen = Set<String>()
            while connection["pageInfo"]["hasNextPage"].bool == true {
                guard pages < maxPages, let cursor = connection["pageInfo"]["endCursor"].string,
                    seen.insert(cursor).inserted
                else {
                    complete = false
                    break
                }
                let page = try await request(
                    """
                    query StowAuthored($cursor:String!) { viewer { pullRequests(first:\(Self.authoredPageSize), after:$cursor, states:OPEN, orderBy:{field:UPDATED_AT,direction:DESC}) { nodes { \(Self.fields) } \(Self.pageInfo) } } }
                    """, ["cursor": .string(cursor)])
                connection = page.data["viewer"]["pullRequests"]
                complete = complete && !page.hasErrors && Self.validConnection(connection)
                collect(connection["nodes"].array, valid: !page.hasErrors, authored: true)
                pages += 1
            }
            complete = complete && Self.validConnection(connection)
            var searchCursor: String?
            var searchSeen = Set<String>()
            var searchPages = 0
            repeat {
                let page = try await request(
                    """
                    query StowReviewRequests($cursor:String) { search(query:"is:pr is:open user-review-requested:@me", type:ISSUE, first:100, after:$cursor) { issueCount nodes { ... on PullRequest { \(Self.fields) } } \(Self.pageInfo) } }
                    """, ["cursor": searchCursor.map(GraphQLValue.string) ?? .null])
                let search = page.data["search"]
                complete = complete && !page.hasErrors && Self.validConnection(search)
                if (search["issueCount"].int ?? 0) > 1000 { complete = false }
                collect(search["nodes"].array, valid: !page.hasErrors)
                searchPages += 1
                if search["pageInfo"]["hasNextPage"].bool != true { break }
                guard searchPages < 10, let cursor = search["pageInfo"]["endCursor"].string,
                    searchSeen.insert(cursor).inserted
                else {
                    complete = false
                    break
                }
                searchCursor = cursor
            } while true

            let references = Dictionary(
                (pins + previous.map(\.reference)).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }
            ).values.sorted { $0.id < $1.id }
            for start in stride(from: 0, to: references.count, by: 25) {
                let batch = Array(references[start..<min(start + 25, references.count)])
                var aliases: [String: PullRequestReference] = [:]
                var selections: [String] = []
                for (index, ref) in batch.enumerated() {
                    guard ref.host.lowercased() == "github.com" else {
                        complete = false
                        continue
                    }
                    let alias = "pr\(index)"
                    aliases[alias] = ref
                    selections.append(
                        "\(alias): repository(owner:\(Self.literal(ref.owner)),name:\(Self.literal(ref.repository))) { pullRequest(number:\(ref.number)) { \(Self.fields) } }"
                    )
                }
                if selections.isEmpty { continue }
                let page = try await request("query StowPinned { \(selections.joined(separator: " ")) }")
                complete = complete && !page.hasErrors
                for (alias, ref) in aliases {
                    let node = page.data[alias]["pullRequest"]
                    if node.isNull {
                        // Explicit resolution failure retains the old card and never fabricates a terminal state.
                        nodes[ref.id] = (.object(["_unavailable": .bool(true)]), false)
                        complete = false
                    } else {
                        nodes[ref.id] = (node, !page.hasErrors)
                    }
                }
            }
        } catch is CancellationError { throw CancellationError() } catch { complete = false }

        var snapshots: [PullRequestSnapshot] = []
        let oldByID = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let refsByID = Dictionary(
            (pins + previous.map(\.reference)).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for id in nodes.keys.sorted() {
            guard let (node, valid) = nodes[id] else { continue }
            if node["_unavailable"].bool == true {
                guard let ref = refsByID[id] else { continue }
                var snapshot = oldByID[id] ?? PullRequestSnapshot(reference: ref, title: ref.displayName)
                snapshot.isUnavailable = true
                snapshot.isStale = true
                snapshot.readinessIsComplete = false
                snapshot.fetchedAt = now
                snapshots.append(snapshot)
                continue
            }
            var requestNodes = node["reviewRequests"]["nodes"].array
            var requestComplete = valid && Self.validConnection(node["reviewRequests"])
            do {
                var connection = node["reviewRequests"]
                var pages = 1
                var seen = Set<String>()
                while connection["pageInfo"]["hasNextPage"].bool == true {
                    guard pages < maxPages, let cursor = connection["pageInfo"]["endCursor"].string,
                        let nodeID = node["id"].string, seen.insert(cursor).inserted
                    else {
                        requestComplete = false
                        break
                    }
                    let page = try await request(
                        """
                        query StowReviewerPage($id:ID!,$cursor:String!) { node(id:$id) { ... on PullRequest { reviewRequests(first:100,after:$cursor) { nodes { requestedReviewer { __typename ... on User { id login } ... on Team { id name } } } \(Self.pageInfo) } } } }
                        """, ["id": .string(nodeID), "cursor": .string(cursor)])
                    connection = page.data["node"]["reviewRequests"]
                    requestNodes += connection["nodes"].array
                    requestComplete = requestComplete && !page.hasErrors && Self.validConnection(connection)
                    pages += 1
                }
            } catch is CancellationError { throw CancellationError() } catch { requestComplete = false }
            complete = complete && requestComplete
            guard
                var snapshot = Self.snapshot(
                    node, viewerLogin: login, viewerID: viewerID,
                    requests: requestNodes, complete: requestComplete, now: now)
            else {
                complete = false
                continue
            }
            if let old = oldByID[id] {
                snapshot.observedStateSince = Self.sameObservedState(old, snapshot) ? old.observedStateSince : now
                snapshot.terminalObservedAt = snapshot.state == "OPEN" ? nil : (old.terminalObservedAt ?? now)
                snapshot.details = old.details
            }
            snapshots.append(snapshot)
        }
        // On an incomplete fetch, absence conveys nothing. Retain previous data, marked stale.
        if !complete {
            let present = Set(snapshots.map(\.id))
            for var old in previous where !present.contains(old.id) {
                old.isStale = true
                old.readinessIsComplete = false
                snapshots.append(old)
            }
        }
        let warning: String?
        if complete {
            warning = nil
        } else if let retryAt, retryAt > .now {
            warning = GitHubError.rateLimited(until: retryAt).localizedDescription + " Partial results are retained."
        } else {
            warning =
                "Some GitHub data could not be refreshed. Existing cards are retained; incomplete cards cannot be ready."
        }
        return .init(viewerLogin: login, snapshots: snapshots, isComplete: complete, warning: warning, fetchedAt: now)
    }

    private static func snapshot(
        _ node: GraphQLValue, viewerLogin: String, viewerID: String,
        requests: [GraphQLValue], complete: Bool, now: Date
    ) -> PullRequestSnapshot? {
        guard let ref = reference(node), let title = node["title"].string else { return nil }
        let author = node["author"]["login"].string
        let checksKnown =
            node.object.keys.contains("statusCheckRollup")
            && (node["statusCheckRollup"].isNull || node["statusCheckRollup"]["state"].string != nil)
        let direct = requests.contains {
            $0["requestedReviewer"]["__typename"].string == "User" && $0["requestedReviewer"]["id"].string == viewerID
        }
        let requestTypesKnown = requests.allSatisfy {
            let reviewer = $0["requestedReviewer"]
            return reviewer["__typename"].string == "Team"
                || (reviewer["__typename"].string == "User" && reviewer["id"].string != nil)
        }
        let state = node["state"].string ?? "UNKNOWN"
        let mergeable = node["mergeable"].string
        let mergeState = node["mergeStateStatus"].string
        let review = node["reviewDecision"].string
        let checks = node["statusCheckRollup"]["state"].string
        let fieldsKnown =
            node["id"].string != nil && author != nil && node["isDraft"].bool != nil
            && ["OPEN", "CLOSED", "MERGED"].contains(state)
            && ["MERGEABLE", "CONFLICTING"].contains(mergeable ?? "")
            && ["BEHIND", "BLOCKED", "CLEAN", "DIRTY", "DRAFT", "HAS_HOOKS", "UNSTABLE"].contains(mergeState ?? "")
            && node.object.keys.contains("reviewDecision")
            && (node["reviewDecision"].isNull
                || ["APPROVED", "CHANGES_REQUESTED", "REVIEW_REQUIRED"].contains(review ?? ""))
            && checksKnown
            && (checks == nil || ["SUCCESS", "FAILURE", "ERROR", "PENDING", "EXPECTED"].contains(checks!))
        let readyComplete = complete && fieldsKnown && requestTypesKnown
        return .init(
            reference: ref, title: title, nodeID: node["id"].string, authorLogin: author,
            isViewerAuthor: author.map { $0.caseInsensitiveCompare(viewerLogin) == .orderedSame }, state: state,
            isDraft: node["isDraft"].bool, mergeable: mergeable, mergeStateStatus: mergeState, reviewDecision: review,
            checksState: checks, checksKnown: checksKnown,
            hasDirectReviewRequest: direct ? true : (complete && requestTypesKnown ? false : nil),
            readinessIsComplete: readyComplete, createdAt: node["createdAt"].string.flatMap(date),
            updatedAt: node["updatedAt"].string.flatMap(date),
            fetchedAt: now, observedStateSince: now,
            terminalObservedAt: state == "CLOSED" || state == "MERGED" ? now : nil,
            isStale: !readyComplete)
    }

    private static func reference(_ node: GraphQLValue) -> PullRequestReference? {
        guard let owner = node["repository"]["owner"]["login"].string, let repo = node["repository"]["name"].string,
            let number = node["number"].int, number > 0
        else { return nil }
        return .init(owner: owner, repository: repo, number: number)
    }
    private static func validConnection(_ connection: GraphQLValue) -> Bool {
        guard case .array = connection["nodes"] else { return false }
        return connection["pageInfo"]["hasNextPage"].bool != nil
    }
    private static func sameObservedState(_ a: PullRequestSnapshot, _ b: PullRequestSnapshot) -> Bool {
        a.state == b.state && a.isDraft == b.isDraft && a.mergeable == b.mergeable
            && a.mergeStateStatus == b.mergeStateStatus
            && a.reviewDecision == b.reviewDecision && a.checksState == b.checksState && a.checksKnown == b.checksKnown
            && a.hasDirectReviewRequest == b.hasDirectReviewRequest && a.readinessIsComplete == b.readinessIsComplete
    }
    private static func literal(_ string: String) -> String {
        // JSON string literals are also safe GraphQL string literals; never interpolate unescaped names.
        String(data: try! JSONEncoder().encode(string), encoding: .utf8)!
    }
    private static func date(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: string)
            ?? {
                formatter.formatOptions.insert(.withFractionalSeconds)
                return formatter.date(from: string)
            }()
    }
    private static func httpDate(_ string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: string)
    }
}
