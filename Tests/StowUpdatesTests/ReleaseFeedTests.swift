import Foundation
import StowCore
import XCTest

@testable import StowUpdates

final class ReleaseFeedTests: XCTestCase {
    private let pages = "https://github.com/byanthny/stow/releases/tag/"

    override func setUp() {
        StubReplies.shared.reset()
    }

    func testRequestAndSessionCarryNoCredentialsOrCookies() {
        let request = ReleaseFeed.request()
        XCTAssertEqual(request.url?.absoluteString, "https://api.github.com/repos/byanthny/stow/releases?per_page=10")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertFalse(request.httpShouldHandleCookies)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        // The default agent names this Mac's macOS and CFNetwork versions.
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "Stow")
        let configuration = ReleaseFeed.sessionConfiguration()
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
        let releases = try await ReleaseFeed.fetchReleases(configuration: stubbed())
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
                _ = try await ReleaseFeed.fetchReleases(configuration: stubbed())
                XCTFail("HTTP \(status) must fail")
            } catch {
                XCTAssertEqual(error as? UpdateCheckError, expected, "HTTP \(status)")
            }
        }
    }

    func testFetchStopsReadingPastTheSizeLimit() async throws {
        let limit = ReleaseFeed.maximumResponseBytes
        // A list padded to exactly the limit is read.
        let padded = "[" + String(repeating: " ", count: limit - 2) + "]"
        StubReplies.shared.reply = .init(status: 200, body: Data(padded.utf8))
        let releases = try await ReleaseFeed.fetchReleases(configuration: stubbed())
        XCTAssertEqual(releases, [])
        StubReplies.shared.reply = .init(
            status: 200, body: Data(("[" + String(repeating: " ", count: limit - 1) + "]").utf8))
        do {
            _ = try await ReleaseFeed.fetchReleases(configuration: stubbed())
            XCTFail("A reply over the limit must fail")
        } catch {
            XCTAssertEqual(error as? UpdateCheckError, .tooLarge)
        }
    }

    func testFetchAsksTheGivenSource() async throws {
        let source = ReleaseSource(owner: "example", repository: "app")
        let page = "https://github.com/example/app/releases/tag/v1.0.0"
        StubReplies.shared.reply = .init(status: 200, body: Data("[\(entry(tag: "v1.0.0", page: page))]".utf8))
        let releases = try await ReleaseFeed.fetchReleases(from: source, configuration: stubbed())
        XCTAssertEqual(releases.map(\.page.absoluteString), [page])
        XCTAssertEqual(
            StubReplies.shared.requests.first?.url?.absoluteString,
            "https://api.github.com/repos/example/app/releases?per_page=10")
    }

    // MARK: helpers

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
        let configuration = ReleaseFeed.sessionConfiguration()
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
