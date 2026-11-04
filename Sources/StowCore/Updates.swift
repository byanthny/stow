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

/// A published Stow release: its version and its page on github.com.
public struct StowRelease: Codable, Equatable, Sendable {
    public let version: ReleaseVersion
    /// Always one of Stow's release pages.
    public let page: URL

    /// Nil unless `page` is one of Stow's release pages.
    public init?(version: ReleaseVersion, page: String) {
        guard let url = UpdateCheck.releasePage(page) else { return nil }
        self.version = version
        self.page = url
    }

    private enum CodingKeys: String, CodingKey { case version, page }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(ReleaseVersion.self, forKey: .version)
        guard let release = StowRelease(version: version, page: try container.decode(String.self, forKey: .page)) else {
            throw DecodingError.dataCorruptedError(
                forKey: .page, in: container, debugDescription: "Not a Stow release page.")
        }
        self = release
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(page.absoluteString, forKey: .page)
    }
}

/// Settings → Updates, kept in the profile index for every profile, and what the last check found.
public struct UpdateSettings: Codable, Equatable, Sendable {
    /// Off until the person turns it on.
    public var checksForUpdates = false
    public var lastCheckAt: Date?
    /// The newest release the last check found above the version that ran it.
    public var available: StowRelease?
    /// The version whose notice was dismissed; a newer release shows again.
    public var dismissedVersion: ReleaseVersion?

    public init() {}

    private enum CodingKeys: String, CodingKey { case checksForUpdates, lastCheckAt, available, dismissedVersion }

    /// A field that doesn't decode reads as its default.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        checksForUpdates = (try? container.decodeIfPresent(Bool.self, forKey: .checksForUpdates)) ?? false
        lastCheckAt = try? container.decodeIfPresent(Date.self, forKey: .lastCheckAt)
        available = try? container.decodeIfPresent(StowRelease.self, forKey: .available)
        dismissedVersion = try? container.decodeIfPresent(ReleaseVersion.self, forKey: .dismissedVersion)
    }

    /// The release to offer: newer than `running`, with checks on and its notice not dismissed.
    public func notice(running: ReleaseVersion) -> StowRelease? {
        guard checksForUpdates, let available, running < available.version else { return nil }
        if let dismissedVersion, !(dismissedVersion < available.version) { return nil }
        return available
    }
}

public enum UpdateCheckError: Error, LocalizedError, Equatable, Sendable {
    case unreachable, rateLimited, unavailable, tooLarge, unreadable

    public var errorDescription: String? {
        switch self {
        case .unreachable: "Stow couldn’t reach GitHub. Check your connection, then try again."
        case .rateLimited: "GitHub is limiting requests from this network. Try again later."
        case .unavailable: "GitHub didn’t return Stow’s releases. Try again later."
        case .tooLarge: "GitHub’s reply was too large to read."
        case .unreadable: "GitHub’s reply couldn’t be read."
        }
    }
}

/// The opt-in check for a newer Stow: one unauthenticated request to GitHub, with nothing downloaded.
public enum UpdateCheck {
    /// Stow's ten most recent releases, newest first, pre-releases included.
    public static let releasesURL = URL(string: "https://api.github.com/repos/byanthny/stow/releases?per_page=10")!
    /// Release pages start here; a release with any other page is ignored.
    public static let releasePagePrefix = "https://github.com/byanthny/stow/releases/"
    /// Replies longer than this are refused.
    public static let maximumResponseBytes = 1024 * 1024
    /// Automatic checks wait this long after the last one.
    public static let interval: TimeInterval = 24 * 60 * 60

    /// Whether a day has passed since the last check, or the clock was set back.
    public static func isDue(lastCheck: Date?, now: Date) -> Bool {
        guard let lastCheck else { return true }
        let elapsed = now.timeIntervalSince(lastCheck)
        return elapsed >= interval || elapsed < 0
    }

    /// The URL when `text` is a release page under `releasePagePrefix` with no dot segments, else nil.
    public static func releasePage(_ text: String) -> URL? {
        let prefix = releasePagePrefix.utf8
        guard text.utf8.starts(with: prefix) else { return nil }
        let path = text.utf8.dropFirst(prefix.count)
        let allowed = path.allSatisfy { byte in
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
                UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "_"),
                UInt8(ascii: "/"):
                return true
            default: return false
            }
        }
        guard !path.isEmpty, allowed else { return nil }
        let segments = String(decoding: path, as: UTF8.self).split(separator: "/", omittingEmptySubsequences: false)
        guard !segments.contains(where: { $0 == "." || $0 == ".." }) else { return nil }
        return URL(string: text)
    }

    /// Releases from GitHub's list, skipping entries without a version tag or a release page.
    public static func releases(from data: Data) throws -> [StowRelease] {
        guard let entries = try? JSONDecoder().decode([Entry].self, from: data) else {
            throw UpdateCheckError.unreadable
        }
        return entries.compactMap { entry in
            guard let tag = entry.tag, let version = ReleaseVersion(tag), let page = entry.page else { return nil }
            return StowRelease(version: version, page: page)
        }
    }

    /// The newest release above the running version, pre-releases included.
    public static func newest(_ releases: [StowRelease], above running: ReleaseVersion) -> StowRelease? {
        releases.filter { running < $0.version }.max { $0.version < $1.version }
    }

    /// A GET with fixed headers and no cookies or credentials.
    public static func request() -> URLRequest {
        var request = URLRequest(url: releasesURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Stow", forHTTPHeaderField: "User-Agent")
        request.setValue("en", forHTTPHeaderField: "Accept-Language")
        return request
    }

    /// An ephemeral session with no cookies, credentials, or cache.
    public static func sessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.waitsForConnectivity = false
        return configuration
    }

    /// Asks GitHub for Stow's releases and reads at most `maximumResponseBytes` of the reply.
    public static func fetchReleases(configuration: URLSessionConfiguration = sessionConfiguration()) async throws
        -> [StowRelease]
    {
        let session = URLSession(configuration: configuration)
        // Also stops a reply that runs past the limit.
        defer { session.invalidateAndCancel() }
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request())
        } catch {
            throw UpdateCheckError.unreachable
        }
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw UpdateCheckError.unreadable }
        switch status {
        case 200: break
        case 403, 429: throw UpdateCheckError.rateLimited
        default: throw UpdateCheckError.unavailable
        }
        var data = Data()
        do {
            for try await byte in bytes {
                guard data.count < maximumResponseBytes else { throw UpdateCheckError.tooLarge }
                data.append(byte)
            }
        } catch let error as UpdateCheckError {
            throw error
        } catch {
            throw UpdateCheckError.unreachable
        }
        return try releases(from: data)
    }

    /// One listed release; a missing or mistyped field reads as nil.
    private struct Entry: Decodable {
        var tag: String?
        var page: String?

        private enum CodingKeys: String, CodingKey {
            case tag = "tag_name"
            case page = "html_url"
        }

        init(from decoder: any Decoder) throws {
            let container = try? decoder.container(keyedBy: CodingKeys.self)
            tag = try? container?.decodeIfPresent(String.self, forKey: .tag)
            page = try? container?.decodeIfPresent(String.self, forKey: .page)
        }
    }
}
