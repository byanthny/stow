import Darwin
import Foundation

public struct LiveSaveResult: Equatable, Sendable {
    public var state: AppState
    public var conflictNoteIDs: [UUID]
    public var externallyDeletedIDs: [UUID]

    public init(state: AppState, conflictNoteIDs: [UUID] = [], externallyDeletedIDs: [UUID] = []) {
        self.state = state
        self.conflictNoteIDs = conflictNoteIDs
        self.externallyDeletedIDs = externallyDeletedIDs
    }
}

/// UUID-named Markdown files are managed by Stow. Other filenames are left untouched.
enum LiveNoteIO {
    static let maximumIndexBytes = 64 * 1024 * 1024

    static func exists(_ url: URL) throws -> Bool {
        var info = stat()
        let result = url.path.withCString { Darwin.lstat($0, &info) }
        if result == 0 { return true }
        if errno == ENOENT || errno == ENOTDIR { return false }
        throw StateError.unreadable
    }

    static func ensureDirectory(_ url: URL) throws {
        if try exists(url) {
            var info = stat()
            guard url.path.withCString({ Darwin.lstat($0, &info) }) == 0,
                (info.st_mode & S_IFMT) == S_IFDIR
            else { throw StateError.unreadable }
        } else {
            do {
                try FileManager.default.createDirectory(
                    at: url, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
            } catch { throw StateError.unwritable }
        }
    }

    static func read(_ url: URL, maximumBytes: Int) throws -> Data? {
        guard try exists(url) else { return nil }
        var coordinationError: NSError?
        var result: Result<Data?, Error>?
        NSFileCoordinator(filePresenter: nil).coordinate(
            readingItemAt: url, options: .withoutChanges,
            error: &coordinationError
        ) { coordinatedURL in
            result = Result { try readUncoordinated(coordinatedURL, maximumBytes: maximumBytes) }
        }
        if let result { return try result.get() }
        throw StateError.unreadable
    }

    private static func readUncoordinated(_ url: URL, maximumBytes: Int) throws -> Data? {
        let descriptor = url.path.withCString { Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK) }
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            throw StateError.unreadable
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard Darwin.fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw StateError.unreadable
        }
        guard info.st_size <= maximumBytes else { throw StateError.corrupt }
        var data = Data()
        do {
            while let chunk = try handle.read(upToCount: min(65_536, maximumBytes + 1 - data.count)), !chunk.isEmpty {
                data.append(chunk)
                guard data.count <= maximumBytes else { throw StateError.corrupt }
            }
        } catch let error as StateError { throw error } catch { throw StateError.unreadable }
        return data
    }

    static func source(_ data: Data) throws -> String {
        do { return try MarkdownTransfer.decodeNote(data) } catch { throw StateError.corrupt }
    }

    static func files(in directory: URL) throws -> [UUID: URL] {
        guard try exists(directory) else { return [:] }
        try ensureDirectory(directory)
        let files: [URL]
        do { files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) } catch
        { throw StateError.unreadable }
        var result: [UUID: URL] = [:]
        for file in files where file.pathExtension == "md" {
            let name = file.deletingPathExtension().lastPathComponent
            guard name.count == 36, let id = UUID(uuidString: name) else { continue }
            // Multiple spellings of one UUID are ambiguous; never silently choose a source.
            guard result[id] == nil else { throw StateError.corrupt }
            result[id] = file
        }
        return result
    }

    static func write(
        _ data: Data, to url: URL, replace: Bool = true,
        expectedData: Data? = nil, checkExpected: Bool = false
    ) throws {
        var coordinationError: NSError?
        var result: Result<Void, Error>?
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: url, options: .forReplacing,
            error: &coordinationError
        ) { coordinatedURL in
            result = Result {
                // Keep the comparison and replacement under the same coordination claim. A new
                // external edit after the merge read must never be silently overwritten.
                if checkExpected {
                    let current = try readUncoordinated(
                        coordinatedURL, maximumBytes: MarkdownTransfer.maximumNoteByteCount)
                    guard current == expectedData else { throw StateError.unwritable }
                }
                try writeUncoordinated(data, to: coordinatedURL, replace: replace)
            }
        }
        if let result { return try result.get() }
        throw StateError.unwritable
    }

    private static func writeUncoordinated(_ data: Data, to url: URL, replace: Bool) throws {
        // Refuse even dangling destination symlinks. Replacing them would hide data/redirect user intent.
        if try exists(url) {
            var info = stat()
            guard url.path.withCString({ Darwin.lstat($0, &info) }) == 0,
                (info.st_mode & S_IFMT) == S_IFREG
            else { throw StateError.unreadable }
            guard replace else { throw StateError.unwritable }
        }
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".stow-\(UUID().uuidString).tmp")
        let descriptor = temporary.path.withCString {
            Darwin.open($0, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, mode_t(0o600))
        }
        guard descriptor >= 0 else { throw StateError.unwritable }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer {
            try? handle.close()
            try? FileManager.default.removeItem(at: temporary)
        }
        guard Darwin.fchmod(descriptor, mode_t(0o600)) == 0 else { throw StateError.unwritable }
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch { throw StateError.unwritable }
        let status = temporary.path.withCString { source in
            url.path.withCString { destination in
                replace ? Darwin.rename(source, destination) : Darwin.link(source, destination)
            }
        }
        guard status == 0 else { throw StateError.unwritable }
    }

    static func remove(_ url: URL) throws {
        guard try exists(url) else { return }
        var coordinationError: NSError?
        var result: Result<Void, Error>?
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: url, options: .forDeleting,
            error: &coordinationError
        ) { coordinatedURL in
            result = Result {
                // Unlink removes the managed entry itself, never a symlink target.
                guard coordinatedURL.path.withCString({ Darwin.unlink($0) }) == 0 || errno == ENOENT else {
                    throw StateError.unwritable
                }
            }
        }
        if let result { return try result.get() }
        throw StateError.unwritable
    }
}
