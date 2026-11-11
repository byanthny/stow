import Darwin
import Foundation

/// Keeps one writable session per state folder.
///
/// Two processes writing the same index would silently revert each other's metadata, because the index is
/// replaced as a whole. The lock is an advisory BSD `flock` lock on a private file beside the index, taken
/// atomically by `open(O_EXLOCK)`. The kernel drops it when the holder exits or crashes, so there is never a
/// stale lock to clean up.
public final class StateLock: @unchecked Sendable {
    public enum Outcome: Sendable {
        case acquired(StateLock)
        /// Another live process owns this state folder.
        case heldByAnotherProcess
        /// The volume cannot lock (it has no `flock`); writing proceeds unguarded.
        case unavailable
        /// Locking failed otherwise, as with a link or folder at the lock path, permissions, or I/O; nothing writes.
        case failed
    }

    public static let filename = ".stow.lock"
    /// The process-wide lock that keeps a second Stow instance from running on the same data folder.
    public static let instanceFilename = ".stow-app.lock"
    private let lock = NSLock()
    private var descriptor: Int32

    private init(descriptor: Int32) { self.descriptor = descriptor }
    deinit { release() }

    public static func acquire(forStateAt stateURL: URL) -> Outcome {
        acquire(named: filename, in: stateURL.deletingLastPathComponent())
    }

    /// Takes the lock file `filename` inside `directory`, creating the private folder if needed.
    public static func acquire(named filename: String, in directory: URL) -> Outcome {
        acquire(named: filename, in: directory) { Darwin.fchmod($0, mode_t(0o600)) }
    }

    /// `makePrivate` sets the lock file's mode and returns 0 or -1 with `errno`; tests replace it.
    static func acquire(named filename: String, in directory: URL, makePrivate: (Int32) -> Int32) -> Outcome {
        do { try LiveNoteIO.ensureDirectory(directory) } catch { return .failed }
        let path = directory.appendingPathComponent(filename).path
        // Never follow a planted link, and never let a launched child inherit the lock.
        let descriptor = path.withCString {
            Darwin.open($0, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_EXLOCK | O_NONBLOCK, mode_t(0o600))
        }
        guard descriptor >= 0 else {
            let result = outcome(ofError: errno)
            // A FIFO or socket at the path also reports that it cannot lock.
            if case .unavailable = result, holdsOtherThanFile(path) { return .failed }
            return result
        }
        var info = stat()
        guard Darwin.fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            Darwin.close(descriptor)
            return .failed
        }
        guard makePrivate(descriptor) == 0 else {
            Darwin.close(descriptor)
            return .failed
        }
        return .acquired(StateLock(descriptor: descriptor))
    }

    /// What an error from taking the lock means. Only a volume without locks is unavailable.
    static func outcome(ofError code: Int32) -> Outcome {
        switch code {
        case EWOULDBLOCK: .heldByAnotherProcess
        case ENOTSUP, EOPNOTSUPP: .unavailable
        default: .failed
        }
    }

    /// Whether something other than a regular file is at `path`, without following a link.
    private static func holdsOtherThanFile(_ path: String) -> Bool {
        var info = stat()
        return path.withCString { Darwin.lstat($0, &info) } == 0 && (info.st_mode & S_IFMT) != S_IFREG
    }

    /// Releases the lock early. Normally the lock lives until the process exits.
    public func release() {
        lock.lock()
        defer { lock.unlock() }
        guard descriptor >= 0 else { return }
        // Closing the only descriptor releases the lock.
        Darwin.close(descriptor)
        descriptor = -1
    }
}
