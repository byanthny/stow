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
        do { return try PrivateFile.exists(url) } catch { throw stateError(error) }
    }

    static func ensureDirectory(_ url: URL) throws {
        do { try PrivateFile.ensureFolder(url) } catch { throw stateError(error) }
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
        do { return try PrivateFile.read(url, maximumBytes: maximumBytes) } catch { throw stateError(error) }
    }

    /// The state error for a private file failure: an oversize file is corrupt.
    private static func stateError(_ error: any Error) -> StateError {
        switch error as? PrivateFileError {
        case .tooLarge?: .corrupt
        case .unwritable?: .unwritable
        case .exists?, .unreadable?, nil: .unreadable
        }
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
        do { try PrivateFile.writeAtomically(data, to: url, replacing: replace) } catch { throw StateError.unwritable }
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
