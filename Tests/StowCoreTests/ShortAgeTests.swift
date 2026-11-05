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
}
