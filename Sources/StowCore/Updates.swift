import Foundation

/// A Semantic Versioning 2.0.0 version, such as `1.0.0-beta.2`; build metadata is dropped.
public struct ReleaseVersion: Hashable, Comparable, Sendable, CustomStringConvertible, Codable {
    public let major: Int
    public let minor: Int
    public let patch: Int
    /// The identifiers after `-`; empty for a release.
    public let prerelease: [String]

    /// Reads a version or a `v`-prefixed tag; nil for anything that isn't strict Semantic Versioning.
    public init?(_ text: String) {
        var rest = Substring(text)
        if rest.hasPrefix("v") { rest = rest.dropFirst() }
        if let plus = rest.firstIndex(of: "+") {
            guard Self.identifiers(rest[rest.index(after: plus)...]) != nil else { return nil }
            rest = rest[..<plus]
        }
        var prerelease: [String] = []
        if let dash = rest.firstIndex(of: "-") {
            guard let identifiers = Self.identifiers(rest[rest.index(after: dash)...]),
                identifiers.allSatisfy({ !Self.isNumber($0) || !Self.hasLeadingZero($0) })
            else { return nil }
            prerelease = identifiers.map(String.init)
            rest = rest[..<dash]
        }
        let numbers = rest.split(separator: ".", omittingEmptySubsequences: false)
        guard numbers.count == 3 else { return nil }
        var values: [Int] = []
        for number in numbers {
            guard Self.isNumber(number), !Self.hasLeadingZero(number), let value = Int(number) else { return nil }
            values.append(value)
        }
        major = values[0]
        minor = values[1]
        patch = values[2]
        self.prerelease = prerelease
    }

    public var description: String {
        let core = "\(major).\(minor).\(patch)"
        return prerelease.isEmpty ? core : core + "-" + prerelease.joined(separator: ".")
    }

    /// Semantic Versioning precedence: a pre-release comes before its release.
    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        if lhs.prerelease.isEmpty || rhs.prerelease.isEmpty { return !lhs.prerelease.isEmpty && rhs.prerelease.isEmpty }
        for (left, right) in zip(lhs.prerelease, rhs.prerelease) where left != right {
            switch (isNumber(left[...]), isNumber(right[...])) {
            // Without leading zeros, the longer number is larger.
            case (true, true):
                return left.utf8.count != right.utf8.count
                    ? left.utf8.count < right.utf8.count : left.utf8.lexicographicallyPrecedes(right.utf8)
            case (true, false): return true
            case (false, true): return false
            case (false, false): return left.utf8.lexicographicallyPrecedes(right.utf8)
            }
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }

    public init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let version = ReleaseVersion(text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not a version."))
        }
        self = version
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }

    /// Dot-separated identifiers of ASCII letters, digits, and hyphens, none empty.
    private static func identifiers(_ text: Substring) -> [Substring]? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        let valid = parts.allSatisfy { part in
            !part.isEmpty
                && part.utf8.allSatisfy { byte in
                    switch byte {
                    case UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
                        UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "-"):
                        return true
                    default: return false
                    }
                }
        }
        return valid ? parts : nil
    }

    private static func isNumber(_ text: Substring) -> Bool {
        !text.isEmpty && text.utf8.allSatisfy { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }
    }

    private static func hasLeadingZero(_ text: Substring) -> Bool {
        text.utf8.count > 1 && text.utf8.first == UInt8(ascii: "0")
    }
}

/// A published Stow release: its version, its page on github.com, and whether it's a pre-release.
public struct StowRelease: Codable, Equatable, Sendable {
    public let version: ReleaseVersion
    /// Always the source's page for this release's tag.
    public let page: URL
    /// Marked as a pre-release on GitHub, or carrying a pre-release version.
    public let isPrerelease: Bool

    /// Nil unless `page` is the source's page for `version`.
    public init?(version: ReleaseVersion, page: String, isPrerelease: Bool = false, source: ReleaseSource = .stow) {
        guard let url = source.releasePage(page, for: version) else { return nil }
        self.version = version
        self.page = url
        self.isPrerelease = isPrerelease || !version.prerelease.isEmpty
    }

    private enum CodingKeys: String, CodingKey { case version, page, isPrerelease }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(ReleaseVersion.self, forKey: .version)
        let prerelease = (try? container.decodeIfPresent(Bool.self, forKey: .isPrerelease)) ?? false
        guard
            let release = StowRelease(
                version: version, page: try container.decode(String.self, forKey: .page), isPrerelease: prerelease)
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .page, in: container, debugDescription: "Not a Stow release page.")
        }
        self = release
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(page.absoluteString, forKey: .page)
        try container.encode(isPrerelease, forKey: .isPrerelease)
    }
}

/// Where releases come from: a GitHub repository's release list and pages.
public struct ReleaseSource: Equatable, Sendable {
    public var owner: String
    public var repository: String

    public init(owner: String, repository: String) {
        self.owner = owner
        self.repository = repository
    }

    /// Stow's own releases.
    public static let stow = ReleaseSource(owner: "byanthny", repository: "stow")

    /// The ten most recent releases, newest first, pre-releases included.
    public var releasesURL: URL {
        URL(string: "https://api.github.com/repos/\(owner)/\(repository)/releases?per_page=10")!
    }

    /// A release's page is this followed by its tag; a release with any other page is ignored.
    public var releasePagePrefix: String { "https://github.com/\(owner)/\(repository)/releases/tag/" }

    /// The URL when `text` is `version`'s release page: `releasePagePrefix` and a tag naming that version.
    public func releasePage(_ text: String, for version: ReleaseVersion) -> URL? {
        guard text.utf8.starts(with: releasePagePrefix.utf8) else { return nil }
        let tag = String(decoding: text.utf8.dropFirst(releasePagePrefix.utf8.count), as: UTF8.self)
        guard ReleaseVersion(tag) == version else { return nil }
        return URL(string: text)
    }

    /// Releases from GitHub's list, skipping entries without a version tag or one of this source's pages.
    public func releases(from data: Data) throws -> [StowRelease] {
        guard let entries = try? JSONDecoder().decode([Entry].self, from: data) else {
            throw UpdateCheckError.unreadable
        }
        return entries.compactMap { entry in
            guard let tag = entry.tag, let version = ReleaseVersion(tag), let page = entry.page else { return nil }
            return StowRelease(version: version, page: page, isPrerelease: entry.prerelease ?? false, source: self)
        }
    }

    /// One listed release; a missing or mistyped field reads as nil.
    private struct Entry: Decodable {
        var tag: String?
        var page: String?
        var prerelease: Bool?

        private enum CodingKeys: String, CodingKey {
            case tag = "tag_name"
            case page = "html_url"
            case prerelease
        }

        init(from decoder: any Decoder) throws {
            let container = try? decoder.container(keyedBy: CodingKeys.self)
            tag = try? container?.decodeIfPresent(String.self, forKey: .tag)
            page = try? container?.decodeIfPresent(String.self, forKey: .page)
            prerelease = try? container?.decodeIfPresent(Bool.self, forKey: .prerelease)
        }
    }
}

/// When to check, and which releases to offer.
public struct UpdatePolicy: Equatable, Sendable {
    /// Automatic checks wait this long after the last one.
    public var interval: TimeInterval

    public init(interval: TimeInterval = 24 * 60 * 60) {
        self.interval = interval
    }

    public static let standard = UpdatePolicy()

    /// Whether `interval` has passed since the last check, or the clock was set back.
    public func isDue(lastCheck: Date?, now: Date) -> Bool {
        guard let lastCheck else { return true }
        let elapsed = now.timeIntervalSince(lastCheck)
        return elapsed >= interval || elapsed < 0
    }

    /// The newest release above the running version. Pre-releases count only until a stable release is out,
    /// in `releases` or, by `stableIsOut`, seen before.
    public func newest(
        _ releases: [StowRelease], above running: ReleaseVersion, stableIsOut: Bool = false
    ) -> StowRelease? {
        let stableIsOut = stableIsOut || releases.contains { !$0.isPrerelease }
        return releases.filter { (!stableIsOut || !$0.isPrerelease) && running < $0.version }
            .max { $0.version < $1.version }
    }
}

/// What one check found.
public enum UpdateOutcome: Equatable, Sendable {
    case available(StowRelease)
    case upToDate
    case failed(UpdateCheckError)
}

/// Settings → Updates, kept in the profile index for every profile, and what the last check found.
public struct UpdateSettings: Codable, Equatable, Sendable {
    /// Off until the person turns it on.
    public var checksForUpdates = false
    /// When the last successful check started.
    public var lastCheckAt: Date?
    /// The newest release the last check found above the version that ran it.
    public var available: StowRelease?
    /// The version whose notice was dismissed; a newer release shows again.
    public var dismissedVersion: ReleaseVersion?
    /// Set once a check finds a stable release; pre-releases aren't offered after that.
    public var sawStableRelease = false

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case checksForUpdates, lastCheckAt, available, dismissedVersion, sawStableRelease
    }

    /// A field that doesn't decode reads as its default.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        checksForUpdates = (try? container.decodeIfPresent(Bool.self, forKey: .checksForUpdates)) ?? false
        lastCheckAt = try? container.decodeIfPresent(Date.self, forKey: .lastCheckAt)
        available = try? container.decodeIfPresent(StowRelease.self, forKey: .available)
        dismissedVersion = try? container.decodeIfPresent(ReleaseVersion.self, forKey: .dismissedVersion)
        sawStableRelease = (try? container.decodeIfPresent(Bool.self, forKey: .sawStableRelease)) ?? false
    }

    /// The release to offer: newer than `running`, with checks on and its notice not dismissed.
    public func notice(running: ReleaseVersion) -> StowRelease? {
        guard checksForUpdates, let available, running < available.version else { return nil }
        if let dismissedVersion, !(dismissedVersion < available.version) { return nil }
        return available
    }

    /// Records a check that started at `time`. A failed check changes nothing.
    public mutating func record(
        _ result: Result<[StowRelease], UpdateCheckError>, running: ReleaseVersion, at time: Date,
        policy: UpdatePolicy = .standard
    ) -> UpdateOutcome {
        switch result {
        case .success(let releases):
            lastCheckAt = time
            sawStableRelease = sawStableRelease || releases.contains { !$0.isPrerelease }
            available = policy.newest(releases, above: running, stableIsOut: sawStableRelease)
            return available.map(UpdateOutcome.available) ?? .upToDate
        case .failure(let error):
            return .failed(error)
        }
    }
}

public enum UpdateCheckError: Error, LocalizedError, Equatable, Sendable {
    case unreachable, rateLimited, unavailable, tooLarge, unreadable, unknownVersion

    public var errorDescription: String? {
        switch self {
        case .unreachable: "Stow couldn’t reach GitHub. Check your connection, then try again."
        case .rateLimited: "GitHub is limiting requests from this network. Try again later."
        case .unavailable: "GitHub didn’t return Stow’s releases. Try again later."
        case .tooLarge: "GitHub’s reply was too large to read."
        case .unreadable: "GitHub’s reply couldn’t be read."
        case .unknownVersion: "Stow couldn’t read its own version."
        }
    }
}
