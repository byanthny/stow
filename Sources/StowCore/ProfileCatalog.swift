import Foundation

public struct ProfileEntry: Equatable, Sendable {
    public var id: UUID
    public var folder: URL
    public var isDataFolder: Bool
    /// Sanitized, with "Main" or "Unnamed profile" as the fallback. Duplicates are numbered here
    /// for display only; the identity file is untouched.
    public var name: String
    public var color: String
    /// Not in `seenIDs`. Always false for the data folder profile.
    public var isArrival: Bool
}

public enum ProfileIndexStatus: Equatable, Sendable { case absent, loaded, needsReset }

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
    static let mainName = "Main"
    static let unnamedName = "Unnamed profile"
    static let fallbackColor = "#8E8E93"

    let dataFolder: URL
    let currentUserID: uid_t
    let trash: @Sendable (URL) throws -> Void
    private var dataFolderID: UUID?

    public init(
        dataFolder: URL, currentUserID: uid_t = getuid(),
        trash: @escaping @Sendable (URL) throws -> Void = {
            try FileManager.default.trashItem(at: $0, resultingItemURL: nil)
        }
    ) {
        self.dataFolder = dataFolder
        self.currentUserID = currentUserID
        self.trash = trash
    }

    /// Reads the data folder and `profiles/`. Writes nothing.
    public func load() throws -> ProfileCatalogSnapshot {
        let (index, status) = try loadIndex()
        let seen = Set(index.seenIDs)
        var found: [ProfileEntry] = []

        if try hasProfileData(in: dataFolder) {
            let identity = try readIdentity(in: dataFolder, folderID: nil)
            let id = identity?.id ?? mintedDataFolderID()
            found.append(
                ProfileEntry(
                    id: id, folder: dataFolder, isDataFolder: true,
                    name: identity?.name ?? Self.mainName,
                    color: identity?.color ?? Self.fallbackColor, isArrival: false))
        }
        for (id, folder) in try profileFolders() where !found.contains(where: { $0.id == id }) {
            let identity = try readIdentity(in: folder, folderID: id)
            found.append(
                ProfileEntry(
                    id: id, folder: folder, isDataFolder: false,
                    name: identity?.name ?? Self.unnamedName,
                    color: identity?.color ?? Self.fallbackColor, isArrival: !seen.contains(id)))
        }

        let profiles = Self.numbered(Self.ordered(found, by: index.order))
        let hasIndexFile = status != .absent
        return ProfileCatalogSnapshot(
            profiles: profiles, index: index, indexStatus: status,
            isNewInstallation: !hasIndexFile && profiles.isEmpty)
    }

    // MARK: helpers

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
        guard let index = try? ProfileIndex.decode(data) else { return (ProfileIndex(), .needsReset) }
        return (index, .loaded)
    }

    private func hasProfileData(in folder: URL) throws -> Bool {
        let state = try LiveNoteIO.exists(folder.appendingPathComponent("state.json"))
        let identity = try LiveNoteIO.exists(folder.appendingPathComponent(ProfileIdentity.filename))
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
            throw StateError.unreadable
        }
        var result: [(UUID, URL)] = []
        for name in names.sorted() {
            guard name.count == 36, let id = UUID(uuidString: name) else { continue }
            let folder = profilesURL.appendingPathComponent(name, isDirectory: true)
            guard isOwnedDirectory(folder), try hasProfileData(in: folder) else { continue }
            guard !result.contains(where: { $0.0 == id }) else { continue }
            result.append((id, folder))
        }
        return result
    }

    private func isOwnedDirectory(_ url: URL) -> Bool {
        var info = stat()
        guard url.path.withCString({ Darwin.lstat($0, &info) }) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFDIR && info.st_uid == currentUserID
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

    /// Later duplicates get " 2", " 3", and so on, comparing sanitized names ignoring case.
    private static func numbered(_ entries: [ProfileEntry]) -> [ProfileEntry] {
        var taken = Set(entries.map { $0.name.lowercased() })
        var counts: [String: Int] = [:]
        var seen = Set<String>()
        return entries.map { entry in
            var entry = entry
            let key = entry.name.lowercased()
            if seen.insert(key).inserted { return entry }
            var number = counts[key, default: 1]
            var candidate: String
            repeat {
                number += 1
                candidate = "\(entry.name) \(number)"
            } while taken.contains(candidate.lowercased())
            counts[key] = number
            taken.insert(candidate.lowercased())
            entry.name = candidate
            return entry
        }
    }
}
