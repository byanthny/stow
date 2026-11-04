import AppKit
import StowCore
import StowGitHub

/// Keeps track of the profiles and which of them are open. Each open profile is a session with its own lock,
/// store, and windows.
@MainActor
final class ProfileManager {
    private(set) var profiles: [ProfileEntry] = []
    private(set) var sessions: [UUID: ProfileSession] = [:]
    /// The profile that menus act on when no Stow window is key.
    private(set) var lastActiveID: UUID?
    /// Asks whether to close a profile whose changes could not be saved. True closes it without saving.
    var confirmClosingWithoutSaving: @MainActor (ProfileEntry) -> Bool = { entry in
        let alert = NSAlert()
        alert.messageText = "Some changes in \(entry.name) could not be saved"
        alert.informativeText =
            "Keep the profile open to preserve notes currently in memory, or close it without saving those changes."
        alert.addButton(withTitle: "Keep open")
        alert.addButton(withTitle: "Close without saving")
        return alert.runModal() == .alertSecondButtonReturn
    }
    /// Says that a profile someone asked to open is open in another copy of Stow.
    var reportOpenElsewhere: @MainActor (ProfileEntry) -> Void = { entry in
        let alert = NSAlert()
        alert.messageText = "\(entry.name) is open in another copy of Stow"
        alert.informativeText = "Quit the other copy, then open the profile here."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
    private let catalog: ProfileCatalog
    private let isDemo: Bool
    /// A GitHub client for a profile's store in place of the one it finds itself. Tests use it.
    private let githubOverride: @MainActor (ProfileEntry) -> (any GitHubClient)?
    private var alwaysShowsProfileName = false
    /// The newest lifecycle request for each profile. Each request waits for the one before it, so opens, closes,
    /// hides, and shows made in quick succession apply in order and never interleave.
    private var requests: [UUID: Request] = [:]

    private struct Request {
        let token: UUID
        let task: Task<Void, Never>
    }

    init(
        dataFolder: URL, isDemo: Bool, catalog: ProfileCatalog? = nil,
        githubOverride: @escaping @MainActor (ProfileEntry) -> (any GitHubClient)? = { _ in nil }
    ) {
        self.catalog = catalog ?? ProfileCatalog(dataFolder: dataFolder)
        self.isDemo = isDemo
        self.githubOverride = githubOverride
    }

    /// Names show once a second profile exists, or always when the user turns that on.
    var showsProfileNames: Bool { profiles.count > 1 || alwaysShowsProfileName }

    /// The key window's profile, else the most recently active one, else the first open profile. Never a profile
    /// that has stopped.
    var activeSession: ProfileSession? {
        if let window = NSApp.keyWindow, let session = session(owning: window) { return session }
        if let lastActiveID, let session = sessions[lastActiveID], !session.isStopped { return session }
        return profiles.lazy.compactMap { self.sessions[$0.id] }.first { !$0.isStopped }
    }

    func session(owning window: NSWindow) -> ProfileSession? {
        sessions.values.first { !$0.isStopped && $0.owns(window) }
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
        let first = profiles.first(where: \.isDataFolder) ?? profiles[0]
        // When another process holds this profile, the caller hands over to it, so nothing is said here.
        return await serialized(first.id) { await self.openSession(first) }
    }

    /// Opens a profile, or brings its windows forward when it is already open. Returns false, after saying so,
    /// when another copy of Stow has the profile open.
    @discardableResult
    func open(_ id: UUID) async -> Bool {
        await serialized(id) {
            if let session = self.sessions[id] {
                self.lastActiveID = id
                session.show()
                return true
            }
            guard let entry = self.profiles.first(where: { $0.id == id }) else { return false }
            guard await self.openSession(entry) else {
                self.reportOpenElsewhere(entry)
                return false
            }
            return true
        }
    }

    /// Orders out a profile's windows and pauses its GitHub refreshes and accessories. It stays open.
    func hide(_ id: UUID) {
        whenIdle(id) { self.sessions[id]?.hide() }
    }

    /// Shows a hidden profile's windows as they were, brings the profile forward, and refreshes it.
    func show(_ id: UUID) {
        whenIdle(id) {
            guard let session = self.sessions[id] else { return }
            self.lastActiveID = id
            session.show()
        }
    }

    /// Opens a profile if needed and brings its windows forward, then hides the profile it leaves unless that
    /// profile turned off Hide when switching away. Windows move at once, with no animation to wait for.
    func switchTo(_ id: UUID) async {
        let source = activeSession
        guard await open(id), let source, source.entry.id != id, sessions[source.entry.id] === source,
            source.store.state.hidesWhenSwitchingAway
        else { return }
        hide(source.entry.id)
    }

    /// Saves a profile, then closes its windows, stops its refreshes, accessories, and watchers, and releases its
    /// lock. Its data stays on disk. When the save fails, the person can keep the profile open, which returns
    /// false, or close it without saving.
    func close(_ id: UUID) async -> Bool {
        await serialized(id) {
            guard let session = self.sessions[id] else { return true }
            if !(await session.store.flush()), !self.confirmClosingWithoutSaving(session.entry) { return false }
            // Menus and other requests stop finding the profile before it stops.
            self.sessions[id] = nil
            await session.close()
            return true
        }
    }

    /// Takes the profile's lock and opens its windows. Returns false when another process holds the lock.
    private func openSession(_ entry: ProfileEntry) async -> Bool {
        // A profile open here already holds its lock, and a second lock on the same file would be refused.
        if sessions[entry.id] != nil { return true }
        guard let session = ProfileSession(entry: entry, isDemo: isDemo, githubClient: githubOverride(entry)) else {
            return false
        }
        session.showsName = showsProfileNames
        session.onActivate = { [weak self] in self?.lastActiveID = entry.id }
        sessions[entry.id] = session
        lastActiveID = entry.id
        await session.start()
        // Seen only once its arrival settings are on disk; otherwise the copied settings would apply next time.
        let store = session.store
        if entry.isArrival, !session.isStopped, store.saveError == nil, !store.storageNeedsRecovery {
            await markSeen(entry.id)
        }
        return true
    }

    /// Records that this Mac has seen a profile, so it opens normally from now on. If the index cannot be
    /// written, the profile opens as new again next time, with GitHub and accessories off.
    private func markSeen(_ id: UUID) async {
        guard (try? await catalog.markSeen(id)) != nil, let index = profiles.firstIndex(where: { $0.id == id })
        else { return }
        profiles[index].isArrival = false
    }

    /// Runs `body` once every earlier request for the profile has finished, and returns its result.
    private func serialized<T: Sendable>(_ id: UUID, _ body: @escaping @MainActor () async -> T) async -> T {
        let previous = requests[id]?.task
        let token = UUID()
        let work = Task { @MainActor in
            await previous?.value
            return await body()
        }
        requests[id] = Request(token: token, task: Task { _ = await work.value })
        let result = await work.value
        if requests[id]?.token == token { requests[id] = nil }
        return result
    }

    /// Runs `body` now when nothing is pending for the profile, otherwise after the pending requests.
    private func whenIdle(_ id: UUID, _ body: @escaping @MainActor () -> Void) {
        guard let previous = requests[id]?.task else { return body() }
        let token = UUID()
        requests[id] = Request(
            token: token,
            task: Task { @MainActor in
                await previous.value
                body()
                if self.requests[id]?.token == token { self.requests[id] = nil }
            })
    }
}
