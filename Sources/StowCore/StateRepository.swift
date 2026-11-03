import Darwin
import Foundation

public enum StateError: Error, LocalizedError, Equatable, Sendable {
    case unreadable
    case corrupt
    case unsupportedVersion(Int)
    case recoveryRequired
    case unwritable
    case recoveryFailed

    public var errorDescription: String? {
        switch self {
        case .unreadable: return "Stow could not read its saved state. The original file has been preserved."
        case .corrupt: return "Stow could not decode its saved state. The original file has been preserved."
        case .unsupportedVersion(let version):
            return "This saved state uses unsupported version \(version). The original file has been preserved."
        case .recoveryRequired: return "Saved state must be backed up with explicit recovery before it can be replaced."
        case .unwritable: return "Stow could not save state. Check access to the storage folder."
        case .recoveryFailed: return "Stow could not back up the saved state. The original file has been preserved."
        }
    }
}

/// The actor serializes full-state writes. Notes have one canonical representation inside AppState.
public actor StateRepository {
    public static var defaultURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent("Stow", isDirectory: true).appendingPathComponent("state.json")
    }

    private let url: URL
    private var hasLoaded = false
    private var requiresRecovery = false
    private var isClosed = false

    public init(url: URL) { self.url = url }

    public func load() async throws -> AppState {
        try loadState()
    }

    private func loadState() throws -> AppState {
        guard !requiresRecovery else { throw StateError.recoveryRequired }
        guard FileManager.default.fileExists(atPath: url.path) else {
            hasLoaded = true
            return AppState()
        }
        let data: Data
        do { data = try Data(contentsOf: url) } catch {
            requiresRecovery = true
            throw StateError.unreadable
        }
        do {
            // Read the envelope first so a newer schema need not match today's AppState shape.
            struct Version: Decodable { var schemaVersion: Int }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let version = try decoder.decode(Version.self, from: data).schemaVersion
            guard version == AppState.currentVersion else {
                requiresRecovery = true
                throw StateError.unsupportedVersion(version)
            }
            let state = try decoder.decode(AppState.self, from: data)
            hasLoaded = true
            return state
        } catch let error as StateError { throw error } catch {
            requiresRecovery = true
            throw StateError.corrupt
        }
    }

    public func save(_ state: AppState) async throws {
        guard !isClosed else { return }
        try saveState(state)
    }

    /// Commits the final quit snapshot and prevents delayed older writes from replacing it.
    /// No suspension occurs between the final write and closing the repository. A failed write
    /// leaves it open so the app can remain running and retry.
    public func saveAndClose(_ state: AppState) async throws {
        guard !isClosed else { return }
        try saveState(state)
        isClosed = true
    }

    private func saveState(_ state: AppState) throws {
        guard !requiresRecovery else { throw StateError.recoveryRequired }
        if !hasLoaded { _ = try loadState() }
        guard state.schemaVersion == AppState.currentVersion else {
            throw StateError.unsupportedVersion(state.schemaVersion)
        }
        do {
            let directory = url.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
            }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(state)
            try writeAtomically(data)
        } catch { throw StateError.unwritable }
    }

    /// Creates the temporary file privately before writing any bytes, then atomically renames it.
    /// A failed encode, write, sync, permission change, or rename leaves the original untouched.
    private func writeAtomically(_ data: Data) throws {
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
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
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
        let renamed = temporary.path.withCString { source in
            url.path.withCString { destination in Darwin.rename(source, destination) }
        }
        guard renamed == 0 else { throw StateError.unwritable }
    }

    /// Only invoke after a user's explicit recovery action. Never deletes the unreadable original.
    @discardableResult
    public func recoverByBackingUp() async throws -> URL? {
        var backup: URL?
        if FileManager.default.fileExists(atPath: url.path) {
            let target = url.appendingPathExtension("backup-\(UUID().uuidString)")
            do { try FileManager.default.moveItem(at: url, to: target) } catch { throw StateError.recoveryFailed }
            backup = target
        }
        requiresRecovery = false
        hasLoaded = true
        return backup
    }
}
