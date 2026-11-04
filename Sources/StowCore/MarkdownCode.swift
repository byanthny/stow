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
        var fence: (start: Int, character: UInt16, length: Int)?
        var paragraphStart: Int?
        var lineStart = 0

        func endParagraph(at end: Int) {
            if let start = paragraphStart { spans += inlineSpans(units, from: start, to: end) }
            paragraphStart = nil
        }

        while lineStart < units.count {
            var contentEnd = lineStart
            while contentEnd < units.count, units[contentEnd] != newline, units[contentEnd] != carriageReturn {
                contentEnd += 1
            }
            var lineEnd = contentEnd
            if lineEnd < units.count, units[lineEnd] == carriageReturn { lineEnd += 1 }
            if lineEnd < units.count, units[lineEnd] == newline { lineEnd += 1 }
            let line = lineStart..<contentEnd

            if let open = fence {
                if let close = fenceRun(units, line), close.character == open.character, close.length >= open.length,
                    close.isBare
                {
                    spans.append(Span(kind: .block, range: NSRange(location: open.start, length: lineEnd - open.start)))
                    fence = nil
                }
            } else if let open = fenceRun(units, line), open.character == tilde || !open.infoHasBacktick {
                endParagraph(at: lineStart)
                fence = (lineStart, open.character, open.length)
            } else if line.allSatisfy({ units[$0] == space || units[$0] == tab }) {
                endParagraph(at: lineStart)
            } else if paragraphStart == nil {
                paragraphStart = lineStart
            }
            lineStart = lineEnd
        }
        if let open = fence {
            spans.append(Span(kind: .block, range: NSRange(location: open.start, length: units.count - open.start)))
        } else {
            endParagraph(at: units.count)
        }
        return spans.sorted { $0.range.location < $1.range.location }
    }

    private struct FenceRun {
        var character: UInt16
        var length: Int
        /// Nothing but spaces or tabs follows the fence, as a closing fence needs.
        var isBare: Bool
        var infoHasBacktick: Bool
    }

    /// Up to three spaces, then at least three backticks or tildes.
    private static func fenceRun(_ units: [UInt16], _ line: Range<Int>) -> FenceRun? {
        var index = line.lowerBound
        while index < line.upperBound, units[index] == space, index - line.lowerBound < 3 { index += 1 }
        guard index < line.upperBound, units[index] == backtick || units[index] == tilde else { return nil }
        let character = units[index]
        let runStart = index
        while index < line.upperBound, units[index] == character { index += 1 }
        guard index - runStart >= 3 else { return nil }
        let rest = units[index..<line.upperBound]
        return FenceRun(
            character: character, length: index - runStart, isBare: rest.allSatisfy { $0 == space || $0 == tab },
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
