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

    func testLongLinesOfUnclosedMarksStyleQuickly() {
        for piece in ["**a ", "~~a ", "[", "[a](", "`a` **b** ", "```\nx\n```\n"] {
            let source = String(repeating: piece, count: 64_000 / piece.utf8.count)
            let start = Date.now
            _ = MarkdownStyle.spans(in: source)
            XCTAssertLessThan(Date.now.timeIntervalSince(start), 2, "\(piece.debugDescription) took too long")
        }
    }

    func testTypingRestylesOnlyItsLine() {
        let before = "# Title\n\nSome **bold** here\n\nPlain line\n"
        let after = "# Title\n\nSome **bold** here\n\nPlain xline\n"
        let range = changedRange(before, after, edited: NSRange(location: 35, length: 1), delta: 1)
        XCTAssertEqual((after as NSString).substring(with: range), "Plain xline\n")
    }

    func testOpeningAFenceRestylesTheLinesItCovers() {
        let before = "Title\n\nNot code\n**Also not code**\n"
        let after = "Title\n```\nNot code\n**Also not code**\n"
        let range = changedRange(before, after, edited: NSRange(location: 6, length: 3), delta: 3)
        XCTAssertEqual(NSMaxRange(range), (after as NSString).length)
        XCTAssertEqual(range.location, 6)
    }

    func testEditsLeaveStylesOutsideTheChangedRangeAsTheyWere() {
        var random = SplitMix(seed: 7)
        let pieces = ["*", "**", "_", "`", "```", "#", "# ", " ", "\n", "x", "> ", "- ", "[a](https://example.com)", "~~"]
        var text = "# Title\n\nSome **bold** and *it* text.\n```\ncode\n```\n> quote\n- item [a](https://example.com)\n"
        for step in 0..<600 {
            let source = text as NSString
            let location = Int.random(in: 0...source.length, using: &random)
            let removed = Int.random(in: 0...min(3, source.length - location), using: &random)
            let inserted = Bool.random(using: &random) ? pieces.randomElement(using: &random)! : ""
            let after = source.replacingCharacters(in: NSRange(location: location, length: removed), with: inserted)
            let insertedLength = (inserted as NSString).length
            let range = changedRange(
                text, after, edited: NSRange(location: location, length: insertedLength), delta: insertedLength - removed)
            let old = styles(text)
            let new = styles(after)
            for position in 0..<new.count where !NSLocationInRange(position, range) {
                let previous = position < location ? position : position - insertedLength + removed
                XCTAssertEqual(new[position], old[previous], "Step \(step) changed styles at \(position) outside \(range)")
            }
            text = after.count > 400 ? String(after.prefix(200)) : after
        }
    }

    private func changedRange(_ before: String, _ after: String, edited: NSRange, delta: Int) -> NSRange {
        MarkdownStyle.changedRange(
            from: MarkdownStyle.spans(in: before), to: MarkdownStyle.spans(in: after), in: after as NSString,
            edited: edited, delta: delta)
    }

    /// The kinds of span covering each UTF-16 offset of `source`.
    private func styles(_ source: String) -> [[String]] {
        var styles = Array(repeating: [String](), count: (source as NSString).length)
        for span in MarkdownStyle.spans(in: source) {
            for position in span.range.location..<NSMaxRange(span.range) { styles[position].append("\(span.kind)") }
        }
        return styles.map { $0.sorted() }
    }
}

/// A seeded generator, so a failing sequence of edits repeats.
private struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
