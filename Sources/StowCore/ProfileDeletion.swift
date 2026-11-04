import Darwin
import Foundation

/// Records a move of the data folder profile into `profiles/<id>/`. It stays in the data folder as `.moving.json`
/// until the move is finished or undone, so a crash part way never leaves the profile split between two folders.
struct ProfileMoveJournal: Codable, Equatable, Sendable {
    static let filename = ".moving.json"
    static let currentVersion = 1
    static let maximumBytes = 1024 * 1024
    /// The names that saves, restores, and recovery give a profile's files, in the order they move: the files
    /// that mark a folder as a profile go first. Locks, the index, `profiles/`, and anything else stay put.
    static let itemPatterns = [
        "state.json", ProfileIdentity.filename, "notes", "notes-<UUID>", "state.json.*", "notes.backup-*",
        "notes-*.backup-*", "pre-restore-*.stowbackup",
    ]

    var schemaVersion = currentVersion
    var id: UUID
    var items: [String]

    init(id: UUID, items: [String]) {
        self.id = id
        self.items = items
    }

    /// The profile's items among a folder's entries, in move order.
    static func items(among names: [String]) -> [String] {
        itemPatterns.flatMap { pattern in names.filter { matches($0, pattern) }.sorted() }
    }

    /// Decodes untrusted bytes. Every item must be a profile file name, so a planted journal cannot move
    /// anything else. A newer journal is left for the build that wrote it.
    static func decode(_ data: Data) -> ProfileMoveJournal? {
        guard data.count <= maximumBytes,
            let journal = try? JSONDecoder().decode(ProfileMoveJournal.self, from: data),
            journal.schemaVersion == currentVersion,
            journal.items.allSatisfy({ name in itemPatterns.contains { matches(name, $0) } })
        else { return nil }
        return journal
    }

    private static func matches(_ name: String, _ pattern: String) -> Bool {
        guard !name.contains("/"), !name.contains("\0") else { return false }
        if pattern == "notes-<UUID>" {
            let identifier = name.dropFirst("notes-".count)
            return name.hasPrefix("notes-") && identifier.count == 36 && UUID(uuidString: String(identifier)) != nil
        }
        return fnmatch(pattern, name, 0) == 0
    }
}

extension ProfileCatalog {
    var journalURL: URL { dataFolder.appendingPathComponent(ProfileMoveJournal.filename) }

    /// Moves a profile's folder to the Trash, where it stays recoverable, then drops the profile from the index.
    /// Holds the profile's lock throughout, and refuses while another holder has it and for the last profile.
    /// If a step fails, the move is undone before the error is thrown. Profile data is never deleted.
    public func trash(_ id: UUID) throws {
        let snapshot = try writableSnapshot()
        let entry = try entry(id, in: snapshot)
        guard snapshot.profiles.count > 1 else { throw ProfileError.lastProfile }
        let lock = try Self.holdLock(of: entry.folder)
        defer { lock?.release() }
        if entry.isDataFolder {
            try trashDataFolderProfile(id)
            dataFolderID = nil
        } else {
            do { try moveToTrash(entry.folder) } catch { throw ProfileError.unwritable }
        }
        forget(id, in: snapshot)
    }

    /// Moves the data folder profile's files into an empty `profiles/<id>/` under a journal, then trashes that
    /// folder, so Put Back returns the profile to a place Stow looks.
    private func trashDataFolderProfile(_ id: UUID) throws {
        let destination = profilesURL.appendingPathComponent(id.uuidString, isDirectory: true)
        try wrapping { try LiveNoteIO.ensureDirectory(profilesURL) }
        // Discovery ignores a profiles folder that is not a real one owned by this user.
        guard isOwnedDirectory(profilesURL), makeMoveDestination(destination) else { throw ProfileError.unwritable }
        let journal: ProfileMoveJournal
        do {
            let names = try FileManager.default.contentsOfDirectory(atPath: dataFolder.path)
            journal = ProfileMoveJournal(id: id, items: ProfileMoveJournal.items(among: names))
            try writeJournal(journal)
        } catch {
            Self.removeEmptyFolder(destination)
            throw ProfileError.unwritable
        }
        let moved = Self.move(journal.items, from: dataFolder, to: destination)
        guard moved.count == journal.items.count else {
            putBack(moved, from: destination)
            throw ProfileError.unwritable
        }
        do { try moveToTrash(destination) } catch {
            putBack(journal.items, from: destination)
            throw ProfileError.unwritable
        }
        // The folder is in the Trash. A journal that outlives this names a missing folder, which load drops.
        try? LiveNoteIO.remove(journalURL)
    }

    /// Makes the folder the data folder profile moves into. An existing folder is reused only when it is a real
    /// folder owned by this user, holds nothing, and no journal is waiting: what a crash between making it and
    /// writing the journal leaves. Any other existing folder is refused, so the files never mix with another copy.
    private func makeMoveDestination(_ folder: URL) -> Bool {
        let status = folder.path.withCString { Darwin.mkdir($0, mode_t(0o700)) == 0 ? 0 : errno }
        if status == 0 { return true }
        guard status == EEXIST, isOwnedDirectory(folder), (try? LiveNoteIO.exists(journalURL)) == false,
            (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.isEmpty == true
        else { return false }
        // Owner-only, like a folder made here.
        return folder.path.withCString { Darwin.chmod($0, mode_t(0o700)) } == 0
    }

    /// Moves items back into the data folder after a failed step. Once all are back, it removes the empty folder
    /// and then the journal, in that order, so a crash in between leaves a journal that load drops. If an item
    /// cannot come back, the journal stays and the next load finishes the move instead.
    private func putBack(_ items: [String], from destination: URL) {
        guard Self.move(items.reversed(), from: destination, to: dataFolder).count == items.count else { return }
        Self.removeEmptyFolder(destination)
        try? LiveNoteIO.remove(journalURL)
    }

    /// Removes a trashed profile from the index. The folder is already in the Trash, so a failed write is not
    /// reported as a failed deletion: discovery never lists a missing folder, and the stale ID only means the
    /// folder is not treated as new if it is put back.
    private func forget(_ id: UUID, in snapshot: ProfileCatalogSnapshot) {
        var index = snapshot.index
        index.order.removeAll { $0 == id }
        index.open.removeAll { $0.id == id }
        index.seenIDs.removeAll { $0 == id }
        if index.lastActiveID == id { index.lastActiveID = nil }
        guard index != snapshot.index else { return }
        // Without the trashed entry, an index write can never recreate the data folder profile's identity.
        var remaining = snapshot
        remaining.profiles.removeAll { $0.id == id }
        try? writeIndex(index, after: remaining)
    }

    /// Finishes a move of the data folder profile that a crash interrupted, so its files are never left split
    /// between two folders. It runs only while it can hold the data folder's lock and the destination's;
    /// otherwise the journal waits for a later launch. It moves only the journal's profile files, never replaces
    /// anything, and leaves an unreadable or newer journal untouched.
    func finishInterruptedMove() {
        guard (try? LiveNoteIO.exists(journalURL)) == true else { return }
        let dataLock: StateLock?
        do { dataLock = try Self.holdLock(of: dataFolder) } catch { return }
        defer { dataLock?.release() }
        guard let data = try? LiveNoteIO.read(journalURL, maximumBytes: ProfileMoveJournal.maximumBytes),
            let journal = ProfileMoveJournal.decode(data)
        else { return }
        let destination = profilesURL.appendingPathComponent(journal.id.uuidString, isDirectory: true)
        guard isOwnedDirectory(profilesURL), isOwnedDirectory(destination) else {
            // The folder reached the Trash, or was removed, before its journal: nothing is left to finish.
            if (try? LiveNoteIO.exists(destination)) == false { try? LiveNoteIO.remove(journalURL) }
            return
        }
        let destinationLock: StateLock?
        do { destinationLock = try Self.holdLock(of: destination) } catch { return }
        defer { destinationLock?.release() }
        var finished = true
        for name in journal.items {
            let source = dataFolder.appendingPathComponent(name)
            switch Self.renameExclusively(source, to: destination.appendingPathComponent(name)) {
            // Moved now, moved before the crash, or present in both folders, where neither copy is replaced.
            case 0, ENOENT, EEXIST: break
            default: finished = false
            }
        }
        if finished { try? LiveNoteIO.remove(journalURL) }
    }

    // MARK: helpers

    /// The folder's lock, or nil on a volume that cannot lock, where writing proceeds as elsewhere in Stow.
    /// Throws `.inUse` while another holder, in this process or another, has it.
    private static func holdLock(of folder: URL) throws -> StateLock? {
        switch StateLock.acquire(forStateAt: folder.appendingPathComponent("state.json")) {
        case .acquired(let lock): return lock
        case .heldByAnotherProcess: throw ProfileError.inUse
        case .unavailable: return nil
        }
    }

    private func writeJournal(_ journal: ProfileMoveJournal) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(journal), data.count <= ProfileMoveJournal.maximumBytes else {
            throw ProfileError.unwritable
        }
        // Never replaces a journal that is still waiting for a later launch.
        try wrapping { try LiveNoteIO.write(data, to: journalURL, replace: false) }
    }

    /// Renames each item in order, stopping at the first failure, and returns the names moved.
    private static func move(_ names: [String], from source: URL, to target: URL) -> [String] {
        var moved: [String] = []
        for name in names {
            guard renameExclusively(source.appendingPathComponent(name), to: target.appendingPathComponent(name)) == 0
            else { break }
            moved.append(name)
        }
        return moved
    }

    /// Renames within the volume. It never replaces an existing item and never falls back to copying.
    /// Returns 0 or the error number.
    private static func renameExclusively(_ source: URL, to target: URL) -> Int32 {
        source.path.withCString { from in
            target.path.withCString { renamex_np(from, $0, UInt32(RENAME_EXCL)) == 0 ? 0 : errno }
        }
    }

    /// rmdir removes only an empty folder, so this can never delete profile data.
    private static func removeEmptyFolder(_ folder: URL) {
        _ = folder.path.withCString { Darwin.rmdir($0) }
    }
}
