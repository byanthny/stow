import Foundation
import StowExtensionSDK

public struct PullRequestReference: Codable, Hashable, Sendable, Identifiable {
    public var host: String
    public var owner: String
    public var repository: String
    public var number: Int
    public var id: String { "\(host.lowercased())/\(owner.lowercased())/\(repository.lowercased())/\(number)" }
    public var url: URL { URL(string: "https://\(host)/\(owner)/\(repository)/pull/\(number)")! }
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

public struct PullRequestDetails: Codable, Equatable, Sendable {
    public var checks: [CheckSummary]
    public var reviews: [ReviewSummary]
    public var unresolvedThreadCount: Int?
    public var latestComment: String?
    public var latestCommentAuthor: String?
    public var fetchedAt: Date
    public var isComplete: Bool
    public init(
        checks: [CheckSummary] = [], reviews: [ReviewSummary] = [], unresolvedThreadCount: Int? = nil,
        latestComment: String? = nil, latestCommentAuthor: String? = nil, fetchedAt: Date = .now,
        isComplete: Bool = true
    ) {
        self.checks = checks
        self.reviews = reviews
        self.unresolvedThreadCount = unresolvedThreadCount
        self.latestComment = latestComment
        self.latestCommentAuthor = latestCommentAuthor
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

public struct AppState: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public var schemaVersion: Int = currentVersion
    public var notes: [Note] = []
    public var pins: [PullRequestReference] = []
    public var dismissedIDs: [String] = []
    public var pullRequests: [PullRequestSnapshot] = []
    public var boardFrame: WindowFrame?
    public var githubEnabled: Bool = true
    public var ghExecutablePath: String?
    public var viewerLogin: String?
    public var lastRefreshAt: Date?
    public var extensionInstances: [ExtensionInstanceState] = []
    public var appearance: AppearanceSettings = .default
    public var collapsedSections: [String] = []
    public init() {}

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, notes, pins, dismissedIDs, pullRequests, boardFrame, githubEnabled
        case ghExecutablePath, viewerLogin, lastRefreshAt, extensionInstances, appearance, collapsedSections
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
        githubEnabled = try container.decode(Bool.self, forKey: .githubEnabled)
        ghExecutablePath = try container.decodeIfPresent(String.self, forKey: .ghExecutablePath)
        viewerLogin = try container.decodeIfPresent(String.self, forKey: .viewerLogin)
        lastRefreshAt = try container.decodeIfPresent(Date.self, forKey: .lastRefreshAt)
        extensionInstances = try container.decode([ExtensionInstanceState].self, forKey: .extensionInstances)
        appearance = try container.decodeIfPresent(AppearanceSettings.self, forKey: .appearance) ?? .default
        collapsedSections = try container.decodeIfPresent([String].self, forKey: .collapsedSections) ?? []
    }
}
