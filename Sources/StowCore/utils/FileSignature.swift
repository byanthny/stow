import Darwin
import Foundation

/// One version of a file, told apart from others without reading it: its inode, size, and modification time.
public struct FileSignature: Equatable, Sendable {
    let inode: UInt64
    let size: Int64
    let seconds: Int
    let nanoseconds: Int

    init(_ info: stat) {
        inode = UInt64(info.st_ino)
        size = Int64(info.st_size)
        seconds = info.st_mtimespec.tv_sec
        nanoseconds = info.st_mtimespec.tv_nsec
    }

    /// The signature of the regular file at `url`, never following a link; nil for anything else.
    init?(at url: URL) {
        var info = stat()
        guard url.path.withCString({ Darwin.lstat($0, &info) }) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            return nil
        }
        self.init(info)
    }
}
