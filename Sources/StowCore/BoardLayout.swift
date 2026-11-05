import Foundation

/// How the board arranges its sections. Every value is a preference with a default, not a rule.
public struct BoardLayout: Codable, Equatable, Sendable {
    public enum Section: String, Codable, CaseIterable, Sendable {
        case needsYou, notes, waiting
    }

    public enum OwnerOrder: String, Codable, Sendable {
        case alphabetical, mostCards
    }

    public static let defaultOrder: [Section] = [.needsYou, .notes, .waiting]
    public static let defaultVisiblePullRequests = 3
    /// Accepted card counts before "Show more"; 0 means every card.
    public static let visiblePullRequestRange = 0...100

    public var order: [Section] { didSet { order = Self.normalized(order) } }
    /// Pull requests shown in each section before "Show more"; 0 shows every card.
    public var visiblePullRequests: Int
    /// Board notes show as one-line rows until opened.
    public var notesStartCollapsed: Bool
    /// The board header shows its title beside the icon; the icon always stays.
    public var showsTitle: Bool
    public var groupByOwner = false
    public var ownerOrder: OwnerOrder = .alphabetical
    public var alwaysShowOwnerControl = false
    public var hidesNotesForHiddenOwners = false

    public init(
        order: [Section] = defaultOrder, visiblePullRequests: Int = defaultVisiblePullRequests,
        notesStartCollapsed: Bool = true, showsTitle: Bool = true
    ) {
        self.order = Self.normalized(order)
        self.visiblePullRequests = visiblePullRequests
        self.notesStartCollapsed = notesStartCollapsed
        self.showsTitle = showsTitle
    }

    private enum CodingKeys: String, CodingKey {
        case order, visiblePullRequests, notesStartCollapsed, showsTitle
        case groupByOwner, ownerOrder, alwaysShowOwnerControl, hidesNotesForHiddenOwners
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Section names from a newer version are skipped rather than rejecting the whole state.
        let names = try container.decodeIfPresent([String].self, forKey: .order) ?? []
        order = Self.normalized(names.compactMap(Section.init(rawValue:)))
        visiblePullRequests =
            try container.decodeIfPresent(Int.self, forKey: .visiblePullRequests) ?? Self.defaultVisiblePullRequests
        guard Self.visiblePullRequestRange.contains(visiblePullRequests) else {
            throw DecodingError.dataCorruptedError(
                forKey: .visiblePullRequests, in: container, debugDescription: "Pull request count out of range")
        }
        notesStartCollapsed = try container.decodeIfPresent(Bool.self, forKey: .notesStartCollapsed) ?? true
        showsTitle = try container.decodeIfPresent(Bool.self, forKey: .showsTitle) ?? true
        groupByOwner = try container.decodeIfPresent(Bool.self, forKey: .groupByOwner) ?? false
        // A name from a newer version, or a value that is not a name, falls back to the default rather than
        // rejecting the whole state.
        let ownerOrderName = try? container.decodeIfPresent(String.self, forKey: .ownerOrder)
        ownerOrder = ownerOrderName.flatMap(OwnerOrder.init(rawValue:)) ?? .alphabetical
        alwaysShowOwnerControl = try container.decodeIfPresent(Bool.self, forKey: .alwaysShowOwnerControl) ?? false
        hidesNotesForHiddenOwners =
            try container.decodeIfPresent(Bool.self, forKey: .hidesNotesForHiddenOwners) ?? false
    }

    /// Moves a section up (negative) or down (positive) one place at a time; edges are left alone.
    public mutating func move(_ section: Section, by offset: Int) {
        guard let index = order.firstIndex(of: section) else { return }
        let target = index + offset.signum()
        guard order.indices.contains(target) else { return }
        order.swapAt(index, target)
    }

    /// Cards to show from `total` before "Show more", or all of them once the section is expanded.
    public func shownPullRequests(of total: Int, expanded: Bool) -> Int {
        guard visiblePullRequests > 0, !expanded else { return total }
        return min(total, visiblePullRequests)
    }

    /// Each section exactly once: saved order first, then any missing sections in default order.
    static func normalized(_ order: [Section]) -> [Section] {
        var seen = Set<Section>()
        let kept = order.filter { seen.insert($0).inserted }
        return kept + defaultOrder.filter { !seen.contains($0) }
    }
}
