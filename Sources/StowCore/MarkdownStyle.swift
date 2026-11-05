import Foundation

/// Ranges of a note's Markdown to style while it is edited, in UTF-16 offsets as `NSString` counts them.
public enum MarkdownStyle {
    public enum Kind: Equatable, Sendable {
        /// The note's first line, shown as its title.
        case title
        case heading(level: Int)
        case bold, italic, strikethrough
        /// Inline code or a fenced block.
        case code
        /// A link's visible text. Only http and https URLs count.
        case link(URL)
        case quote
        /// Markdown syntax, shown dimmed but kept.
        case marker
    }

    public struct Span: Equatable, Sendable {
        public var kind: Kind
        public var range: NSRange

        public init(kind: Kind, range: NSRange) {
            self.kind = kind
            self.range = range
        }
    }

    public static func spans(in source: String) -> [Span] {
        let text = source as NSString
        let codeSpans = MarkdownCode.spans(in: source)
        let blocks = codeSpans.filter { $0.kind == .block }.map(\.range)
        let code = codeSpans.map(\.range)
        var spans = code.map { Span(kind: .code, range: $0) }
        if let title = titleLine(in: text, outside: blocks) { spans.append(Span(kind: .title, range: title)) }

        // Line styles: headings, quotes, and list markers. Lines inside fenced blocks stay code.
        text.enumerateSubstrings(
            in: NSRange(location: 0, length: text.length), options: [.byLines, .substringNotRequired]
        ) { _, line, _, _ in
            guard line.length > 0, !overlaps(line, blocks) else { return }
            if let match = headingPattern.firstMatch(in: source, range: line) {
                let marks = match.range(at: 1)
                spans.append(Span(kind: .heading(level: marks.length), range: line))
                spans.append(Span(kind: .marker, range: marks))
            } else if let match = quotePattern.firstMatch(in: source, range: line) {
                spans.append(Span(kind: .quote, range: line))
                spans.append(Span(kind: .marker, range: match.range(at: 1)))
            } else if let match = listPattern.firstMatch(in: source, range: line) {
                spans.append(Span(kind: .marker, range: match.range(at: 1)))
            }
        }

        // Inline styles, never inside code: the text between the marks, and the marks.
        let whole = NSRange(location: 0, length: text.length)
        func inline(_ pattern: NSRegularExpression, _ kind: Kind) {
            for match in pattern.matches(in: source, range: whole) where !overlaps(match.range, code) {
                spans.append(Span(kind: kind, range: match.range(at: 2)))
                spans.append(Span(kind: .marker, range: match.range(at: 1)))
                spans.append(Span(kind: .marker, range: match.range(at: 3)))
            }
        }
        inline(boldPattern, .bold)
        inline(strikePattern, .strikethrough)
        inline(starItalicPattern, .italic)
        inline(underscoreItalicPattern, .italic)

        for match in linkPattern.matches(in: source, range: whole) where !overlaps(match.range, code) {
            guard let url = URL(string: text.substring(with: match.range(at: 3))), url.isWebLink else { continue }
            let label = match.range(at: 2)
            spans.append(Span(kind: .link(url), range: label))
            spans.append(Span(kind: .marker, range: match.range(at: 1)))
            // "](url)" after the label.
            let tail = NSMaxRange(label)
            spans.append(Span(kind: .marker, range: NSRange(location: tail, length: NSMaxRange(match.range) - tail)))
        }
        for match in bareLinkPattern.matches(in: source, range: whole) where !overlaps(match.range, code) {
            guard let url = URL(string: text.substring(with: match.range)), url.isWebLink else { continue }
            spans.append(Span(kind: .link(url), range: match.range))
        }
        return spans
    }

    /// A note's title: its first line with text outside fenced code, without heading marks.
    public static func title(in source: String) -> String? {
        let text = source as NSString
        let blocks = MarkdownCode.spans(in: source).filter { $0.kind == .block }.map(\.range)
        guard let line = titleLine(in: text, outside: blocks) else { return nil }
        let title = text.substring(with: line).trimmingCharacters(in: .whitespaces).drop { $0 == "#" }
            .trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? nil : title
    }

    /// The first line with text outside fenced code blocks.
    private static func titleLine(in text: NSString, outside blocks: [NSRange]) -> NSRange? {
        var title: NSRange?
        text.enumerateSubstrings(
            in: NSRange(location: 0, length: text.length), options: [.byLines, .substringNotRequired]
        ) { _, line, _, stop in
            guard line.length > 0, !overlaps(line, blocks), !text.substring(with: line).allSatisfy(\.isWhitespace)
            else { return }
            title = line
            stop.pointee = true
        }
        return title
    }

    /// Whether `range` overlaps any of `ranges`, which are in order and apart, as code spans are.
    private static func overlaps(_ range: NSRange, _ ranges: [NSRange]) -> Bool {
        var low = 0
        var high = ranges.count
        while low < high {
            let middle = (low + high) / 2
            if NSMaxRange(ranges[middle]) <= range.location { low = middle + 1 } else { high = middle }
        }
        return range.length > 0 && low < ranges.count && ranges[low].location < NSMaxRange(range)
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // The patterns are constants, covered by the tests.
        try! NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
    }

    private static let headingPattern = regex(#"^ {0,3}(#{1,6})(?=[ \t]|$)"#)
    private static let quotePattern = regex(#"^ {0,3}(>)"#)
    private static let listPattern = regex(#"^[ \t]*([-*+]|\d{1,9}[.)])(?=[ \t])"#)
    private static let boldPattern = regex(#"(\*\*|__)(?=\S)((?:(?!\1)[^\n])+?)(?<=\S)(\1)"#)
    private static let strikePattern = regex(#"(~~)(?=\S)((?:(?!~~)[^\n])+?)(?<=\S)(~~)"#)
    private static let starItalicPattern = regex(#"(?<![*\w])(\*)(?=[^\s*])([^\n*]+?)(?<=[^\s*])(\*)(?![*\w])"#)
    private static let underscoreItalicPattern = regex(#"(?<![_\w])(_)(?=[^\s_])([^\n_]+?)(?<=[^\s_])(_)(?![_\w])"#)
    private static let linkPattern = regex(#"(\[)([^\[\]\n]+)\]\(([^()\[\]\s]+)\)"#)
    private static let bareLinkPattern = regex(#"(?<![\(<\[\w/])https?://[^\s<>()\[\]]+[^\s<>()\[\].,;:!?'"]"#)
}
