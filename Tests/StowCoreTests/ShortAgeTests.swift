import Foundation
import XCTest

@testable import StowCore

final class ShortAgeTests: XCTestCase {
    func testShortAgesStaySteady() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let english = Locale(identifier: "en_US")
        XCTAssertEqual(now.addingTimeInterval(-30).shortAge(relativeTo: now, locale: english), "just now")
        XCTAssertEqual(now.addingTimeInterval(-150).shortAge(relativeTo: now, locale: english), "2m ago")
        XCTAssertEqual(now.addingTimeInterval(-7_400).shortAge(relativeTo: now, locale: english), "2h ago")
        XCTAssertEqual(now.addingTimeInterval(-90_000).shortAge(relativeTo: now, locale: english), "1d ago")
    }

    func testEachLocaleKeepsOneFormatter() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let locale = Locale(identifier: "en_NZ")
        _ = now.addingTimeInterval(-150).shortAge(relativeTo: now, locale: locale)
        let formatter = try XCTUnwrap(ShortAge.formatters.cached(locale), "The first age kept no formatter")
        let then = now.addingTimeInterval(-7_400)
        XCTAssertEqual(
            then.shortAge(relativeTo: now, locale: locale),
            ShortAge.formatter(locale).localizedString(for: then, relativeTo: now))
        XCTAssertTrue(ShortAge.formatters.cached(locale) === formatter, "A second age made another formatter")
        XCTAssertEqual(formatter.locale, locale)
    }

    func testFormattersStayFewAndAgreeAcrossThreads() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let then = now.addingTimeInterval(-7_400)
        let locales = ["en_US", "fr_FR", "de_DE", "ja_JP", "es_ES", "it_IT", "pt_BR", "ko_KR", "nl_NL", "sv_SE"]
            .map(Locale.init(identifier:))
        let expected = locales.map { ShortAge.formatter($0).localizedString(for: then, relativeTo: now) }
        let mismatches = Mismatches()
        DispatchQueue.concurrentPerform(iterations: 400) { index in
            let age = then.shortAge(relativeTo: now, locale: locales[index % locales.count])
            if age != expected[index % locales.count] { mismatches.add(age) }
        }
        XCTAssertEqual(mismatches.ages, [])
        XCTAssertLessThanOrEqual(ShortAge.formatters.count, 8)
    }
}

/// Ages that differed from the expected ones, gathered from many threads.
private final class Mismatches: @unchecked Sendable {
    private let lock = NSLock()
    private var found: [String] = []
    var ages: [String] { lock.withLock { found } }
    func add(_ age: String) { lock.withLock { found.append(age) } }
}
