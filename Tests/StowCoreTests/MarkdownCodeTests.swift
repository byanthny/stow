import Foundation
import XCTest

@testable import StowCore

final class MarkdownCodeTests: XCTestCase {
    /// Each span as the text it covers, so expectations read like the note.
    private func code(_ source: String) -> [String] {
        MarkdownCode.spans(in: source).map { (source as NSString).substring(with: $0.range) }
    }

    private func kinds(_ source: String) -> [MarkdownCode.Kind] { MarkdownCode.spans(in: source).map(\.kind) }

    func testFencedBlockWithInfoStringAndInlineCodeAfterIt() {
        let source = "Before the meeting:\n```swift\nlet x = `1`\n```\nThen run `swift test`."
        XCTAssertEqual(code(source), ["```swift\nlet x = `1`\n```\n", "`swift test`"])
        XCTAssertEqual(kinds(source), [.block, .inline])
    }

    func testTildeFenceClosesWithALongerFenceOfTheSameCharacter() {
        XCTAssertEqual(code("~~~\n```\nstill code\n~~~~\nafter"), ["~~~\n```\nstill code\n~~~~\n"])
    }

    func testUnclosedFenceRunsToTheEnd() {
        XCTAssertEqual(code("Intro\n```\nunfinished `code"), ["```\nunfinished `code"])
    }

    func testFenceNeedsThreeCharactersAndAtMostThreeSpaces() {
        XCTAssertEqual(kinds("``\nnot a fence\n``"), [.inline])
        XCTAssertEqual(code("   ```\nindented fence\n   ```"), ["   ```\nindented fence\n   ```"])
        XCTAssertEqual(kinds("   ```\nindented fence\n   ```"), [.block])
    }

    func testBacktickInTheInfoStringMeansNoFence() {
        XCTAssertEqual(code("``` a`b\nplain"), [])
    }

    func testClosingFenceAllowsOnlyTrailingSpaces() {
        XCTAssertEqual(code("```\ncode\n``` not closed\n```  \nafter"), ["```\ncode\n``` not closed\n```  \n"])
    }

    func testInlineRunsMatchByLength() {
        XCTAssertEqual(code("Use ``a ` b`` here"), ["``a ` b``"])
        XCTAssertEqual(code("one ` alone"), [])
        XCTAssertEqual(code("``open` only"), [])
    }

    func testInlineCodeStaysInsideItsParagraph() {
        XCTAssertEqual(code("`a\nb`"), ["`a\nb`"])
        XCTAssertEqual(code("`a\n\nb`"), [])
    }

    func testEscapedBacktickIsPlainText() {
        XCTAssertEqual(code("\\`not code` here"), [])
    }

    func testRangesCountUTF16AndWindowsLineEndings() {
        let source = "café `🙂` ok\r\n\r\n```\r\nx\r\n```\r\nend"
        XCTAssertEqual(code(source), ["`🙂`", "```\r\nx\r\n```\r\n"])
        XCTAssertEqual(MarkdownCode.spans(in: source).first?.range, NSRange(location: 5, length: 4))
    }

    func testTextWithoutCodeHasNoSpans() {
        XCTAssertEqual(MarkdownCode.spans(in: ""), [])
        XCTAssertEqual(MarkdownCode.spans(in: "# Plain note\n\n- one\n- two"), [])
    }
}
