import Foundation

/// Finds the code in a note's Markdown source, so the editor can show it in a fixed-width font. The note itself stays
/// plain text: this only reports where code is.
public enum MarkdownCode {
    public enum Kind: Equatable, Sendable { case block, inline }

    public struct Span: Equatable, Sendable {
        public var kind: Kind
        /// UTF-16 offsets, as `NSString` and `NSTextStorage` count them. A block includes its fence lines.
        public var range: NSRange

        public init(kind: Kind, range: NSRange) {
            self.kind = kind
            self.range = range
        }
    }

    /// A fenced block opens with at least three backticks or tildes, indented by at most three spaces, and closes
    /// with a fence of the same character that is at least as long. A block with no closing fence runs to the end.
    /// Inline code is a run of backticks closed by a run of the same length in the same paragraph. Nothing inside a
    /// block counts as inline code.
    public static func spans(in source: String) -> [Span] {
        let units = Array(source.utf16)
        var spans: [Span] = []
        var fences = Fences()
        var blockStart = 0
        var paragraphStart: Int?

        func endParagraph(at end: Int) {
            if let start = paragraphStart { spans += inlineSpans(units, from: start, to: end) }
            paragraphStart = nil
        }

        forEachLine(in: units) { line, lineEnd in
            switch fences.read(units[line]) {
            case .opens:
                endParagraph(at: line.lowerBound)
                blockStart = line.lowerBound
            case .closes:
                spans.append(Span(kind: .block, range: NSRange(location: blockStart, length: lineEnd - blockStart)))
            case .inside: break
            case .outside:
                if line.allSatisfy({ units[$0] == space || units[$0] == tab }) {
                    endParagraph(at: line.lowerBound)
                } else if paragraphStart == nil {
                    paragraphStart = line.lowerBound
                }
            }
            return true
        }
        if fences.isOpen {
            spans.append(Span(kind: .block, range: NSRange(location: blockStart, length: units.count - blockStart)))
        } else {
            endParagraph(at: units.count)
        }
        return spans.sorted { $0.range.location < $1.range.location }
    }

    /// Calls `body` with each line's content and where its break ends, until `body` returns false.
    static func forEachLine<Units: Collection<UInt16>>(
        in units: Units, _ body: (_ line: Range<Units.Index>, _ end: Units.Index) -> Bool
    ) {
        var lineStart = units.startIndex
        while lineStart < units.endIndex {
            var contentEnd = lineStart
            while contentEnd < units.endIndex, units[contentEnd] != newline, units[contentEnd] != carriageReturn {
                units.formIndex(after: &contentEnd)
            }
            var lineEnd = contentEnd
            if lineEnd < units.endIndex, units[lineEnd] == carriageReturn { units.formIndex(after: &lineEnd) }
            if lineEnd < units.endIndex, units[lineEnd] == newline { units.formIndex(after: &lineEnd) }
            guard body(lineStart..<contentEnd, lineEnd) else { return }
            lineStart = lineEnd
        }
    }

    /// Follows fenced blocks line by line, from a note's first line.
    struct Fences {
        enum Line { case outside, opens, inside, closes }

        private var open: (character: UInt16, length: Int)?

        var isOpen: Bool { open != nil }

        /// Where the next line, its content without its break, stands. A block's fence lines belong to it.
        mutating func read<Units: Collection<UInt16>>(_ line: Units) -> Line {
            if let fence = open {
                guard let close = fenceRun(line), close.character == fence.character, close.length >= fence.length,
                    close.isBare
                else { return .inside }
                open = nil
                return .closes
            }
            guard let run = fenceRun(line), run.character == tilde || !run.infoHasBacktick else { return .outside }
            open = (run.character, run.length)
            return .opens
        }
    }

    private struct FenceRun {
        var character: UInt16
        var length: Int
        /// Nothing but spaces or tabs follows the fence, as a closing fence needs.
        var isBare: Bool
        var infoHasBacktick: Bool
    }

    /// Up to three spaces, then at least three backticks or tildes.
    private static func fenceRun<Units: Collection<UInt16>>(_ line: Units) -> FenceRun? {
        var index = line.startIndex
        var indent = 0
        while index < line.endIndex, line[index] == space, indent < 3 {
            line.formIndex(after: &index)
            indent += 1
        }
        guard index < line.endIndex, line[index] == backtick || line[index] == tilde else { return nil }
        let character = line[index]
        var length = 0
        while index < line.endIndex, line[index] == character {
            line.formIndex(after: &index)
            length += 1
        }
        guard length >= 3 else { return nil }
        let rest = line[index...]
        return FenceRun(
            character: character, length: length, isBare: rest.allSatisfy { $0 == space || $0 == tab },
            infoHasBacktick: rest.contains(backtick))
    }

    private static func inlineSpans(_ units: [UInt16], from start: Int, to end: Int) -> [Span] {
        var spans: [Span] = []
        var index = start
        while index < end {
            guard units[index] == backtick else {
                index += 1
                continue
            }
            // A backslash makes the backtick after it plain text.
            if index > start, units[index - 1] == backslash {
                index += 1
                continue
            }
            let open = index
            while index < end, units[index] == backtick { index += 1 }
            let length = index - open
            var search = index
            while search < end {
                guard units[search] == backtick else {
                    search += 1
                    continue
                }
                let runStart = search
                while search < end, units[search] == backtick { search += 1 }
                if search - runStart == length {
                    spans.append(Span(kind: .inline, range: NSRange(location: open, length: search - open)))
                    index = search
                    break
                }
            }
        }
        return spans
    }

    private static let newline: UInt16 = 0x0A
    private static let carriageReturn: UInt16 = 0x0D
    private static let space: UInt16 = 0x20
    private static let tab: UInt16 = 0x09
    private static let backtick: UInt16 = 0x60
    private static let tilde: UInt16 = 0x7E
    private static let backslash: UInt16 = 0x5C
}
