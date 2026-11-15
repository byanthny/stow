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
        try readSigned(url, maximumBytes: maximumBytes)?.data
    }

    /// The bytes `read` returns, with the file's signature as it was opened.
    static func readSigned(_ url: URL, maximumBytes: Int) throws -> (data: Data, signature: FileSignature)? {
        guard try exists(url) else { return nil }
        var coordinationError: NSError?
        var result: Result<(data: Data, signature: FileSignature)?, Error>?
        NSFileCoordinator(filePresenter: nil).coordinate(
            readingItemAt: url, options: .withoutChanges,
            error: &coordinationError
        ) { coordinatedURL in
            result = Result { try readUncoordinated(coordinatedURL, maximumBytes: maximumBytes) }
        }
        if let result { return try result.get() }
        throw StateError.unreadable
    }

    private static func readUncoordinated(_ url: URL, maximumBytes: Int) throws -> (
        data: Data, signature: FileSignature
    )? {
        do { return try PrivateFile.readSigned(url, maximumBytes: maximumBytes) } catch { throw stateError(error) }
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
        return try managedFiles(in: directory)
    }

    /// The UUID-named Markdown files in `directory`, listed without creating or changing anything.
    static func managedFiles(in directory: URL) throws -> [UUID: URL] {
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

    /// `prepared` gets the new file's signature before the file reaches `url`.
    static func write(
        _ data: Data, to url: URL, replace: Bool = true,
        expectedData: Data? = nil, checkExpected: Bool = false, prepared: (FileSignature) -> Void = { _ in }
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
                    guard current?.data == expectedData else { throw StateError.unwritable }
                }
                try writeUncoordinated(data, to: coordinatedURL, replace: replace, prepared: prepared)
            }
        }
        if let result { return try result.get() }
        throw StateError.unwritable
    }

    private static func writeUncoordinated(
        _ data: Data, to url: URL, replace: Bool, prepared: (FileSignature) -> Void
    ) throws {
        // Refuse even dangling destination symlinks. Replacing them would hide data/redirect user intent.
        if try exists(url) {
            var info = stat()
            guard url.path.withCString({ Darwin.lstat($0, &info) }) == 0,
                (info.st_mode & S_IFMT) == S_IFREG
            else { throw StateError.unreadable }
            guard replace else { throw StateError.unwritable }
        }
        do { try PrivateFile.writeAtomically(data, to: url, replacing: replace, prepared: prepared) } catch {
            throw StateError.unwritable
        }
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

/// The managed Markdown files as Stow last wrote or read them, so a change it made itself starts no merge.
public final class NoteFileSignatures: @unchecked Sendable {
    private let lock = NSLock()
    /// Signatures by file name.
    private var signatures: [String: FileSignature] = [:]

    public init() {}

    /// Records `file` as written or read with `signature`, or as removed when it is nil.
    func record(_ signature: FileSignature?, for file: URL) {
        lock.withLock { signatures[file.lastPathComponent] = signature }
    }

    func replace(with recorded: [String: FileSignature]) {
        lock.withLock { signatures = recorded }
    }

    /// Whether `directory` holds exactly the managed files recorded, each as recorded.
    public func match(_ directory: URL) -> Bool {
        guard directory.isRealFolder, let files = try? LiveNoteIO.managedFiles(in: directory) else { return false }
        let recorded = lock.withLock { signatures }
        return files.count == recorded.count
            && files.values.allSatisfy { file in
                recorded[file.lastPathComponent].map { FileSignature(at: file) == $0 } ?? false
            }
    }
}
