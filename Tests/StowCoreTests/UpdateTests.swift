import Foundation
import XCTest

@testable import StowCore

final class UpdateTests: XCTestCase {
    private let pages = "https://github.com/byanthny/stow/releases/tag/"

    override func setUp() {
        StubReplies.shared.reset()
    }

    // MARK: versions

    func testVersionsReadReleaseTags() throws {
        let cases: [(tag: String, numbers: [Int], prerelease: [String], text: String)] = [
            ("v0.2.1", [0, 2, 1], [], "0.2.1"),
            ("0.2.1", [0, 2, 1], [], "0.2.1"),
            ("v1.0.0-beta.2", [1, 0, 0], ["beta", "2"], "1.0.0-beta.2"),
            ("10.20.30-rc.1+build.7", [10, 20, 30], ["rc", "1"], "10.20.30-rc.1"),
            ("1.0.0-x-y.--", [1, 0, 0], ["x-y", "--"], "1.0.0-x-y.--"),
        ]
        for (tag, numbers, prerelease, text) in cases {
            let version = try XCTUnwrap(ReleaseVersion(tag), tag)
            XCTAssertEqual([version.major, version.minor, version.patch], numbers, tag)
            XCTAssertEqual(version.prerelease, prerelease, tag)
            XCTAssertEqual(version.description, text, tag)
        }
    }

    func testVersionsRejectMalformedTags() {
        for tag in [
            "", "v", "untagged-1a2b3c", "1", "1.2", "1.2.3.4", "01.2.3", "1.02.3", "1.2.03", "-1.2.3", "1.2.-3",
            "vv1.2.3", " 1.2.3", "1.2.3\n", "1.2.3-", "1.2.3-beta..1", "1.2.3-beta.01", "1.2.3-be ta", "1.2.3-béta",
            "1.2.3+", "1.2.3+build..1", "\u{FF11}.2.3", "1.2.99999999999999999999",
        ] {
            XCTAssertNil(ReleaseVersion(tag), tag)
        }
    }

    func testVersionsOrderAsSemanticVersioning() throws {
        // The Semantic Versioning example, numbers that sort wrongly as text, and oversized pre-release numbers.
        let ascending = [
            [
                "1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta", "1.0.0-beta.2", "1.0.0-beta.11",
                "1.0.0-rc.1", "1.0.0",
            ],
            ["0.2.1", "0.2.9", "0.2.10", "0.10.0", "1.0.0"],
            ["1.0.0-alpha.9", "1.0.0-alpha.10", "1.0.0-alpha.99999999999999999999", "1.0.0-alpha.a"],
        ]
        for list in ascending {
            let versions = try list.map { try XCTUnwrap(ReleaseVersion($0), $0) }
            for (lower, higher) in zip(versions, versions.dropFirst()) {
                XCTAssertTrue(lower < higher, "\(lower) < \(higher)")
                XCTAssertFalse(higher < lower, "\(higher) < \(lower)")
            }
        }
        XCTAssertEqual(ReleaseVersion("v1.0.0+build.1"), ReleaseVersion("1.0.0+build.2"))
    }

    // MARK: releases

    func testReleasesKeepOnlyVersionedStowPages() throws {
        let list = [
            entry(tag: "v0.3.0", page: pages + "v0.3.0"),
            entry(tag: "nightly", page: pages + "nightly"),
            entry(tag: "v9.0.0", page: "https://github.com/example/stow/releases/tag/v9.0.0"),
            entry(tag: "v9.1.0", page: "https://example.com/byanthny/stow/releases/tag/v9.1.0"),
            #"{"tag_name":"v9.2.0","prerelease":false}"#,
            #"{"tag_name":7,"html_url":"https://github.com/byanthny/stow/releases/tag/v9.3.0"}"#,
            entry(tag: "v0.2.1", page: pages + "v0.2.1", prerelease: false),
        ]
        let releases = try UpdateCheck.releases(from: Data("[\(list.joined(separator: ","))]".utf8))
        XCTAssertEqual(releases.map(\.version.description), ["0.3.0", "0.2.1"])
        XCTAssertEqual(releases.map(\.page.absoluteString), [pages + "v0.3.0", pages + "v0.2.1"])
    }

    func testRepliesThatAreNotAListAreUnreadable() throws {
        for reply in [#"{"message":"Not Found"}"#, "not json", ""] {
            XCTAssertThrowsError(try UpdateCheck.releases(from: Data(reply.utf8)), reply) {
                XCTAssertEqual($0 as? UpdateCheckError, .unreadable, reply)
            }
        }
        XCTAssertEqual(try UpdateCheck.releases(from: Data("[]".utf8)), [])
    }

    func testReleasePagesStayUnderStowReleases() {
        for page in [pages + "v0.2.1", pages + "v1.0.0-beta.2"] {
            XCTAssertEqual(UpdateCheck.releasePage(page)?.absoluteString, page)
        }
        for page in [
            "http://github.com/byanthny/stow/releases/tag/v1.0.0",
            "https://github.com/byanthny/stow-fork/releases/tag/v1.0.0",
            "https://github.com.example.net/byanthny/stow/releases/tag/v1.0.0",
            "https://github.com/byanthny/stow/releases",
            "https://github.com/byanthny/stow/releases/",
            "https://github.com/byanthny/stow/releases/../../example/repo",
            "https://github.com/byanthny/stow/releases/tag/../../../example",
            "https://github.com/byanthny/stow/releases/%2e%2e/%2e%2e/example",
            "https://github.com/byanthny/stow/releases/tag/v1.0.0?return=https://example.com",
            "https://github.com/byanthny/stow/releases/tag/v1.0.0#top",
            "https://github.com/byanthny/stow/releases/tag/v1 0",
            "https://github.com/byanthny/stow/releases/tag/v1.0.0\n",
        ] {
            XCTAssertNil(UpdateCheck.releasePage(page), page)
        }
    }

    func testNewestReleaseAboveRunningVersionIncludesPrereleases() throws {
        let releases = try ["v0.2.0", "v0.3.0-beta.1", "v0.2.1", "v0.3.0-alpha.2"].map(release)
        func newest(above running: String) throws -> String? {
            UpdateCheck.newest(releases, above: try XCTUnwrap(ReleaseVersion(running)))?.version.description
        }
        XCTAssertEqual(try newest(above: "0.2.1"), "0.3.0-beta.1")
        XCTAssertEqual(try newest(above: "0.1.0"), "0.3.0-beta.1")
        XCTAssertEqual(try newest(above: "0.3.0-alpha.2"), "0.3.0-beta.1")
        XCTAssertNil(try newest(above: "0.3.0-beta.1"))
        XCTAssertNil(try newest(above: "0.3.0"))
    }

    func testChecksAreDueOnceADay() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(UpdateCheck.isDue(lastCheck: nil, now: now))
        XCTAssertFalse(UpdateCheck.isDue(lastCheck: now, now: now))
        XCTAssertFalse(UpdateCheck.isDue(lastCheck: now.addingTimeInterval(-86_399), now: now))
        XCTAssertTrue(UpdateCheck.isDue(lastCheck: now.addingTimeInterval(-86_400), now: now))
        // A clock set back never postpones the next check by more than a day.
        XCTAssertTrue(UpdateCheck.isDue(lastCheck: now.addingTimeInterval(3_600), now: now))
    }

    // MARK: settings

    func testUpdateSettingsAreOffUntilTurnedOn() throws {
        XCTAssertFalse(ProfileIndex().updates.checksForUpdates)
        let saved = try ProfileIndex.decode(Data(#"{"schemaVersion":1,"order":[]}"#.utf8))
        XCTAssertEqual(saved.updates, UpdateSettings())
        XCTAssertFalse(saved.updates.checksForUpdates)
    }

    func testUpdateSettingsRoundTripThroughTheIndex() throws {
        var index = ProfileIndex()
        index.updates.checksForUpdates = true
        index.updates.lastCheckAt = Date(timeIntervalSince1970: 1_800_000_000)
        index.updates.available = try release("v0.3.0")
        index.updates.dismissedVersion = ReleaseVersion("0.2.9")
        XCTAssertEqual(try ProfileIndex.decode(JSONEncoder().encode(index)).updates, index.updates)
    }

    func testDamagedUpdateSettingsLeaveTheIndexReadable() throws {
        let damaged = try ProfileIndex.decode(
            Data(
                #"""
                {"schemaVersion":1,"alwaysShowProfileName":true,"updates":{"checksForUpdates":"yes",
                "available":{"version":"v9.0.0","page":"https://example.com/x"},"dismissedVersion":7}}
                """#.utf8))
        XCTAssertTrue(damaged.alwaysShowProfileName)
        XCTAssertEqual(damaged.updates, UpdateSettings())
        let wrongShape = try ProfileIndex.decode(Data(#"{"schemaVersion":1,"updates":[]}"#.utf8))
        XCTAssertEqual(wrongShape.updates, UpdateSettings())
        // A saved release must still pass the page check.
        let offSite = try ProfileIndex.decode(
            Data(
                #"""
                {"schemaVersion":1,"updates":{"checksForUpdates":true,"available":{"version":"9.0.0",
                "page":"https://example.com/byanthny/stow/releases/tag/v9.0.0"}}}
                """#.utf8))
        XCTAssertTrue(offSite.updates.checksForUpdates)
        XCTAssertNil(offSite.updates.available)
    }

    func testNoticeShowsANewerReleaseWhileOnUntilDismissed() throws {
        let running = try XCTUnwrap(ReleaseVersion("0.2.1"))
        var settings = UpdateSettings()
        settings.available = try release("v0.3.0")
        XCTAssertNil(settings.notice(running: running), "The setting is off")
        settings.checksForUpdates = true
        XCTAssertEqual(settings.notice(running: running)?.version.description, "0.3.0")
        settings.dismissedVersion = ReleaseVersion("0.3.0")
        XCTAssertNil(settings.notice(running: running))
        settings.available = try release("v0.3.1")
        XCTAssertEqual(settings.notice(running: running)?.version.description, "0.3.1")
        // Once this Mac runs that release, or a later one, there is nothing to offer.
        XCTAssertNil(settings.notice(running: try XCTUnwrap(ReleaseVersion("0.3.1"))))
    }

    // MARK: request

    func testRequestAndSessionCarryNoCredentialsOrCookies() {
        let request = UpdateCheck.request()
        XCTAssertEqual(request.url?.absoluteString, "https://api.github.com/repos/byanthny/stow/releases?per_page=10")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertFalse(request.httpShouldHandleCookies)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        // The default agent names this Mac's macOS and CFNetwork versions.
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "Stow")
        let configuration = UpdateCheck.sessionConfiguration()
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertNil(configuration.urlCache)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertEqual(configuration.httpCookieAcceptPolicy, .never)
        XCTAssertLessThanOrEqual(configuration.timeoutIntervalForResource, 60)
    }

    func testFetchReadsReleasesWithoutCredentials() async throws {
        StubReplies.shared.reply = .init(
            status: 200, body: Data("[\(entry(tag: "v0.3.0", page: pages + "v0.3.0"))]".utf8))
        let releases = try await UpdateCheck.fetchReleases(configuration: stubbed())
        XCTAssertEqual(releases.map(\.version.description), ["0.3.0"])
        let requests = StubReplies.shared.requests
        XCTAssertEqual(requests.count, 1)
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.github.com/repos/byanthny/stow/releases?per_page=10")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
    }

    func testFetchReportsRefusalsAsErrors() async throws {
        let cases: [(Int, UpdateCheckError)] = [
            (403, .rateLimited), (429, .rateLimited), (404, .unavailable), (500, .unavailable),
        ]
        for (status, expected) in cases {
            // A body that would parse must not count when GitHub refuses.
            StubReplies.shared.reply = .init(status: status, body: Data("[]".utf8))
            do {
                _ = try await UpdateCheck.fetchReleases(configuration: stubbed())
                XCTFail("HTTP \(status) must fail")
            } catch {
                XCTAssertEqual(error as? UpdateCheckError, expected, "HTTP \(status)")
            }
        }
    }

    func testFetchStopsReadingPastTheSizeLimit() async throws {
        let limit = UpdateCheck.maximumResponseBytes
        // A list padded to exactly the limit is read.
        let padded = "[" + String(repeating: " ", count: limit - 2) + "]"
        StubReplies.shared.reply = .init(status: 200, body: Data(padded.utf8))
        let releases = try await UpdateCheck.fetchReleases(configuration: stubbed())
        XCTAssertEqual(releases, [])
        StubReplies.shared.reply = .init(
            status: 200, body: Data(("[" + String(repeating: " ", count: limit - 1) + "]").utf8))
        do {
            _ = try await UpdateCheck.fetchReleases(configuration: stubbed())
            XCTFail("A reply over the limit must fail")
        } catch {
            XCTAssertEqual(error as? UpdateCheckError, .tooLarge)
        }
    }

    // MARK: helpers

    private func release(_ tag: String) throws -> StowRelease {
        let version = try XCTUnwrap(ReleaseVersion(tag), tag)
        return try XCTUnwrap(StowRelease(version: version, page: pages + tag), tag)
    }

    /// One release as GitHub lists it, with synthetic values in the fields Stow does not read.
    private func entry(tag: String, page: String, prerelease: Bool = true) -> String {
        """
        {"url":"https://api.github.com/repos/byanthny/stow/releases/1",\
        "assets_url":"https://api.github.com/repos/byanthny/stow/releases/1/assets",\
        "upload_url":"https://uploads.github.com/repos/byanthny/stow/releases/1/assets{?name,label}",\
        "html_url":"\(page)","id":1,"author":{"login":"example-maintainer","id":1,"type":"User","site_admin":false},\
        "node_id":"RE_synthetic","tag_name":"\(tag)","target_commitish":"main","name":"Stow \(tag)",\
        "draft":false,"immutable":false,"prerelease":\(prerelease),"created_at":"2026-11-04T12:00:00Z",\
        "updated_at":"2026-11-04T12:00:00Z","published_at":"2026-11-04T12:00:00Z","assets":[],\
        "tarball_url":"https://api.github.com/repos/byanthny/stow/tarball/\(tag)",\
        "zipball_url":"https://api.github.com/repos/byanthny/stow/zipball/\(tag)","body":"Synthetic release notes."}
        """
    }

    /// The update check's own session settings, answered by `StubProtocol` instead of the network.
    private func stubbed() -> URLSessionConfiguration {
        let configuration = UpdateCheck.sessionConfiguration()
        configuration.protocolClasses = [StubProtocol.self]
        return configuration
    }
}

/// What `StubProtocol` answers, and the requests it saw. Tests in one class run one at a time.
private final class StubReplies: @unchecked Sendable {
    struct Reply {
        var status: Int
        var body: Data
    }

    static let shared = StubReplies()
    private let lock = NSLock()
    private var storedReply = Reply(status: 500, body: Data())
    private var storedRequests: [URLRequest] = []

    var reply: Reply {
        get { locked { storedReply } }
        set { locked { storedReply = newValue } }
    }

    var requests: [URLRequest] { locked { storedRequests } }

    func reset() {
        locked {
            storedReply = Reply(status: 500, body: Data())
            storedRequests = []
        }
    }

    fileprivate func answer(_ request: URLRequest) -> Reply {
        locked {
            storedRequests.append(request)
            return storedReply
        }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

/// Answers every request from `StubReplies`, so no test reaches the network.
private final class StubProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let reply = StubReplies.shared.answer(request)
        guard let url = request.url,
            let response = HTTPURLResponse(
                url: url, statusCode: reply.status, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json; charset=utf-8"])
        else { return client?.urlProtocol(self, didFailWithError: URLError(.badURL)) ?? () }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
