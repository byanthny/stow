import AppKit
import Observation
import StowCore
import StowExtensionSDK
import StowGitHub
import StowSampleExtension

/// Keeps track of the profiles and which of them are open. Each open profile is a session with its own lock,
/// store, and windows. Views observe the profile list, so Settings and each board follow its changes.
@MainActor @Observable
final class ProfileManager {
    private(set) var profiles: [ProfileEntry] = [] {
        didSet { onProfilesChange?() }
    }
    /// Called when the profile list, its order, a name, or whether names show changes, so menus can rebuild.
    @ObservationIgnored var onProfilesChange: (() -> Void)?
    private(set) var sessions: [UUID: ProfileSession] = [:]
    /// The profile that menus act on when no Stow window is key.
    private(set) var lastActiveID: UUID?
    /// Settings → Profiles → Always show profile name, which the index keeps for every profile.
    private(set) var alwaysShowsProfileName = false {
        didSet { if alwaysShowsProfileName != oldValue { onProfilesChange?() } }
    }
    /// The index cannot be read, or a newer Stow saved it. Settings offers Reset profile list, and profile changes
    /// wait for it.
    private(set) var indexNeedsReset = false
    /// A newer version of Stow saved the index, so updating Stow is the better fix than a reset.
    private(set) var indexIsNewer = false
    /// The profile whose Settings shows the New profile sheet.
    var newProfileRequest: UUID?
    /// Set once `start()` has shown a profile. From then on a quit records which profiles are open, even none.
    @ObservationIgnored private(set) var hasStarted = false
    /// Asks whether to close a profile whose changes could not be saved. True closes it without saving.
    @ObservationIgnored var confirmClosingWithoutSaving: @MainActor (ProfileEntry) -> Bool = { entry in
        let alert = NSAlert()
        alert.messageText = "Some changes in \(entry.name) could not be saved"
        alert.informativeText =
            "Keep the profile open to preserve notes currently in memory, or close it without saving those changes."
        alert.addButton(withTitle: "Keep open")
        alert.addButton(withTitle: "Close without saving")
        return alert.runModal() == .alertSecondButtonReturn
    }
    /// Says that a profile someone asked to open is open in another copy of Stow.
    @ObservationIgnored var reportOpenElsewhere: @MainActor (ProfileEntry) -> Void = { entry in
        let alert = NSAlert()
        alert.messageText = "\(entry.name) is open in another copy of Stow"
        alert.informativeText = "Quit the other copy, then open the profile here."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
    /// Says that a profile someone asked to open is no longer where Stow found it, such as one moved to the Trash
    /// in Finder after the menus listed it.
    @ObservationIgnored var reportNotFound: @MainActor (ProfileEntry) -> Void = { entry in
        let alert = NSAlert()
        alert.messageText = "Stow can’t find \(entry.name)"
        alert.informativeText =
            "Its folder was moved or deleted. If it’s in the Trash, put it back, then open it again."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
    /// Says that the profile folders can't be read, so Stow can't tell whether a profile someone asked to open is
    /// still there.
    @ObservationIgnored var reportUnreadable: @MainActor (ProfileEntry) -> Void = { entry in
        let alert = NSAlert()
        alert.messageText = "Stow can’t read its profile folders"
        alert.informativeText =
            "\(entry.name) stays closed. Check that Stow’s data folder can be read, then open the profile again."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
    /// Says that a launch found profile data but no profile it could list, so it opened nothing rather than start a
    /// new first profile beside the others.
    @ObservationIgnored var reportNoProfiles: @MainActor () -> Void = {
        let alert = NSAlert()
        alert.messageText = "Stow can’t find any profiles"
        alert.informativeText =
            "Stow has a profile list but can’t read any profile folder. Put a deleted profile back from the Trash, or check that the data folder can be read, then open Stow again."
        alert.addButton(withTitle: "Quit")
        alert.runModal()
    }
    /// Says why a deletion failed when the Settings window that asked for it has closed, as when a profile's own
    /// Settings deletes it, so the reason is never lost with the window.
    @ObservationIgnored var reportDeletionFailure: @MainActor (ProfileEntry, any Error) -> Void = { entry, error in
        guard let reason = profileProblem(error, name: entry.name) else { return }
        let alert = NSAlert()
        alert.messageText = "\(entry.name) couldn’t be deleted"
        alert.informativeText = reason
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
    private let catalog: ProfileCatalog
    private let isDemo: Bool
    /// A GitHub client for a profile's store in place of the one it finds itself. Tests use it.
    private let githubOverride: @MainActor (ProfileEntry) -> (any GitHubClient)?
    /// The accessory providers every profile's store runs. Tests replace them.
    private let accessoryProviders: [any AccessoryProvider]
    /// Makes the client for a `gh` location. Tests replace it so none depends on a real `gh`.
    private let githubClientMaker: @MainActor (URL) -> any GitHubClient
    /// One client per `gh` location, so a rate-limit backoff pauses every profile that uses it.
    private var githubClients: [String: any GitHubClient] = [:]
    /// The newest request for each profile. Each request waits for the one before it, so opens, closes, hides,
    /// shows, and changes to the profile's folder made in quick succession apply in order and never interleave.
    @ObservationIgnored private var requests: [UUID: Request] = [:]

    private struct Request {
        let token: UUID
        let task: Task<Void, Never>
    }

    init(
        dataFolder: URL, isDemo: Bool, catalog: ProfileCatalog? = nil,
        githubOverride: @escaping @MainActor (ProfileEntry) -> (any GitHubClient)? = { _ in nil },
        accessoryProviders: [any AccessoryProvider] = [SyntheticAccessoryProvider()],
        githubClientMaker: @escaping @MainActor (URL) -> any GitHubClient = { GHClient(executableURL: $0) }
    ) {
        self.githubClientMaker = githubClientMaker
        self.catalog = catalog ?? ProfileCatalog(dataFolder: dataFolder)
        self.isDemo = isDemo
        self.githubOverride = githubOverride
        self.accessoryProviders = accessoryProviders
    }

    /// The client every profile using this `gh` location shares. Its backoff is the location's, not a profile's.
    func githubClient(for executable: URL) -> any GitHubClient {
        let key = executable.resolvingSymlinksInPath().path
        if let existing = githubClients[key] { return existing }
        let client = githubClientMaker(executable)
        githubClients[key] = client
        return client
    }

    /// Names and colors show once a second profile exists, or always when the user turns that on.
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
    /// Only a new installation, with no index and no profile data anywhere, gets a first profile, which the data
    /// folder becomes when it first saves. When profile data exists but no profile can be listed, nothing opens
    /// and Stow says so, rather than start a new, empty profile beside the others. A profile another process
    /// holds stays closed, and Stow says so once another profile is open. Returns false when no profile opened.
    func start() async -> Bool {
        // When the catalog cannot read the data folder at all, the data folder opens and its store reports the
        // problem without writing.
        let snapshot = try? await catalog.load()
        alwaysShowsProfileName = snapshot?.index.alwaysShowProfileName ?? false
        indexNeedsReset = snapshot?.indexStatus.blocksChanges == true
        indexIsNewer = snapshot?.indexStatus == .newer
        profiles = snapshot?.profiles ?? []
        if profiles.isEmpty {
            guard snapshot?.isNewInstallation ?? true else {
                reportNoProfiles()
                return false
            }
            profiles = [await catalog.dataFolderEntry()]
        }
        // An absent index, or one that needs a reset, records no open profiles.
        let recorded = snapshot?.index ?? ProfileIndex()
        var openElsewhere: [ProfileEntry] = []
        for entry in profiles {
            guard let item = recorded.open.first(where: { $0.id == entry.id }) else { continue }
            let opened = await serialized(entry.id) { await self.openSession(entry, hidden: item.isHidden) }
            if opened == .heldElsewhere { openElsewhere.append(entry) }
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
                if opened == .opened { break }
            }
        }
        let shown = profiles.compactMap { sessions[$0.id] }.filter { !$0.isHidden }
        guard let front = shown.first(where: { $0.entry.id == recorded.lastActiveID }) ?? shown.first else {
            return false
        }
        lastActiveID = front.entry.id
        hasStarted = true
        // The most recently active profile on screen comes forward, as it was at quit.
        if shown.count > 1 { front.show() }
        for entry in openElsewhere { reportOpenElsewhere(entry) }
        return true
    }

    /// Opens a profile, or brings its windows forward when it is already open. Returns false, after saying so,
    /// when another copy of Stow has the profile open, or when its folder is gone, such as one moved to the Trash
    /// after the menus listed it; the list then drops it.
    @discardableResult
    func open(_ id: UUID) async -> Bool {
        await serialized(id) {
            if let session = self.sessions[id] {
                self.lastActiveID = id
                session.show()
                return true
            }
            guard let entry = self.profiles.first(where: { $0.id == id }) else { return false }
            switch await self.openSession(entry) {
            case .opened: return true
            case .heldElsewhere: self.reportOpenElsewhere(entry)
            case .notFound: self.reportNotFound(entry)
            case .unreadable: self.reportUnreadable(entry)
            }
            return false
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
    /// profile turned off Hide when switching away. The profile left is `sourceID`'s when given, as for a board's
    /// profile menu, else the active one. Windows move at once, with no animation to wait for.
    func switchTo(_ id: UUID, from sourceID: UUID? = nil) async {
        let source = sourceID.flatMap { sessions[$0] } ?? activeSession
        guard await open(id), let source, source.entry.id != id, sessions[source.entry.id] === source,
            source.store.state.hidesWhenSwitchingAway
        else { return }
        hide(source.entry.id)
    }

    /// Switches to the next profile (offset 1) or the previous one (offset -1) in profile order, wrapping around.
    /// With no active profile, Next goes to the first and Previous to the last.
    func switchRelative(_ offset: Int) async {
        guard profiles.count > 1 else { return }
        let current = (activeSession?.entry.id ?? lastActiveID).flatMap { id in profiles.firstIndex { $0.id == id } }
        let start = current ?? (offset > 0 ? -1 : 0)
        let count = profiles.count
        await switchTo(profiles[((start + offset) % count + count) % count].id)
    }

    /// Shows or opens the most recently active profile, as the Dock icon does. An open profile shows at once.
    func reopenMostRecent() {
        guard let target = profiles.first(where: { $0.id == lastActiveID }) ?? profiles.first else { return }
        if sessions[target.id] != nil {
            show(target.id)
        } else {
            Task { await open(target.id) }
        }
    }

    /// Shows the New profile sheet in a profile's Settings: the given profile's, else the active one's. With no
    /// profile open, the most recently active one opens to hold it.
    func requestNewProfile(from id: UUID? = nil) {
        if let session = id.flatMap({ sessions[$0] }) ?? activeSession, !session.isStopped {
            return presentNewProfile(in: session)
        }
        guard let target = profiles.first(where: { $0.id == lastActiveID }) ?? profiles.first else { return }
        Task {
            guard await open(target.id), let session = sessions[target.id] else { return }
            presentNewProfile(in: session)
        }
    }

    private func presentNewProfile(in session: ProfileSession) {
        session.showSettings()
        newProfileRequest = session.entry.id
    }

    /// The board header's profile menu for a profile: the other profiles to switch to, Hide and Close, then New
    /// profile… and Profile settings…. With one profile, only the last two.
    func profileMenu(for id: UUID) -> [[ProfileMenuItem]] {
        var sections: [[ProfileMenuItem]] = []
        if profiles.count > 1 {
            sections.append(
                profiles.filter { $0.id != id }.map { entry in
                    ProfileMenuItem(title: entry.name, state: menuState(of: entry.id)) { [weak self] in
                        Task { await self?.switchTo(entry.id, from: id) }
                    }
                })
            sections.append([
                ProfileMenuItem(title: "Hide profile") { [weak self] in self?.hide(id) },
                ProfileMenuItem(title: "Close profile") { [weak self] in Task { _ = await self?.close(id) } },
            ])
        }
        sections.append([
            ProfileMenuItem(title: "New profile…") { [weak self] in self?.requestNewProfile(from: id) },
            ProfileMenuItem(title: "Profile settings…") { [weak self] in self?.sessions[id]?.showSettings() },
        ])
        return sections
    }

    /// A profile's mark in profile menus: on while it shows, mixed while hidden, off while closed.
    func menuState(of id: UUID) -> NSControl.StateValue {
        guard let session = sessions[id], !session.isStopped else { return .off }
        return session.isHidden ? .mixed : .on
    }

    /// Reads the profile list again, so a new profile, order, name, color, or icon, or the display setting,
    /// reaches the menus, the open profiles' windows, and Settings. When the list cannot be read it stays as it
    /// was and the error is thrown.
    func reloadProfiles() async throws {
        apply(try await catalog.load())
    }

    /// Takes the list and display setting from a fresh read of the folders, and passes them to the open profiles.
    private func apply(_ snapshot: ProfileCatalogSnapshot) {
        alwaysShowsProfileName = snapshot.index.alwaysShowProfileName
        indexNeedsReset = snapshot.indexStatus.blocksChanges
        indexIsNewer = snapshot.indexStatus == .newer
        // Before the data folder profile first saves, the folder lists nothing; the open profile stays listed.
        if !snapshot.profiles.isEmpty, snapshot.profiles != profiles { profiles = snapshot.profiles }
        for session in sessions.values {
            if let entry = profiles.first(where: { $0.id == session.entry.id }) { session.entry = entry }
            session.showsName = showsProfileNames
        }
    }

    // MARK: changing profiles

    /// Makes a new, empty profile with GitHub and accessories off, and lists it last. It does not open. Once the
    /// profile exists this does not fail: if the list cannot be read right after, the new profile is listed as made
    /// and the next reload catches up.
    @discardableResult
    func createProfile(name: String, color: String) async throws -> ProfileEntry {
        let entry = try await catalog.createProfile(name: name, color: color)
        if (try? await reloadProfiles()) == nil, !profiles.contains(where: { $0.id == entry.id }) {
            profiles.append(entry)
            for session in sessions.values { session.showsName = showsProfileNames }
        }
        return profiles.first { $0.id == entry.id } ?? entry
    }

    func rename(_ id: UUID, to name: String) async throws {
        try await changeIdentity(of: id) { try await self.catalog.rename(id, to: name) }
    }

    func setColor(_ id: UUID, to color: String) async throws {
        try await changeIdentity(of: id) { try await self.catalog.setColor(id, to: color) }
    }

    func setIcon(_ id: UUID, to icon: ProfileIcon?) async throws {
        try await changeIdentity(of: id) { try await self.catalog.setIcon(id, to: icon) }
    }

    /// Moves a profile by `offset` places in the list, which also renumbers the ⌃⌥ shortcuts.
    func move(_ id: UUID, by offset: Int) async throws {
        try await finish(outcome { try await self.catalog.move(id, by: offset) })
    }

    func setAlwaysShowProfileName(_ value: Bool) async throws {
        try await catalog.setAlwaysShowProfileName(value)
        try await reloadProfiles()
    }

    /// Moves the unreadable index to the returned backup and starts a new one.
    @discardableResult
    func resetIndex() async throws -> URL {
        let backup = try await catalog.resetIndex()
        try await reloadProfiles()
        return backup
    }

    /// Closes the profile if it is open, then moves its folder to the Trash, where it stays recoverable. Refuses
    /// the last profile and one another process holds. Throws `CancellationError` when the person keeps the
    /// profile open after its changes could not be saved. If the move fails, a profile that was open opens again.
    func delete(_ id: UUID) async throws {
        let deletion: Result<Void, any Error> = await serialized(id) {
            await self.outcome {
                // Checked first, so a deletion that cannot happen never closes the profile.
                let snapshot = try await self.catalog.load()
                if snapshot.indexStatus.blocksChanges { throw ProfileError.indexNeedsReset }
                guard snapshot.profiles.contains(where: { $0.id == id }) else { throw ProfileError.notFound }
                guard snapshot.profiles.count > 1 else { throw ProfileError.lastProfile }
                let reopening = self.sessions[id].map { (entry: $0.entry, hidden: $0.isHidden) }
                // The move takes the profile's lock itself, so an open profile closes and releases it first.
                guard await self.closeNow(id) else { throw CancellationError() }
                do {
                    try await self.catalog.trash(id)
                } catch {
                    if let reopening { _ = await self.openSession(reopening.entry, hidden: reopening.hidden) }
                    throw error
                }
                if self.lastActiveID == id { self.lastActiveID = nil }
            }
        }
        try await finish(deletion)
    }

    /// Deletes a profile as Settings → Profiles asks. A failure after the asking profile closed, as when a profile's
    /// own Settings deletes it and the move to the Trash fails, can no longer show in that window, so
    /// `reportDeletionFailure` says why. The error is thrown either way.
    func delete(_ id: UUID, askedFrom settingsID: UUID) async throws {
        let entry = profiles.first { $0.id == id }
        do {
            try await delete(id)
        } catch {
            if let entry, sessions[settingsID]?.settingsWindow?.isVisible != true {
                reportDeletionFailure(entry, error)
            }
            throw error
        }
    }

    /// Writes the profile's identity file while holding its lock, then reloads the list. An open profile already
    /// holds its lock. A closed one is locked for the write, and refused while another process holds it.
    private func changeIdentity(of id: UUID, _ change: @escaping @MainActor () async throws -> Void) async throws {
        let written: Result<Void, any Error> = await serialized(id) {
            await self.outcome {
                let lock = try await self.lockUnlessOpen(id)
                defer { lock?.release() }
                try await change()
            }
        }
        try await finish(written)
    }

    /// The result of `body`, for work that runs in a profile's request queue.
    private func outcome(of body: () async throws -> Void) async -> Result<Void, any Error> {
        do {
            try await body()
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    /// Reloads the list after a change, and after one that found its profile gone, so the profile's row and menu
    /// items go too; then throws the change's error, if any.
    private func finish(_ outcome: Result<Void, any Error>) async throws {
        if case .failure(let error) = outcome, (error as? ProfileError) != .notFound { throw error }
        try await reloadProfiles()
        try outcome.get()
    }

    /// The profile's lock for a write to its folder, or nil when an open session here holds it already or the
    /// folder cannot be locked. Throws `.inUse` while another process holds it, and `.notFound` when the profile is
    /// gone. The catalog confirms the profile first, because taking a lock creates a missing folder, and an empty
    /// folder where a deleted profile was would make Finder's Put Back ask to replace it.
    private func lockUnlessOpen(_ id: UUID) async throws -> StateLock? {
        if let session = sessions[id], !session.isStopped { return nil }
        guard let entry = try await catalog.load().profiles.first(where: { $0.id == id }) else {
            throw ProfileError.notFound
        }
        switch StateLock.acquire(forStateAt: entry.folder.appendingPathComponent("state.json")) {
        case .acquired(let lock): return lock
        case .unavailable: return nil
        case .heldByAnotherProcess: throw ProfileError.inUse
        }
    }

    // MARK: closing and quitting

    /// Saves a profile, then closes its windows, stops its refreshes, accessories, and watchers, and releases its
    /// lock. Its data stays on disk. When the save fails, the person can keep the profile open, which returns
    /// false, or close it without saving.
    func close(_ id: UUID) async -> Bool {
        await serialized(id) { await self.closeNow(id) }
    }

    /// `close(_:)` for a caller that already waits its turn among the profile's requests.
    private func closeNow(_ id: UUID) async -> Bool {
        guard let session = sessions[id] else { return true }
        if !(await session.store.flush()), !confirmClosingWithoutSaving(session.entry) { return false }
        // Menus and other requests stop finding the profile before it stops.
        sessions[id] = nil
        // A New profile sheet waiting in its Settings must not reappear when the profile opens again.
        if newProfileRequest == id { newProfileRequest = nil }
        await session.close()
        return true
    }

    /// What a quit waits for: every open profile's final save, then the record of which profiles are open for the
    /// next launch, giving each profile's save result. The record is written even when every profile is closed,
    /// so the next launch does not reopen them. Nil when there is nothing to save or record, as when no profile
    /// has opened.
    func prepareToQuit() -> Task<[UUID: Bool], Never>? {
        guard hasStarted || sessions.values.contains(where: { !$0.isStopped && $0.store.isLoaded }) else {
            return nil
        }
        let finalSave = terminationSave()
        let recording = recordSession()
        return Task.detached {
            let results = await finalSave.value
            await recording.value
            return results
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

    private enum OpenOutcome { case opened, heldElsewhere, notFound, unreadable }

    /// Takes the profile's lock and opens its windows, out of sight when it reopens hidden. The profile is first
    /// confirmed with a fresh read of the folders, because the list may be older than a folder moved away or a
    /// deletion just finished: taking the lock would recreate the folder, and its store would write empty state
    /// there, where Finder's Put Back expects nothing.
    private func openSession(_ listed: ProfileEntry, hidden: Bool = false) async -> OpenOutcome {
        // A profile open here already holds its lock, and a second lock on the same file would be refused.
        if sessions[listed.id] != nil { return .opened }
        let confirmation: ProfileEntry?
        do { confirmation = try await confirmed(listed) } catch { return .unreadable }
        guard let entry = confirmation else { return .notFound }
        guard
            let session = ProfileSession(
                entry: entry, profile: ProfileHandle(id: entry.id, manager: self), isDemo: isDemo,
                githubClient: githubOverride(entry),
                githubClientFactory: { [weak self] in self?.githubClient(for: $0) ?? GHClient(executableURL: $0) },
                accessoryProviders: accessoryProviders)
        else { return .heldElsewhere }
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
        return .opened
    }

    /// The profile as the folders show it now, after reloading the list from them; nil, with the profile dropped
    /// from the list, when it is gone. Two profiles open without being listed, and neither writes where profile
    /// data was expected: a new installation's first profile, which has no files until it first saves, and the
    /// data folder profile when the data folder cannot be read at all, whose store then reports the problem.
    /// Throws for any other profile when the folders can't be read, so a profile is never called missing when Stow
    /// only can't look.
    private func confirmed(_ entry: ProfileEntry) async throws -> ProfileEntry? {
        let snapshot: ProfileCatalogSnapshot
        do {
            snapshot = try await catalog.load()
        } catch {
            if entry.isDataFolder { return entry }
            throw error
        }
        apply(snapshot)
        if let listed = snapshot.profiles.first(where: { $0.id == entry.id }) { return listed }
        if snapshot.isNewInstallation, entry.isDataFolder {
            let first = await catalog.dataFolderEntry()
            if first.id == entry.id { return first }
        }
        // Also when no other profile is left to list.
        if profiles.contains(where: { $0.id == entry.id }) { profiles.removeAll { $0.id == entry.id } }
        return nil
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

/// What one profile's windows read about their profile, and the profile actions they offer. It holds the manager
/// weakly, because the manager owns those windows.
@MainActor
struct ProfileHandle {
    let id: UUID
    weak var manager: ProfileManager?

    /// The profile as listed now, following renames and color and icon changes.
    var entry: ProfileEntry? { manager?.profiles.first { $0.id == id } }
    /// Colors and names show once a second profile exists, or always when the user turns that on.
    var showsIdentity: Bool { manager?.showsProfileNames ?? false }
}

/// An item in a board's profile menu.
struct ProfileMenuItem {
    let title: String
    var state: NSControl.StateValue = .off
    let action: @MainActor () -> Void
}
