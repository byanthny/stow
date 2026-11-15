import Darwin
import Foundation

/// Why a private file or folder could not be read or written. Errors from writing an open file pass through.
public enum PrivateFileError: Error, Equatable, Sendable {
    /// The file holds more bytes than the limit.
    case tooLarge
    /// Something is already at the path, a link included.
    case exists
    /// A link or something other than a regular file or folder is at the path, or it can't be opened or checked.
    case unreadable
    /// The file or folder could not be made, made owner-only, or moved into place.
    case unwritable
}

/// Owner-only files and folders that never follow a link at their own path.
public enum PrivateFile {
    /// Whether anything is at `url`, a dangling link included.
    public static func exists(_ url: URL) throws -> Bool {
        var info = stat()
        let result = url.path.withCString { Darwin.lstat($0, &info) }
        if result == 0 { return true }
        if errno == ENOENT || errno == ENOTDIR { return false }
        throw PrivateFileError.unreadable
    }

    /// Creates `url` and any missing parents as owner-only folders; an existing entry must be a real folder.
    public static func ensureFolder(_ url: URL) throws {
        if try exists(url) {
            var info = stat()
            guard url.path.withCString({ Darwin.lstat($0, &info) }) == 0,
                (info.st_mode & S_IFMT) == S_IFDIR
            else { throw PrivateFileError.unreadable }
        } else {
            do {
                try FileManager.default.createDirectory(
                    at: url, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
            } catch { throw PrivateFileError.unwritable }
        }
    }

    /// Creates a new owner-only folder at `url`, refusing anything already there.
    public static func createFolder(_ url: URL) throws {
        guard url.path.withCString({ Darwin.mkdir($0, mode_t(0o700)) }) == 0 else {
            throw errno == EEXIST ? PrivateFileError.exists : PrivateFileError.unwritable
        }
        guard url.path.withCString({ Darwin.chmod($0, mode_t(0o700)) }) == 0 else {
            try? FileManager.default.removeItem(at: url)
            throw PrivateFileError.unwritable
        }
    }

    /// The bytes of the regular file at `url`, or nil when nothing is there; refuses a link and over `maximumBytes`.
    public static func read(_ url: URL, maximumBytes: Int) throws -> Data? {
        let descriptor = url.path.withCString { Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK) }
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            throw PrivateFileError.unreadable
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard Darwin.fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw PrivateFileError.unreadable
        }
        guard info.st_size <= maximumBytes else { throw PrivateFileError.tooLarge }
        do { return try read(handle, maximumBytes: maximumBytes) } catch let error as PrivateFileError {
            throw error
        } catch { throw PrivateFileError.unreadable }
    }

    /// Reads `handle` to its end, throwing `tooLarge` past `maximumBytes`; read errors pass through.
    public static func read(_ handle: FileHandle, maximumBytes: Int) throws -> Data {
        guard maximumBytes >= 0, maximumBytes < Int.max else { throw PrivateFileError.tooLarge }
        var data = Data()
        while data.count <= maximumBytes {
            let chunk = try handle.read(upToCount: min(65_536, maximumBytes + 1 - data.count)) ?? Data()
            if chunk.isEmpty { return data }
            data.append(chunk)
        }
        throw PrivateFileError.tooLarge
    }

    /// Writes `data` to a new owner-only file at `url`, refusing anything already there; a failed write removes it.
    public static func create(_ data: Data, at url: URL) throws {
        let descriptor = url.path.withCString {
            Darwin.open($0, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, mode_t(0o600))
        }
        guard descriptor >= 0 else { throw errno == EEXIST ? PrivateFileError.exists : PrivateFileError.unwritable }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var completed = false
        defer {
            try? handle.close()
            if !completed { try? FileManager.default.removeItem(at: url) }
        }
        guard Darwin.fchmod(descriptor, mode_t(0o600)) == 0 else { throw PrivateFileError.unwritable }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
        completed = true
    }

    /// Writes `data` to a new owner-only file beside `url`, then renames it over `url`, replacing a link rather than
    /// following it. With `replacing` false it links the file there instead, refusing anything already at `url`.
    public static func writeAtomically(
        _ data: Data, to url: URL, replacing: Bool = true, temporaryPrefix: String = ".stow-"
    ) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(
            "\(temporaryPrefix)\(UUID().uuidString).tmp")
        try create(data, at: temporary)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let status = temporary.path.withCString { source in
            url.path.withCString { destination in
                replacing ? Darwin.rename(source, destination) : Darwin.link(source, destination)
            }
        }
        guard status == 0 else { throw PrivateFileError.unwritable }
    }
}
