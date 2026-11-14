import Foundation
import StowExtensionSDK

public struct PullRequestReference: Codable, Hashable, Sendable, Identifiable {
    public var host: String
    public var owner: String
    public var repository: String
    public var number: Int
    public var id: String { "\(host.lowercased())/\(owner.lowercased())/\(repository.lowercased())/\(number)" }
    /// The pull request on github.com, the only host Stow reads, whatever `host` says.
    public var url: URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "github.com"
        components.path = "/\(owner)/\(repository)/pull/\(number)"
        return components.url ?? URL(string: "https://github.com")!
    }
    public var displayName: String { "\(owner)/\(repository) #\(number)" }
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }

    public init(host: String = "github.com", owner: String, repository: String, number: Int) {
        self.host = host
        self.owner = owner
        self.repository = repository
        self.number = number
    }
}

public struct WindowFrame: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct Note: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var markdown: String
    public var pullRequest: PullRequestReference?
    public var isDetached: Bool
    public var isAlwaysOnTop: Bool
    public var frame: WindowFrame?
    public var createdAt: Date
    public var updatedAt: Date
    public init(
        id: UUID = UUID(), markdown: String = "", pullRequest: PullRequestReference? = nil,
        isDetached: Bool = false, isAlwaysOnTop: Bool = true, frame: WindowFrame? = nil,
        createdAt: Date = .now, updatedAt: Date = .now
    ) {
        self.id = id
        self.markdown = markdown
        self.pullRequest = pullRequest
        self.isDetached = isDetached
        self.isAlwaysOnTop = isAlwaysOnTop
        self.frame = frame
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

extension Note {
    /// The note's title: its first line with text outside fenced code, without heading marks.
    public var title: String? { MarkdownStyle.title(in: markdown) }
}

public struct CheckSummary: Codable, Equatable, Sendable {
    public var name: String
    public var state: String
    public var url: URL?
    public init(name: String, state: String, url: URL? = nil) {
        self.name = name
        self.state = state
        self.url = url
    }
}

public struct ReviewSummary: Codable, Equatable, Sendable {
    public var author: String
    public var state: String
    public init(author: String, state: String) {
        self.author = author
        self.state = state
    }
}

public struct CommitSummary: Codable, Equatable, Sendable {
    /// The first line of the commit message.
    public var headline: String
    public var committedAt: Date?
    public init(headline: String, committedAt: Date? = nil) {
        self.headline = headline
        self.committedAt = committedAt
    }
}

public struct PullRequestDetails: Codable, Equatable, Sendable {
    public var checks: [CheckSummary]
    public var reviews: [ReviewSummary]
    public var unresolvedThreadCount: Int?
    public var latestComment: String?
    public var latestCommentAuthor: String?
    /// The last few commits, newest first. Nil in details cached before Stow fetched them.
    public var commits: [CommitSummary]?
    public var fetchedAt: Date
    public var isComplete: Bool
    public init(
        checks: [CheckSummary] = [], reviews: [ReviewSummary] = [], unresolvedThreadCount: Int? = nil,
        latestComment: String? = nil, latestCommentAuthor: String? = nil, commits: [CommitSummary]? = nil,
        fetchedAt: Date = .now, isComplete: Bool = true
    ) {
        self.checks = checks
        self.reviews = reviews
        self.unresolvedThreadCount = unresolvedThreadCount
        self.latestComment = latestComment
        self.latestCommentAuthor = latestCommentAuthor
        self.commits = commits
        self.fetchedAt = fetchedAt
        self.isComplete = isComplete
    }
}

/// GitHub enum strings are retained verbatim so future values never decode as a known safe state.
public struct PullRequestSnapshot: Codable, Equatable, Sendable, Identifiable {
    public var reference: PullRequestReference
    public var nodeID: String?
    public var title: String
    public var authorLogin: String?
    public var isViewerAuthor: Bool?
    public var state: String
    public var isDraft: Bool?
    public var mergeable: String?
    public var mergeStateStatus: String?
    public var reviewDecision: String?
    public var checksState: String?
    public var checksKnown: Bool
    public var hasDirectReviewRequest: Bool?
    public var readinessIsComplete: Bool
    public var createdAt: Date?
    public var updatedAt: Date?
    public var fetchedAt: Date
    public var observedStateSince: Date
    public var terminalObservedAt: Date?
    public var isUnavailable: Bool
    public var isStale: Bool
    public var details: PullRequestDetails?
    public var id: String { reference.id }
    public init(
        reference: PullRequestReference, title: String, nodeID: String? = nil,
        authorLogin: String? = nil, isViewerAuthor: Bool? = nil, state: String = "OPEN",
        isDraft: Bool? = nil, mergeable: String? = nil, mergeStateStatus: String? = nil,
        reviewDecision: String? = nil, checksState: String? = nil, checksKnown: Bool = false,
        hasDirectReviewRequest: Bool? = nil, readinessIsComplete: Bool = false,
        createdAt: Date? = nil, updatedAt: Date? = nil, fetchedAt: Date = .now,
        observedStateSince: Date = .now, terminalObservedAt: Date? = nil,
        isUnavailable: Bool = false, isStale: Bool = false, details: PullRequestDetails? = nil
    ) {
        self.reference = reference
        self.title = title
        self.nodeID = nodeID
        self.authorLogin = authorLogin
        self.isViewerAuthor = isViewerAuthor
        self.state = state
        self.isDraft = isDraft
        self.mergeable = mergeable
        self.mergeStateStatus = mergeStateStatus
        self.reviewDecision = reviewDecision
        self.checksState = checksState
        self.checksKnown = checksKnown
        self.hasDirectReviewRequest = hasDirectReviewRequest
        self.readinessIsComplete = readinessIsComplete
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.fetchedAt = fetchedAt
        self.observedStateSince = observedStateSince
        self.terminalObservedAt = terminalObservedAt
        self.isUnavailable = isUnavailable
        self.isStale = isStale
        self.details = details
    }
}

public struct ExtensionInstanceState: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var moduleID: String
    public var slot: AccessorySlot
    public var noteID: UUID?
    public var isEnabled: Bool
    public var configurationVersion: Int
    public var configuration: JSONValue
    public init(
        id: UUID = UUID(), moduleID: String, slot: AccessorySlot, noteID: UUID? = nil,
        isEnabled: Bool = false, configurationVersion: Int = 1, configuration: JSONValue = .object([:])
    ) {
        self.id = id
        self.moduleID = moduleID
        self.slot = slot
        self.noteID = noteID
        self.isEnabled = isEnabled
        self.configurationVersion = configurationVersion
        self.configuration = configuration
    }
}

/// The owners whose pull requests a profile shows. Empty means every owner.
public struct OwnerSelection: Codable, Equatable, Sendable {
    /// Unique ignoring case, sorted ignoring case, keeping the first spelling given.
    public private(set) var owners: [String]

    public init(_ owners: [String] = []) {
        var seen = Set<String>()
        self.owners = owners.filter { seen.insert($0.lowercased()).inserted }
            .sorted { $0.caseInsensitiveCompare($1) == .orderedAscending }
    }

    private enum CodingKeys: String, CodingKey { case owners }

    /// Saved state and backups are untrusted. An entry that isn't text, or that is empty or holds spaces, control or
    /// invisible characters, is dropped instead of rejecting the whole state. Any other name is kept, even one GitHub
    /// wouldn't accept today, so a damaged entry narrows the selection instead of widening it to every owner.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let entries = try container.decodeIfPresent([Entry].self, forKey: .owners) ?? []
        self.init(entries.compactMap(\.login).filter(Self.isSavedOwner))
    }

    /// One saved entry, which may not be text at all.
    private struct Entry: Decodable {
        let login: String?
        init(from decoder: any Decoder) throws { login = try? decoder.singleValueContainer().decode(String.self) }
    }

    /// An owner a profile can keep selected. Cards and pasted links can name older logins that end in a hyphen or
    /// repeat one, and managed users' logins with an underscore, so this is looser than Add owner…, which asks for a
    /// login GitHub accepts today (`isValidLogin`).
    private static func isSavedOwner(_ owner: String) -> Bool {
        let scalars = owner.unicodeScalars
        guard (1...100).contains(scalars.count) else { return false }
        return !scalars.contains { scalar in
            scalar.properties.isWhitespace || [.control, .format].contains(scalar.properties.generalCategory)
        }
    }

    public var isAll: Bool { owners.isEmpty }

    public func contains(_ owner: String) -> Bool {
        owners.contains { $0.caseInsensitiveCompare(owner) == .orderedSame }
    }

    /// A GitHub login: 1 to 39 ASCII letters, digits, or single hyphens, not at either end.
    public static func isValidLogin(_ login: String) -> Bool {
        let bytes = Array(login.utf8)
        guard (1...39).contains(bytes.count) else { return false }
        func isAlphanumeric(_ byte: UInt8) -> Bool {
            (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
        }
        guard isAlphanumeric(bytes[0]), isAlphanumeric(bytes[bytes.count - 1]) else { return false }
        for index in bytes.indices where !isAlphanumeric(bytes[index]) {
            guard bytes[index] == 0x2D, isAlphanumeric(bytes[index - 1]), isAlphanumeric(bytes[index + 1]) else {
                return false
            }
        }
        return true
    }
}

public struct AppState: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public var schemaVersion: Int = currentVersion
    public var notes: [Note] = []
    public var pins: [PullRequestReference] = []
    public var dismissedIDs: [String] = []
    public var pullRequests: [PullRequestSnapshot] = []
    public var boardFrame: WindowFrame?
    public var boardAlwaysOnTop: Bool = true
    public var githubEnabled: Bool = true
    public var ghExecutablePath: String?
    public var viewerLogin: String?
    public var lastRefreshAt: Date?
    public var extensionInstances: [ExtensionInstanceState] = []
    public var appearance: AppearanceSettings = .default
    public var collapsedSections: [String] = []
    public var boardLayout = BoardLayout()
    public var ownerSelection = OwnerSelection()
    public var keepsOnlySelectedOwners = false
    /// How long unpinned merged and closed cards stay. Older versions don't know it and drop it when they save.
    public var terminalCardKeepTime = TerminalCardKeepTime.default
    public var hideKeepsAlwaysOnTopNotes = false
    /// Switching to another profile hides this one. Read from the profile being left.
    public var hidesWhenSwitchingAway = true
    public init() {}

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, notes, pins, dismissedIDs, pullRequests, boardFrame, boardAlwaysOnTop, githubEnabled
        case ghExecutablePath, viewerLogin, lastRefreshAt, extensionInstances, appearance, collapsedSections
        case boardLayout, ownerSelection, keepsOnlySelectedOwners, hideKeepsAlwaysOnTopNotes, hidesWhenSwitchingAway
        case terminalCardKeepTime
    }

    public init(from decoder: any Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        notes = try container.decode([Note].self, forKey: .notes)
        pins = try container.decode([PullRequestReference].self, forKey: .pins)
        dismissedIDs = try container.decode([String].self, forKey: .dismissedIDs)
        pullRequests = try container.decode([PullRequestSnapshot].self, forKey: .pullRequests)
        boardFrame = try container.decodeIfPresent(WindowFrame.self, forKey: .boardFrame)
        boardAlwaysOnTop = try container.decodeIfPresent(Bool.self, forKey: .boardAlwaysOnTop) ?? true
        githubEnabled = try container.decode(Bool.self, forKey: .githubEnabled)
        ghExecutablePath = try container.decodeIfPresent(String.self, forKey: .ghExecutablePath)
        viewerLogin = try container.decodeIfPresent(String.self, forKey: .viewerLogin)
        lastRefreshAt = try container.decodeIfPresent(Date.self, forKey: .lastRefreshAt)
        extensionInstances = try container.decode([ExtensionInstanceState].self, forKey: .extensionInstances)
        appearance = try container.decodeIfPresent(AppearanceSettings.self, forKey: .appearance) ?? .default
        collapsedSections = try container.decodeIfPresent([String].self, forKey: .collapsedSections) ?? []
        boardLayout = try container.decodeIfPresent(BoardLayout.self, forKey: .boardLayout) ?? BoardLayout()
        ownerSelection = try container.decodeIfPresent(OwnerSelection.self, forKey: .ownerSelection) ?? OwnerSelection()
        keepsOnlySelectedOwners = try container.decodeIfPresent(Bool.self, forKey: .keepsOnlySelectedOwners) ?? false
        // A missing or unknown value keeps cards a day, as 0.3.0 did, rather than rejecting the state.
        let keepTimeName = try? container.decodeIfPresent(String.self, forKey: .terminalCardKeepTime)
        terminalCardKeepTime = keepTimeName.flatMap(TerminalCardKeepTime.init(rawValue:)) ?? .default
        hideKeepsAlwaysOnTopNotes =
            try container.decodeIfPresent(Bool.self, forKey: .hideKeepsAlwaysOnTopNotes) ?? false
        hidesWhenSwitchingAway = try container.decodeIfPresent(Bool.self, forKey: .hidesWhenSwitchingAway) ?? true
    }
}
