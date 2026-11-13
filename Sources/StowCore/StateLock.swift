import Darwin
import Foundation

/// Keeps one writable session per state folder.
///
/// Two processes writing the same index would silently revert each other's metadata, because the index is
/// replaced as a whole. The lock is an advisory BSD `flock` lock on a private file beside the index, taken once
/// the open file is checked; `open(O_EXLOCK)` in earlier builds takes the same lock. The kernel drops it when the
/// holder exits or crashes, so there is never a stale lock to clean up.
public final class StateLock: @unchecked Sendable {
    public enum Outcome: Sendable {
        case acquired(StateLock)
        /// Another live process owns this state folder.
        case heldByAnotherProcess
        /// The folder can't be written or the volume has no locks; writing proceeds unguarded.
        case unavailable
        /// The lock path holds something other than this user's own lock file, or locking failed; nothing writes.
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
        do {
            try LiveNoteIO.ensureDirectory(directory)
        } catch StateError.unwritable {
            return .unavailable
        } catch {
            return .failed
        }
        let path = directory.appendingPathComponent(filename).path
        // Never follow a planted link, never wait on a FIFO, and never let a launched child inherit the lock.
        let descriptor = path.withCString {
            Darwin.open($0, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, mode_t(0o600))
        }
        guard descriptor >= 0 else { return outcome(ofOpenError: errno, at: path) }
        var info = stat()
        guard Darwin.fstat(descriptor, &info) == 0, isLockFile(info, owner: geteuid()) else {
            Darwin.close(descriptor)
            return .failed
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            return outcome(ofLockError: code)
        }
        guard makePrivate(descriptor) == 0 else {
            Darwin.close(descriptor)
            return .failed
        }
        return .acquired(StateLock(descriptor: descriptor))
    }

    /// What an `open` error means. A folder that can't be written is unavailable unless something else is at `path`.
    static func outcome(ofOpenError code: Int32, at path: String, owner: uid_t = geteuid()) -> Outcome {
        guard [EROFS, EACCES, EPERM].contains(code) else { return .failed }
        var info = stat()
        guard path.withCString({ Darwin.lstat($0, &info) }) == 0 else { return .unavailable }
        return isLockFile(info, owner: owner) ? .unavailable : .failed
    }

    /// What a `flock` error means. Only a volume without locks is unavailable.
    static func outcome(ofLockError code: Int32) -> Outcome {
        switch code {
        case EWOULDBLOCK: .heldByAnotherProcess
        case ENOTSUP, EOPNOTSUPP, ENOLCK: .unavailable
        default: .failed
        }
    }

    /// Whether `info` is a regular file of `owner`'s with no other name.
    private static func isLockFile(_ info: stat, owner: uid_t) -> Bool {
        (info.st_mode & S_IFMT) == S_IFREG && info.st_nlink == 1 && info.st_uid == owner
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
