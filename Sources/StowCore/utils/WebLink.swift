import Foundation

extension URL {
    /// An http or https address with a host: the only links Stow opens.
    public var isWebLink: Bool {
        guard let scheme = scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        return host?.isEmpty == false
    }
}
