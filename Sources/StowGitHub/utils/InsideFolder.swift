import Darwin
import Foundation

extension URL {
    /// Whether this path passes through `folder`, comparing files rather than spellings, or `folder` can't be checked.
    func isInside(_ folder: URL) -> Bool {
        var target = stat()
        guard fstatat(AT_FDCWD, folder.path, &target, 0) == 0 else { return true }
        let parts = (path as NSString).pathComponents
        return parts.indices.contains { end in
            var info = stat()
            return fstatat(AT_FDCWD, NSString.path(withComponents: Array(parts[...end])), &info, 0) == 0
                && info.st_dev == target.st_dev && info.st_ino == target.st_ino
        }
    }
}
