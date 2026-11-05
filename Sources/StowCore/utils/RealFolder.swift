import Foundation

extension URL {
    /// A folder itself, not a link to one or to anything else.
    public var isRealFolder: Bool {
        (try? FileManager.default.attributesOfItem(atPath: path)[.type] as? FileAttributeType) == .typeDirectory
    }
}
