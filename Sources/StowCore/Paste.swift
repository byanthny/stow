import Foundation

public enum PasteContent: Equatable, Sendable {
    case pin(PullRequestReference, note: String?)
    case note(String)
}

extension PullRequestReference {
    /// Accepts one complete canonical GitHub pull request URL, never a substring or a lookalike host.
    public static func parse(_ text: String) -> PullRequestReference? {
        let candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: candidate),
            components.scheme?.lowercased() == "https", components.host?.lowercased() == "github.com",
            components.user == nil, components.password == nil, components.port == nil
        else { return nil }
        let pattern =
            #"\Ahttps://github\.com/([A-Za-z0-9][A-Za-z0-9-]*)/([A-Za-z0-9_.-]+)/pull/([0-9]+)/?(?:[?#][^\s]*)?\z"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
            let match = regex.firstMatch(in: candidate, range: NSRange(candidate.startIndex..., in: candidate)),
            let ownerRange = Range(match.range(at: 1), in: candidate),
            let repoRange = Range(match.range(at: 2), in: candidate),
            let numberRange = Range(match.range(at: 3), in: candidate),
            let number = Int(candidate[numberRange]), number > 0
        else { return nil }
        let repository = String(candidate[repoRange])
        guard repository != ".", repository != ".." else { return nil }
        return .init(owner: String(candidate[ownerRange]), repository: repository, number: number)
    }
}

public func parsePaste(_ text: String) -> PasteContent {
    // More than one URL is ambiguous even when the first is a valid PR.
    let urlPattern = #"(?i)(?:\b[a-z][a-z0-9+.-]*://|\bwww\.)"#
    let urlRegex = try? NSRegularExpression(pattern: urlPattern)
    let entireRange = NSRange(text.startIndex..., in: text)
    guard urlRegex?.numberOfMatches(in: text, range: entireRange) == 1 else { return .note(text) }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let tokenEnd = trimmed.firstIndex(where: \.isWhitespace) ?? trimmed.endIndex
    guard let reference = PullRequestReference.parse(String(trimmed[..<tokenEnd])) else { return .note(text) }
    let remainder = String(trimmed[tokenEnd...]).trimmingCharacters(in: .whitespacesAndNewlines)
    return .pin(reference, note: remainder.isEmpty ? nil : remainder)
}
