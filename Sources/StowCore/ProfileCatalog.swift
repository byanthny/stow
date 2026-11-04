import Foundation

public struct ProfileEntry: Equatable, Sendable {
    public var id: UUID
    public var folder: URL
    public var isDataFolder: Bool
    /// Sanitized, with "Stow" or "Unnamed profile" as the fallback. Names that look alike are numbered here
    /// for display only; the identity file is untouched.
    public var name: String
    public var color: String
    public var icon: ProfileIcon?
    /// Not in `seenIDs`. Always false for the data folder profile.
    public var isArrival: Bool
}

public enum ProfileIndexStatus: Equatable, Sendable {
    case absent, loaded, needsReset
    /// Saved by a newer version of Stow. It is kept as it is and, like a list that needs a reset, blocks changes.
    case newer

    /// Profiles can't change, and their order and open windows aren't saved, until the list is reset.
    public var blocksChanges: Bool { self == .needsReset || self == .newer }
}

public struct ProfileCatalogSnapshot: Equatable, Sendable {
    /// Index order first, then by name.
    public var profiles: [ProfileEntry]
    public var index: ProfileIndex
    public var indexStatus: ProfileIndexStatus
    public var isNewInstallation: Bool
}

/// Finds profiles by looking at folders. The index never decides which profiles exist.
public actor ProfileCatalog {
    public static let profilesDirectoryName = "profiles"
    /// The data folder profile's name until the user renames it, so a single profile still reads "Stow".
    static let dataFolderName = "Stow"
    static let unnamedName = "Unnamed profile"
    static let fallbackColor = "#8E8E93"

    let dataFolder: URL
    let currentUserID: uid_t
    /// Moves a folder to the Trash. Injected so tests never touch the user's Trash.
    let moveToTrash: @Sendable (URL) throws -> Void
    /// The owner of a path, without following links. A test seam for the per-folder owner check.
    let ownerOf: @Sendable (URL) -> uid_t?
    /// Whether a profile file exists, without following links; throws when it cannot be checked. A test seam for
    /// a folder that stops being readable.
    let fileExists: @Sendable (URL) throws -> Bool
    /// The ID minted for a data folder profile without a readable identity. Cleared when that profile is trashed.
    var dataFolderID: UUID?

    public init(
        dataFolder: URL, currentUserID: uid_t = getuid(),
        trash: @escaping @Sendable (URL) throws -> Void = {
            try FileManager.default.trashItem(at: $0, resultingItemURL: nil)
        }
    ) {
        self.init(
            dataFolder: dataFolder, currentUserID: currentUserID, trash: trash, ownerOf: Self.fileOwner)
    }

    init(
        dataFolder: URL, currentUserID: uid_t, trash: @escaping @Sendable (URL) throws -> Void,
        ownerOf: @escaping @Sendable (URL) -> uid_t?,
        fileExists: @escaping @Sendable (URL) throws -> Bool = { try LiveNoteIO.exists($0) }
    ) {
        self.dataFolder = dataFolder
        self.currentUserID = currentUserID
        self.moveToTrash = trash
        self.ownerOf = ownerOf
        self.fileExists = fileExists
    }

    /// Reads the data folder and `profiles/`. Writes nothing, except to finish a deletion of the data folder
    /// profile that a crash interrupted.
    public func load() throws -> ProfileCatalogSnapshot {
        finishInterruptedMove()
        let (index, status) = try loadIndex()
        let seen = Set(index.seenIDs)
        var found: [ProfileEntry] = []

        if try hasProfileData(in: dataFolder) { found.append(dataFolderEntry()) }
        for (id, folder) in try profileFolders() where !found.contains(where: { $0.id == id }) {
            let identity = try readIdentity(in: folder, folderID: id)
            found.append(
                ProfileEntry(
                    id: id, folder: folder, isDataFolder: false,
                    name: identity?.name ?? Self.unnamedName,
                    color: identity?.color ?? Self.fallbackColor, icon: identity?.icon, isArrival: !seen.contains(id)))
        }

        let profiles = Self.numbered(Self.ordered(found, by: index.order))
        let hasIndexFile = status != .absent
        return ProfileCatalogSnapshot(
            profiles: profiles, index: index, indexStatus: status,
            isNewInstallation: !hasIndexFile && profiles.isEmpty)
    }

    /// The data folder profile, also before its first save creates it. Without an identity file it takes the ID
    /// this catalog minted, the same one `load()` reports once the profile exists. Writes nothing.
    public func dataFolderEntry() -> ProfileEntry {
        let identity = try? readIdentity(in: dataFolder, folderID: nil)
        return ProfileEntry(
            id: identity?.id ?? mintedDataFolderID(), folder: dataFolder, isDataFolder: true,
            name: identity?.name ?? Self.dataFolderName,
            color: identity?.color ?? Self.fallbackColor, icon: identity?.icon, isArrival: false)
    }

    // MARK: changes

    /// Makes a new empty profile folder with its identity, then records it in the index. Returns the profile as it
    /// was made, without reading the folder again, so nothing can fail once it exists.
    public func createProfile(name: String, color: String) throws -> ProfileEntry {
        let snapshot = try writableSnapshot()
        let clean = try Self.validName(name)
        guard ProfileIdentity.isValidColor(color) else { throw ProfileError.invalidColor }
        try requireUnique(clean, among: snapshot.profiles, excluding: nil)

        let id = UUID()
        let folder = profilesURL.appendingPathComponent(id.uuidString, isDirectory: true)
        try wrapping {
            try LiveNoteIO.ensureDirectory(profilesURL)
            try LiveNoteIO.ensureDirectory(folder)
        }
        do {
            try writeIdentity(ProfileIdentity(id: id, name: clean, color: color), in: folder)
            var index = snapshot.index
            index.order = Self.merged(index.order, with: snapshot.profiles.map(\.id) + [id])
            Self.insert(id, into: &index.seenIDs)
            try writeIndex(index, after: snapshot)
        } catch {
            // The folder is ours and still empty of notes; leave nothing for discovery to find.
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        return ProfileEntry(
            id: id, folder: folder, isDataFolder: false, name: clean, color: color, icon: nil, isArrival: false)
    }

    /// Renames a profile. Like every identity change, it refuses an identity file a newer build wrote.
    public func rename(_ id: UUID, to name: String) throws {
        let snapshot = try writableSnapshot()
        let entry = try entry(id, in: snapshot)
        try requireCurrentIdentity(in: entry.folder)
        let clean = try Self.validName(name)
        try requireUnique(clean, among: snapshot.profiles, excluding: id)
        try writeIdentity(
            ProfileIdentity(id: id, name: clean, color: entry.color, icon: entry.icon), in: entry.folder)
    }

    public func setColor(_ id: UUID, to color: String) throws {
        let snapshot = try writableSnapshot()
        let entry = try entry(id, in: snapshot)
        guard ProfileIdentity.isValidColor(color) else { throw ProfileError.invalidColor }
        try requireCurrentIdentity(in: entry.folder)
        // The stored name is the profile's own, not a number added for display.
        let name = try storedName(of: entry)
        try writeIdentity(ProfileIdentity(id: id, name: name, color: color, icon: entry.icon), in: entry.folder)
    }

    /// Sets or clears the profile's icon. Like `setColor`, it refuses to replace an identity file it cannot read.
    public func setIcon(_ id: UUID, to icon: ProfileIcon?) throws {
        let snapshot = try writableSnapshot()
        let entry = try entry(id, in: snapshot)
        if let icon, ProfileIcon.validated(icon) == nil { throw ProfileError.invalidIcon }
        try requireCurrentIdentity(in: entry.folder)
        let name = try storedName(of: entry)
        try writeIdentity(ProfileIdentity(id: id, name: name, color: entry.color, icon: icon), in: entry.folder)
    }

    /// Moves a profile by `offset` places in the list, stopping at either end. Profiles skipped right now,
    /// such as one whose folder cannot be read, keep their saved places.
    public func move(_ id: UUID, by offset: Int) throws {
        let snapshot = try writableSnapshot()
        let shown = snapshot.profiles.map(\.id)
        var ids = shown
        guard let position = ids.firstIndex(of: id) else { throw ProfileError.notFound }
        ids.remove(at: position)
        let (shifted, overflow) = position.addingReportingOverflow(offset)
        let target = overflow ? (offset < 0 ? 0 : ids.count) : min(max(shifted, 0), ids.count)
        ids.insert(id, at: target)
        // The shown profiles take their new order in the places shown profiles held; the others stay put.
        let isShown = Set(shown)
        var arranged = ids.makeIterator()
        var index = snapshot.index
        index.order = Self.merged(index.order, with: shown).map { isShown.contains($0) ? arranged.next() ?? $0 : $0 }
        try writeIndex(index, after: snapshot)
    }

    /// Records which profiles are open and which was last active. Profiles that no longer exist are dropped.
    /// Writes nothing when the record is unchanged, so a quit that changes nothing leaves the index alone.
    public func recordSession(open: [ProfileIndex.OpenProfile], lastActiveID: UUID?) throws {
        let snapshot = try writableSnapshot()
        let known = Set(snapshot.profiles.map(\.id))
        var listed = Set<UUID>()
        var index = snapshot.index
        index.open = open.filter { known.contains($0.id) && listed.insert($0.id).inserted }
        index.lastActiveID = lastActiveID.flatMap { known.contains($0) ? $0 : nil }
        guard index != snapshot.index else { return }
        try writeIndex(index, after: snapshot)
    }

    public func markSeen(_ id: UUID) throws {
        let snapshot = try writableSnapshot()
        guard !snapshot.index.seenIDs.contains(id) else { return }
        var index = snapshot.index
        index.seenIDs.append(id)
        try writeIndex(index, after: snapshot)
    }

    public func setAlwaysShowProfileName(_ value: Bool) throws {
        let snapshot = try writableSnapshot()
        guard snapshot.index.alwaysShowProfileName != value else { return }
        var index = snapshot.index
        index.alwaysShowProfileName = value
        try writeIndex(index, after: snapshot)
    }

    /// Saves the update settings; writes nothing when they're unchanged.
    public func setUpdateSettings(_ settings: UpdateSettings) throws {
        let snapshot = try writableSnapshot()
        guard snapshot.index.updates != settings else { return }
        var index = snapshot.index
        index.updates = settings
        try writeIndex(index, after: snapshot)
    }

    /// Moves the unusable index aside, byte for byte, and starts a new one. The seen list starts empty, so every
    /// profile outside the data folder is an arrival again and opens once with GitHub and accessories off.
    public func resetIndex() throws -> URL {
        let snapshot = try load()
        guard snapshot.indexStatus.blocksChanges else { throw ProfileError.notFound }
        let stamp = Self.backupStamp.string(from: Date())
        let backup = dataFolder.appendingPathComponent(
            "profiles-backup-\(stamp)-\(UUID().uuidString.prefix(8)).json")
        let moved = indexURL.path.withCString { source in
            backup.path.withCString { Darwin.rename(source, $0) }
        }
        guard moved == 0 else { throw ProfileError.unwritable }
        var index = ProfileIndex()
        index.order = snapshot.profiles.map(\.id)
        do {
            var absent = snapshot
            absent.indexStatus = .absent
            try writeIndex(index, after: absent)
        } catch {
            _ = backup.path.withCString { source in indexURL.path.withCString { Darwin.rename(source, $0) } }
            throw error
        }
        return backup
    }

    // MARK: helpers

    private static let backupStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    private static func fileOwner(_ url: URL) -> uid_t? {
        var info = stat()
        guard url.path.withCString({ Darwin.lstat($0, &info) }) == 0 else { return nil }
        return info.st_uid
    }

    func writableSnapshot() throws -> ProfileCatalogSnapshot {
        let snapshot = try load()
        if snapshot.indexStatus.blocksChanges { throw ProfileError.indexNeedsReset }
        return snapshot
    }

    func entry(_ id: UUID, in snapshot: ProfileCatalogSnapshot) throws -> ProfileEntry {
        guard let entry = snapshot.profiles.first(where: { $0.id == id }) else { throw ProfileError.notFound }
        return entry
    }

    private static func validName(_ raw: String) throws -> String {
        guard let clean = ProfileIdentity.sanitizedName(raw) else { throw ProfileError.emptyName }
        return clean
    }

    /// Names that look alike count as the same, so menus and window titles stay distinguishable.
    private func requireUnique(_ name: String, among entries: [ProfileEntry], excluding id: UUID?) throws {
        let key = ProfileIdentity.comparisonKey(name)
        if entries.contains(where: { $0.id != id && ProfileIdentity.comparisonKey($0.name) == key }) {
            throw ProfileError.duplicateName
        }
    }

    /// Refuses to replace an identity file a newer build wrote, even one whose fields this build cannot read.
    func requireCurrentIdentity(in folder: URL) throws {
        let file = folder.appendingPathComponent(ProfileIdentity.filename)
        guard let data = try? LiveNoteIO.read(file, maximumBytes: ProfileIdentity.maximumBytes),
            let version = ProfileIdentity.storedVersion(data), version > ProfileIdentity.currentVersion
        else { return }
        throw ProfileError.newerIdentity(version)
    }

    /// The name in the identity file, which differs from the displayed name when a duplicate is numbered.
    /// A folder without an identity file gets the fallback name. An identity file that exists but cannot be
    /// read may still hold the real name, so it is refused rather than replaced.
    private func storedName(of entry: ProfileEntry) throws -> String {
        let file = entry.folder.appendingPathComponent(ProfileIdentity.filename)
        // A file that cannot even be checked counts as present, so it is never replaced.
        guard (try? LiveNoteIO.exists(file)) ?? true else {
            return entry.isDataFolder ? Self.dataFolderName : Self.unnamedName
        }
        guard let identity = try readIdentity(in: entry.folder, folderID: entry.isDataFolder ? nil : entry.id)
        else { throw ProfileError.invalidIdentity }
        return identity.name
    }

    func writeIdentity(_ identity: ProfileIdentity, in folder: URL) throws {
        try requireCurrentIdentity(in: folder)
        guard let data = try? JSONEncoder().encode(identity) else { throw ProfileError.unwritable }
        try wrapping {
            try LiveNoteIO.write(data, to: folder.appendingPathComponent(ProfileIdentity.filename))
        }
    }

    /// Writes the index atomically. The first write also saves the data folder profile's identity,
    /// so the ID shown to the app stays the same across launches.
    func writeIndex(_ index: ProfileIndex, after snapshot: ProfileCatalogSnapshot) throws {
        if let main = snapshot.profiles.first(where: \.isDataFolder), snapshot.indexStatus == .absent,
            try !wrapping({ try LiveNoteIO.exists(dataFolder.appendingPathComponent(ProfileIdentity.filename)) })
        {
            try writeIdentity(
                ProfileIdentity(id: main.id, name: Self.dataFolderName, color: main.color), in: dataFolder)
        }
        guard let data = Self.encode(index) else { throw ProfileError.unwritable }
        try wrapping {
            try LiveNoteIO.ensureDirectory(dataFolder)
            try LiveNoteIO.write(data, to: indexURL)
        }
    }

    private static func encode(_ index: ProfileIndex) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(index)
    }

    func wrapping<T>(_ body: () throws -> T) throws -> T {
        do { return try body() } catch is StateError { throw ProfileError.unwritable }
    }

    private static func insert(_ id: UUID, into ids: inout [UUID]) {
        if !ids.contains(id) { ids.append(id) }
    }

    /// `base` first, then any of `extra` not already listed, without repeats.
    private static func merged(_ base: [UUID], with extra: [UUID]) -> [UUID] {
        var seen = Set<UUID>()
        return (base + extra).filter { seen.insert($0).inserted }
    }

    var indexURL: URL { dataFolder.appendingPathComponent(ProfileIndex.filename) }
    var profilesURL: URL { dataFolder.appendingPathComponent(Self.profilesDirectoryName, isDirectory: true) }

    private func mintedDataFolderID() -> UUID {
        if let dataFolderID { return dataFolderID }
        let id = UUID()
        dataFolderID = id
        return id
    }

    private func loadIndex() throws -> (ProfileIndex, ProfileIndexStatus) {
        let data: Data?
        do {
            data = try LiveNoteIO.read(indexURL, maximumBytes: ProfileIndex.maximumBytes)
        } catch {
            return (ProfileIndex(), .needsReset)
        }
        guard let data else { return (ProfileIndex(), .absent) }
        do {
            return (try ProfileIndex.decode(data), .loaded)
        } catch ProfileError.newerIndex(_) {
            return (ProfileIndex(), .newer)
        } catch {
            return (ProfileIndex(), .needsReset)
        }
    }

    private func hasProfileData(in folder: URL) throws -> Bool {
        let state = try fileExists(folder.appendingPathComponent("state.json"))
        let identity = try fileExists(folder.appendingPathComponent(ProfileIdentity.filename))
        return state || identity
    }

    /// An unreadable or invalid identity counts as none, so a bad file never hides the profile.
    private func readIdentity(in folder: URL, folderID: UUID?) throws -> ProfileIdentity? {
        guard
            let data = try? LiveNoteIO.read(
                folder.appendingPathComponent(ProfileIdentity.filename),
                maximumBytes: ProfileIdentity.maximumBytes)
        else { return nil }
        return try? ProfileIdentity.decode(data, folderID: folderID)
    }

    /// Real folders owned by the current user, named by a UUID, that hold profile data.
    private func profileFolders() throws -> [(UUID, URL)] {
        guard isOwnedDirectory(profilesURL) else { return [] }
        let names: [String]
        do { names = try FileManager.default.contentsOfDirectory(atPath: profilesURL.path) } catch {
            return []
        }
        var result: [(UUID, URL)] = []
        for name in names.sorted() {
            guard name.count == 36, let id = UUID(uuidString: name) else { continue }
            let folder = profilesURL.appendingPathComponent(name, isDirectory: true)
            // One unreadable folder must not hide the others.
            guard isOwnedDirectory(folder), (try? hasProfileData(in: folder)) == true else { continue }
            guard !result.contains(where: { $0.0 == id }) else { continue }
            result.append((id, folder))
        }
        return result
    }

    func isOwnedDirectory(_ url: URL) -> Bool {
        var info = stat()
        guard url.path.withCString({ Darwin.lstat($0, &info) }) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFDIR && ownerOf(url) == currentUserID
    }

    private static func ordered(_ entries: [ProfileEntry], by order: [UUID]) -> [ProfileEntry] {
        var remaining = entries
        var result: [ProfileEntry] = []
        for id in order {
            if let position = remaining.firstIndex(where: { $0.id == id }) {
                result.append(remaining.remove(at: position))
            }
        }
        remaining.sort {
            let left = $0.name.lowercased(), right = $1.name.lowercased()
            return left == right ? $0.id.uuidString < $1.id.uuidString : left < right
        }
        return result + remaining
    }

    /// Later duplicates get " 2", " 3", and so on, comparing names as they look on screen.
    private static func numbered(_ entries: [ProfileEntry]) -> [ProfileEntry] {
        var taken = Set(entries.map { ProfileIdentity.comparisonKey($0.name) })
        var counts: [String: Int] = [:]
        var seen = Set<String>()
        return entries.map { entry in
            var entry = entry
            let key = ProfileIdentity.comparisonKey(entry.name)
            if seen.insert(key).inserted { return entry }
            var number = counts[key, default: 1]
            var candidate: String
            repeat {
                number += 1
                candidate = "\(entry.name) \(number)"
            } while taken.contains(ProfileIdentity.comparisonKey(candidate))
            counts[key] = number
            taken.insert(ProfileIdentity.comparisonKey(candidate))
            entry.name = candidate
            return entry
        }
    }
}
