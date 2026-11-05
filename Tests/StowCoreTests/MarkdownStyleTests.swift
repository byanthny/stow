import Foundation
import XCTest

@testable import StowCore

final class MarkdownStyleTests: XCTestCase {
    /// The text each span of `kind` covers, in the order found.
    private func styled(_ source: String, _ kind: MarkdownStyle.Kind) -> [String] {
        MarkdownStyle.spans(in: source).filter { $0.kind == kind }
            .map { (source as NSString).substring(with: $0.range) }
    }

    private func markers(_ source: String) -> [String] { styled(source, .marker) }

    func testTheFirstLineWithTextIsTheTitle() {
        XCTAssertEqual(styled("Groceries\n\n- milk", .title), ["Groceries"])
        XCTAssertEqual(styled("\n  \nStandup notes\nmore", .title), ["Standup notes"])
        XCTAssertEqual(styled("", .title), [])
        XCTAssertEqual(styled("```\ncode first\n```", .title), [], "A fenced block is never the title")
    }

    func testOneTitleRuleForEditorRowsAndExports() {
        XCTAssertEqual(MarkdownStyle.title(in: "  ## Groceries  \n- milk"), "Groceries")
        XCTAssertEqual(MarkdownStyle.title(in: "```swift\nlet x = 1\n```\nAfter the code"), "After the code")
        XCTAssertNil(MarkdownStyle.title(in: "\n   \n"))
        XCTAssertNil(MarkdownStyle.title(in: "#"))
        XCTAssertEqual(Note(markdown: "```\ncode\n```\nPlan").title, "Plan")
    }

    func testHeadingsQuotesAndListMarkers() {
        let source = "# Title\n## Sub\n> quoted\n- one\n12. two\n#nospace"
        XCTAssertEqual(styled(source, .heading(level: 1)), ["# Title"])
        XCTAssertEqual(styled(source, .heading(level: 2)), ["## Sub"])
        XCTAssertEqual(styled(source, .quote), ["> quoted"])
        XCTAssertEqual(markers(source), ["#", "##", ">", "-", "12."])
    }

    func testInlineEmphasisStylesTheTextBetweenItsMarkers() {
        let source = "Some **bold**, *it*, _also_ and ~~gone~~ but not 2*3*4 or snake_case_name."
        XCTAssertEqual(styled(source, .bold), ["bold"])
        XCTAssertEqual(styled(source, .italic), ["it", "also"])
        XCTAssertEqual(styled(source, .strikethrough), ["gone"])
        XCTAssertEqual(markers(source), ["**", "**", "~~", "~~", "*", "*", "_", "_"])
    }

    func testNothingInsideCodeIsStyled() {
        let source = "Run `**not bold**` then:\n```\n# not a heading\n[x](https://example.com)\n```"
        XCTAssertEqual(styled(source, .bold), [])
        XCTAssertEqual(styled(source, .heading(level: 1)), [])
        XCTAssertEqual(MarkdownStyle.spans(in: source).filter { if case .link = $0.kind { true } else { false } }, [])
        XCTAssertEqual(styled(source, .code).count, 2)
    }

    func testLinksAreWebOnlyAndTheirSyntaxIsDimmed() throws {
        let source = "See [the site](https://example.com/docs) and https://example.org/a. Not [x](javascript:alert)."
        let links = MarkdownStyle.spans(in: source).compactMap { span -> (String, URL)? in
            guard case .link(let url) = span.kind else { return nil }
            return ((source as NSString).substring(with: span.range), url)
        }
        XCTAssertEqual(links.map(\.0), ["the site", "https://example.org/a"])
        XCTAssertEqual(links.map(\.1.absoluteString), ["https://example.com/docs", "https://example.org/a"])
        XCTAssertEqual(markers(source), ["[", "](https://example.com/docs)"])
    }
}
