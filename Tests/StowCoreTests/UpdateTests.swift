import Foundation
import XCTest

@testable import StowCore

final class UpdateTests: XCTestCase {
    private let pages = "https://github.com/byanthny/stow/releases/tag/"

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
            entry(tag: "v9.9.9", page: pages + "v0.1.0"),
            entry(tag: "v9.0.0", page: "https://github.com/example/stow/releases/tag/v9.0.0"),
            entry(tag: "v9.1.0", page: "https://example.com/byanthny/stow/releases/tag/v9.1.0"),
            #"{"tag_name":"v9.2.0","prerelease":false}"#,
            #"{"tag_name":7,"html_url":"https://github.com/byanthny/stow/releases/tag/v9.3.0"}"#,
            entry(tag: "v0.2.1", page: pages + "v0.2.1", prerelease: false),
        ]
        let releases = try ReleaseSource.stow.releases(from: Data("[\(list.joined(separator: ","))]".utf8))
        XCTAssertEqual(releases.map(\.version.description), ["0.3.0", "0.2.1"])
        XCTAssertEqual(releases.map(\.page.absoluteString), [pages + "v0.3.0", pages + "v0.2.1"])
    }

    func testRepliesThatAreNotAListAreUnreadable() throws {
        for reply in [#"{"message":"Not Found"}"#, "not json", ""] {
            XCTAssertThrowsError(try ReleaseSource.stow.releases(from: Data(reply.utf8)), reply) {
                XCTAssertEqual($0 as? UpdateCheckError, .unreadable, reply)
            }
        }
        XCTAssertEqual(try ReleaseSource.stow.releases(from: Data("[]".utf8)), [])
    }

    func testReleasesLinkOnlyToTheirOwnTagPage() throws {
        for (page, tag) in [(pages + "v0.2.1", "0.2.1"), (pages + "v1.0.0-beta.2", "1.0.0-beta.2"), (pages + "0.3.0", "0.3.0")] {
            let version = try XCTUnwrap(ReleaseVersion(tag))
            XCTAssertEqual(ReleaseSource.stow.releasePage(page, for: version)?.absoluteString, page)
        }
        let version = try XCTUnwrap(ReleaseVersion("1.0.0"))
        for page in [
            pages + "v0.1.0",
            "https://github.com/byanthny/stow/releases/download/v1.0.0/Stow-1.0.0.dmg",
            "https://github.com/byanthny/stow/releases/v1.0.0",
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
            "https://github.com/byanthny/stow/releases/tag/v1.0.0/",
        ] {
            XCTAssertNil(ReleaseSource.stow.releasePage(page, for: version), page)
        }
    }

    func testPrereleasesCountOnlyUntilAStableReleaseIsOut() throws {
        func newest(_ tags: [(String, Bool)], above running: String) throws -> String? {
            let releases = try tags.map { try release($0.0, prerelease: $0.1) }
            return UpdatePolicy.standard.newest(releases, above: try XCTUnwrap(ReleaseVersion(running)))?.version
                .description
        }
        // While every release is a pre-release, as during the alpha, the newest one is offered.
        let alpha = [("v0.2.0", true), ("v0.3.0-beta.1", true), ("v0.2.1", true), ("v0.3.0-alpha.2", true)]
        XCTAssertEqual(try newest(alpha, above: "0.2.1"), "0.3.0-beta.1")
        XCTAssertEqual(try newest(alpha, above: "0.3.0-alpha.2"), "0.3.0-beta.1")
        XCTAssertNil(try newest(alpha, above: "0.3.0-beta.1"))
        XCTAssertNil(try newest(alpha, above: "0.3.0"))
        // Once a stable release is out, only stable releases are offered.
        let stable = alpha + [("v0.3.0", false), ("v0.4.0", true), ("v0.4.0-rc.1", false)]
        XCTAssertEqual(try newest(stable, above: "0.2.1"), "0.3.0")
        XCTAssertNil(try newest(stable, above: "0.3.0"), "Pre-releases, by flag or by version, are not offered")
    }

    func testAnotherSourceKeepsToItsOwnPages() throws {
        let source = ReleaseSource(owner: "example", repository: "app")
        XCTAssertEqual(
            source.releasesURL.absoluteString, "https://api.github.com/repos/example/app/releases?per_page=10")
        let page = "https://github.com/example/app/releases/tag/v1.0.0"
        let version = try XCTUnwrap(ReleaseVersion("1.0.0"))
        XCTAssertEqual(source.releasePage(page, for: version)?.absoluteString, page)
        XCTAssertNil(source.releasePage(pages + "v1.0.0", for: version), "Stow's pages are not another source's")
        let list = "[\(entry(tag: "v1.0.0", page: page)),\(entry(tag: "v2.0.0", page: pages + "v2.0.0"))]"
        XCTAssertEqual(try source.releases(from: Data(list.utf8)).map(\.version.description), ["1.0.0"])
    }

    func testAStableReleaseOnceSeenKeepsPrereleasesAway() throws {
        let running = try XCTUnwrap(ReleaseVersion("1.0.0"))
        var settings = UpdateSettings()
        XCTAssertEqual(
            settings.record(.success([try release("v1.0.0")]), running: running, at: .now), .upToDate)
        // Ten betas later, GitHub's short list holds no stable release, and none is offered still.
        let betas = try (1...10).map { try release("v1.1.0-beta.\($0)", prerelease: true) }
        XCTAssertEqual(settings.record(.success(betas), running: running, at: .now), .upToDate)
        XCTAssertNil(settings.available)
        XCTAssertTrue(try JSONDecoder().decode(UpdateSettings.self, from: JSONEncoder().encode(settings)).sawStableRelease)
    }

    func testRecordingAChecksResult() throws {
        let running = try XCTUnwrap(ReleaseVersion("0.2.1"))
        let time = Date(timeIntervalSince1970: 1_800_000_000)
        var settings = UpdateSettings()
        let found = try release("v0.3.0", prerelease: true)
        XCTAssertEqual(settings.record(.success([found]), running: running, at: time), .available(found))
        XCTAssertEqual(settings.available, found)
        XCTAssertEqual(settings.lastCheckAt, time)
        // A failed check keeps offering what was found before.
        let later = time.addingTimeInterval(60)
        XCTAssertEqual(settings.record(.failure(.rateLimited), running: running, at: later), .failed(.rateLimited))
        XCTAssertEqual(settings.available, found)
        XCTAssertEqual(settings.lastCheckAt, time)
        // An empty list means up to date, and clears the old release.
        XCTAssertEqual(settings.record(.success([]), running: running, at: later), .upToDate)
        XCTAssertNil(settings.available)
        XCTAssertEqual(settings.lastCheckAt, later)
    }

    func testAFailedCheckLeavesTheNextOneDue() throws {
        let running = try XCTUnwrap(ReleaseVersion("0.2.1"))
        let time = Date(timeIntervalSince1970: 1_800_000_000)
        let hour: TimeInterval = 60 * 60
        var settings = UpdateSettings()
        // A first check that fails records nothing, so the hourly wake-up asks again.
        XCTAssertEqual(settings.record(.failure(.unreachable), running: running, at: time), .failed(.unreachable))
        XCTAssertEqual(settings, UpdateSettings())
        XCTAssertTrue(UpdatePolicy.standard.isDue(lastCheck: settings.lastCheckAt, now: time + hour))
        // A day after a check that worked, a failed one keeps that check's time, and the next wake-up asks again.
        XCTAssertEqual(settings.record(.success([]), running: running, at: time), .upToDate)
        let dayLater = time + UpdatePolicy.standard.interval
        XCTAssertEqual(settings.record(.failure(.rateLimited), running: running, at: dayLater), .failed(.rateLimited))
        XCTAssertEqual(settings.lastCheckAt, time)
        XCTAssertTrue(UpdatePolicy.standard.isDue(lastCheck: settings.lastCheckAt, now: dayLater + hour))
        // Once one works, the next is a day away.
        XCTAssertEqual(settings.record(.success([]), running: running, at: dayLater + hour), .upToDate)
        XCTAssertFalse(UpdatePolicy.standard.isDue(lastCheck: settings.lastCheckAt, now: dayLater + 2 * hour))
    }

    func testChecksAreDueOnceADay() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(UpdatePolicy.standard.isDue(lastCheck: nil, now: now))
        XCTAssertFalse(UpdatePolicy.standard.isDue(lastCheck: now, now: now))
        XCTAssertFalse(UpdatePolicy.standard.isDue(lastCheck: now.addingTimeInterval(-86_399), now: now))
        XCTAssertTrue(UpdatePolicy.standard.isDue(lastCheck: now.addingTimeInterval(-86_400), now: now))
        // A clock set back never postpones the next check by more than a day.
        XCTAssertTrue(UpdatePolicy.standard.isDue(lastCheck: now.addingTimeInterval(3_600), now: now))
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

    // MARK: helpers

    private func release(_ tag: String, prerelease: Bool = false) throws -> StowRelease {
        let version = try XCTUnwrap(ReleaseVersion(tag), tag)
        return try XCTUnwrap(StowRelease(version: version, page: pages + tag, isPrerelease: prerelease), tag)
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
}
