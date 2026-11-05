import XCTest

@testable import StowCore

final class WebLinkTests: XCTestCase {
    func testOnlyHTTPAndHTTPSLinksWithAHostCount() throws {
        let cases: [(String, Bool)] = [
            ("https://example.com/docs", true),
            ("HTTP://EXAMPLE.COM", true),
            ("https://", false),
            ("http:example.com", false),
            ("file:///etc/hosts", false),
            ("javascript:alert(1)", false),
            ("mailto:team@example.com", false),
            ("ftp://example.com", false),
        ]
        for (text, isWebLink) in cases {
            XCTAssertEqual(try XCTUnwrap(URL(string: text)).isWebLink, isWebLink, text)
        }
    }
}
