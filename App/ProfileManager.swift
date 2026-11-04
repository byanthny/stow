import AppKit
import StowCore
import StowExtensionSDK
import StowGitHub
import StowSampleExtension

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
    /// The accessory providers every profile's store runs. Tests replace them.
    private let accessoryProviders: [any AccessoryProvider]
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
        githubOverride: @escaping @MainActor (ProfileEntry) -> (any GitHubClient)? = { _ in nil },
        accessoryProviders: [any AccessoryProvider] = [SyntheticAccessoryProvider()]
    ) {
        self.catalog = catalog ?? ProfileCatalog(dataFolder: dataFolder)
        self.isDemo = isDemo
        self.githubOverride = githubOverride
        self.accessoryProviders = accessoryProviders
    }

    /// Names show once a second profile exists, or always when the user turns that on.
    var showsProfileNames: Bool { profiles.count > 1 || alwaysShowsProfileName }

    /// Whether any open, close, hide, or show is still running or waiting for one before it.
    var hasPendingRequests: Bool { !requests.isEmpty }

    /// The profile menus act on: the key window's, else the most recently active one if it shows, else the first
    /// one that shows, else a hidden one, preferring the most recently active. Never a profile that has stopped.
    /// While Stow is inactive no window is key, so a hidden profile is never taken over one on screen.
    var activeSession: ProfileSession? {
        if let window = NSApp.keyWindow, let session = session(owning: window) { return session }
        let open = profiles.compactMap { sessions[$0.id] }.filter { !$0.isStopped }
        let last = open.first { $0.entry.id == lastActiveID }
        if let last, !last.isHidden { return last }
        return open.first { !$0.isHidden } ?? last ?? open.first
    }

    func session(owning window: NSWindow) -> ProfileSession? {
        sessions.values.first { !$0.isStopped && $0.owns(window) }
    }

    /// Reopens the profiles that were open at quit, each hidden or shown as it was. If none would show, the most
    /// recently active profile shows, else the first one reopened, else the data folder profile (the first listed
    /// one when the data folder holds none), which is all that opens without an index, as after the upgrade.
    /// Without any profile, as in a new installation, the data folder becomes the first profile when it first
    /// saves. A profile another process holds stays closed, and Stow says so once another profile is open.
    /// Returns false when no profile could open.
    func start() async -> Bool {
        // When the catalog cannot read the folder, the data folder opens and its store reports the problem.
        let snapshot = try? await catalog.load()
        alwaysShowsProfileName = snapshot?.index.alwaysShowProfileName ?? false
        profiles = snapshot?.profiles ?? []
        if profiles.isEmpty { profiles = [await catalog.dataFolderEntry()] }
        // An absent index, or one that needs a reset, records no open profiles.
        let recorded = snapshot?.index ?? ProfileIndex()
        var openElsewhere: [ProfileEntry] = []
        for entry in profiles {
            guard let item = recorded.open.first(where: { $0.id == entry.id }) else { continue }
            let opened = await serialized(entry.id) { await self.openSession(entry, hidden: item.isHidden) }
            if !opened { openElsewhere.append(entry) }
        }
        if !sessions.values.contains(where: { !$0.isHidden }) {
            let candidates = [
                profiles.first { $0.id == recorded.lastActiveID },
                profiles.first { sessions[$0.id] != nil },
                profiles.first(where: \.isDataFolder) ?? profiles.first,
            ]
            for entry in candidates.compactMap({ $0 }) where !openElsewhere.contains(where: { $0.id == entry.id }) {
                if let session = sessions[entry.id] {
                    session.show()
                    break
                }
                // A profile tried here was not open at quit, so a refusal goes unsaid; if none opens, the caller
                // hands over to the process holding them.
                let opened = await serialized(entry.id) { await self.openSession(entry) }
                if opened { break }
            }
        }
        let shown = profiles.compactMap { sessions[$0.id] }.filter { !$0.isHidden }
        guard let front = shown.first(where: { $0.entry.id == recorded.lastActiveID }) ?? shown.first else {
            return false
        }
        lastActiveID = front.entry.id
        // The most recently active profile on screen comes forward, as it was at quit.
        if shown.count > 1 { front.show() }
        for entry in openElsewhere { reportOpenElsewhere(entry) }
        return true
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

    /// Saves every open profile for the last time, each on its own, and gives each one's result by profile ID.
    /// Every profile's state is captured before this returns, and the saves need nothing from the main actor,
    /// which AppKit can keep waiting while it decides whether to quit. A profile still loading has nothing to save.
    func terminationSave() -> Task<[UUID: Bool], Never> {
        let saves = sessions.values.filter { !$0.isStopped && $0.store.isLoaded }
            .map { ($0.entry.id, $0.store.terminationSave()) }
        return Task.detached {
            var results: [UUID: Bool] = [:]
            for (id, save) in saves { results[id] = await save.value }
            return results
        }
    }

    /// Keeps Stow running after a quit that could not save every profile. Every open profile saves again,
    /// including one whose final save already closed its repository.
    func cancelTermination() {
        for session in sessions.values where !session.isStopped { session.store.cancelTermination() }
    }

    /// Writes which profiles are open, which of them are hidden, and the most recently active profile, for the
    /// next launch. With no index and only the data folder profile open there is nothing to record, so nothing is
    /// written; an index that needs a reset is left as it is. The work needs nothing from the main actor.
    @discardableResult
    func recordSession() -> Task<Void, Never> {
        let open = profiles.compactMap { entry -> ProfileIndex.OpenProfile? in
            guard let session = sessions[entry.id], !session.isStopped else { return nil }
            return ProfileIndex.OpenProfile(id: entry.id, isHidden: session.isHidden)
        }
        let needsIndex = sessions.values.contains { !$0.isStopped && !$0.entry.isDataFolder }
        let lastActiveID = lastActiveID
        let catalog = catalog
        return Task.detached {
            if !needsIndex, (try? await catalog.load())?.indexStatus != .loaded { return }
            try? await catalog.recordSession(open: open, lastActiveID: lastActiveID)
        }
    }

    /// Takes the profile's lock and opens its windows, out of sight when it reopens hidden. Returns false when
    /// another process holds the lock.
    private func openSession(_ entry: ProfileEntry, hidden: Bool = false) async -> Bool {
        // A profile open here already holds its lock, and a second lock on the same file would be refused.
        if sessions[entry.id] != nil { return true }
        guard
            let session = ProfileSession(
                entry: entry, isDemo: isDemo, githubClient: githubOverride(entry),
                accessoryProviders: accessoryProviders)
        else { return false }
        session.showsName = showsProfileNames
        session.onActivate = { [weak self] in self?.lastActiveID = entry.id }
        sessions[entry.id] = session
        if !hidden { lastActiveID = entry.id }
        await session.start(hidden: hidden)
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
