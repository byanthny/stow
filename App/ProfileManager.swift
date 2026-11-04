import AppKit
import StowCore

/// Keeps track of the profiles and which of them are open. Each open profile is a session with its own lock,
/// store, and windows.
@MainActor
final class ProfileManager {
    private(set) var profiles: [ProfileEntry] = []
    private(set) var sessions: [UUID: ProfileSession] = [:]
    /// The profile that menus act on when no Stow window is key.
    private(set) var lastActiveID: UUID?
    private let catalog: ProfileCatalog
    private let isDemo: Bool
    private var alwaysShowsProfileName = false

    init(dataFolder: URL, isDemo: Bool, catalog: ProfileCatalog? = nil) {
        self.catalog = catalog ?? ProfileCatalog(dataFolder: dataFolder)
        self.isDemo = isDemo
    }

    /// Names show once a second profile exists, or always when the user turns that on.
    var showsProfileNames: Bool { profiles.count > 1 || alwaysShowsProfileName }

    /// The key window's profile, else the most recently active one, else the first open profile.
    var activeSession: ProfileSession? {
        if let window = NSApp.keyWindow, let session = session(owning: window) { return session }
        if let lastActiveID, let session = sessions[lastActiveID] { return session }
        return profiles.lazy.compactMap { self.sessions[$0.id] }.first
    }

    func session(owning window: NSWindow) -> ProfileSession? {
        sessions.values.first { $0.owns(window) }
    }

    /// Opens the data folder profile, or the first listed profile when the data folder holds none. Without any
    /// profile, as in a new installation, the data folder becomes the first profile when it first saves.
    /// Returns false when that profile is open in another process.
    func start() async -> Bool {
        // When the catalog cannot read the folder, the data folder opens and its store reports the problem.
        let snapshot = try? await catalog.load()
        alwaysShowsProfileName = snapshot?.index.alwaysShowProfileName ?? false
        profiles = snapshot?.profiles ?? []
        if profiles.isEmpty { profiles = [await catalog.dataFolderEntry()] }
        return await open(profiles.first(where: \.isDataFolder) ?? profiles[0])
    }

    private func open(_ entry: ProfileEntry) async -> Bool {
        // A profile open here already holds its lock, and a second lock on the same file would be refused.
        if sessions[entry.id] != nil { return true }
        guard let session = ProfileSession(entry: entry, isDemo: isDemo) else { return false }
        sessions[entry.id] = session
        lastActiveID = entry.id
        await session.start()
        return true
    }
}
