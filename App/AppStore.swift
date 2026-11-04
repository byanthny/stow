import AppKit
import Observation
import StowCore
import StowExtensionSDK
import StowExtensions
import StowGitHub
import StowSampleExtension

@MainActor @Observable
final class AppStore {
    /// This store's own theme; no window reads another store's.
    let theme = ThemeController()
    var state = AppState()
    var isLoaded = false
    var isRefreshing = false
    var saveError: String?
    var githubMessage: String?
    /// The login `gh` answers as while it differs from the one this profile uses. Cleared when `gh` answers as the
    /// profile's login again, or when the user chooses to use the current account here.
    var accountMismatch: String?
    /// A new installation asks once before using an existing GitHub CLI login.
    var offersGitHubSetup = false
    var storageNeedsRecovery = false
    /// Other owners' cards from the latest refresh while the profile keeps only its selected owners on disk. They
    /// stay in memory for the owner control's counts and are never saved.
    private var memoryOnlyPullRequests: [PullRequestSnapshot] = []
    var expandedPRs: Set<String> = []
    /// Board notes shown open this session; `boardLayout` decides the starting state.
    var expandedNoteIDs: Set<UUID> = []
    @ObservationIgnored private var lastExpandedNoteID: UUID?
    var loadingDetails: Set<String> = []
    var accessoryResults: [UUID: AccessoryResult] = [:]
    var focusNoteID: UUID?
    var focusRequestID = UUID()
    var isTerminating = false
    /// Set while the profile is hidden. GitHub refreshes, the refresh timer, and accessories do nothing while
    /// paused, and resuming refreshes both.
    var isPaused = false {
        didSet {
            guard oldValue, !isPaused else { return }
            Task {
                await refresh()
                // A profile closed while GitHub answered starts no accessories.
                guard !isStopped else { return }
                await refreshAccessories()
            }
        }
    }
    var onDetach: ((UUID) -> Void)?
    var onDelete: ((UUID) -> Void)?
    var onShowBoard: (() -> Void)?
    var onAppearanceChange: (() -> Void)?
    var onBoardLevelChange: (() -> Void)?
    var onRestoreWindows: (() -> Void)?
    var notesDirectory: URL
    var noteFileMessage: String?
    var isRestoringBackup = false
    var conflictNoteIDs: Set<UUID> = []
    let stateURL: URL
    let isDemo: Bool
    /// A profile this Mac has not seen before, which opens with GitHub and accessories off.
    let isArrival: Bool
    let sampleID = "org.stow.sample"
    @ObservationIgnored private let repository: StateRepository
    @ObservationIgnored private let accessoryHost: AccessoryHost
    @ObservationIgnored private let githubOverride: (any GitHubClient)?
    @ObservationIgnored private let githubClientFactory: (@MainActor (URL) -> any GitHubClient)?
    @ObservationIgnored private var coordinator: RefreshCoordinator?
    @ObservationIgnored private var githubClient: (any GitHubClient)?
    @ObservationIgnored private var detailTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var detailTokens: [String: UUID] = [:]
    @ObservationIgnored private var accessoryRuns: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var accessoryTokens: [UUID: UUID] = [:]
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var persistenceTask: Task<Bool, Never>?
    @ObservationIgnored private var restoreTask: Task<Bool, Never>?
    @ObservationIgnored private var recoveryTask: Task<Void, Never>?
    /// The final save of the quit in progress.
    @ObservationIgnored private var terminationTask: Task<Bool, Never>?
    /// Reopens the repository after a quit the person cancelled. Writes wait for it.
    @ObservationIgnored private var reopenTask: Task<Void, Never>?
    @ObservationIgnored private var notesPresenter: NotesFolderPresenter?
    @ObservationIgnored private var notesWatcher: NotesFolderWatcher?
    @ObservationIgnored private var changeRevision: UInt64 = 0
    @ObservationIgnored private var persistedRevision: UInt64 = 0
    @ObservationIgnored private var deletedNoteIDs: Set<UUID> = []
    @ObservationIgnored private var isStopped = false
    @ObservationIgnored private var refreshTimer: Task<Void, Never>?
    @ObservationIgnored private var accessoryTask: Task<Void, Never>?
    @ObservationIgnored private var sessionGeneration = 0

    init(
        stateURL: URL, isDemo: Bool = false, githubClient: (any GitHubClient)? = nil,
        githubClientFactory: (@MainActor (URL) -> any GitHubClient)? = nil,
        accessoryProviders: [any AccessoryProvider] = [SyntheticAccessoryProvider()], arrival: Bool = false
    ) {
        self.stateURL = stateURL
        self.notesDirectory = stateURL.deletingLastPathComponent().appendingPathComponent("notes", isDirectory: true)
        self.isDemo = isDemo
        self.isArrival = arrival
        self.githubOverride = githubClient
        self.githubClientFactory = githubClientFactory
        self.accessoryHost = AccessoryHost(providers: accessoryProviders)
        repository = StateRepository(url: stateURL)
    }

    func start() async {
        do {
            state = try await repository.load()
            if !isDemo, !(await repository.foundSavedIndex) {
                // GitHub is opt-in: a new installation never uses an existing gh login unasked.
                state.githubEnabled = false
                offersGitHubSetup = true
            }
        } catch {
            storageNeedsRecovery = true
            saveError = "Saved data could not be opened. Your original file has been preserved."
            // Nothing turns on unless the person turns it on: state that cannot be read starts, and is recovered,
            // with GitHub and accessories off, and offers GitHub as a new installation does.
            state = state.preparedForArrival()
            offersGitHubSetup = !isDemo
        }
        // Whatever its saved state says, a profile not seen before must not turn GitHub or accessories on here.
        if isArrival { state = state.preparedForArrival() }
        if isDemo && state.notes.isEmpty && !storageNeedsRecovery {
            state = DemoContent.state()
        }
        for index in state.pullRequests.indices {
            state.pullRequests[index].isStale = true
            state.pullRequests[index].readinessIsComplete = false
        }
        theme.apply(state.appearance)
        if !state.boardLayout.notesStartCollapsed {
            let open = state.boardLayout.oneNoteOpenAtATime ? Array(state.notes.prefix(1)) : state.notes
            expandedNoteIDs = Set(open.map(\.id))
        }
        isLoaded = true
        if !storageNeedsRecovery {
            _ = await persist()
            await watchNotesFolder()
        }
        configureGitHub()
        // A store stopped while it loaded starts no timers.
        guard !isStopped else { return }
        refreshTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(120))
                guard !Task.isCancelled else { return }
                await self?.refresh()
            }
        }
        accessoryTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshAccessories()
                try? await Task.sleep(for: .seconds(120))
            }
        }
    }

    @discardableResult
    func applyAppearance(_ settings: AppearanceSettings) -> Bool {
        guard let valid = try? settings.validated() else { return false }
        state.appearance = valid
        theme.apply(valid)
        onAppearanceChange?()
        changed()
        return true
    }

    func toggleBoardAlwaysOnTop() {
        state.boardAlwaysOnTop.toggle()
        onBoardLevelChange?()
        changed()
    }

    func toggleSection(_ section: String) {
        if state.collapsedSections.contains(section) {
            state.collapsedSections.removeAll { $0 == section }
        } else {
            state.collapsedSections.append(section)
        }
        changed()
    }

    func sectionIsCollapsed(_ section: String) -> Bool { state.collapsedSections.contains(section) }

    func moveBoardSection(_ section: BoardLayout.Section, by offset: Int) {
        state.boardLayout.move(section, by: offset)
        changed()
    }

    func setVisiblePullRequests(_ count: Int) {
        guard BoardLayout.visiblePullRequestRange.contains(count) else { return }
        state.boardLayout.visiblePullRequests = count
        changed()
    }

    func setNotesCanCollapse(_ allowed: Bool) {
        state.boardLayout.notesCanCollapse = allowed
        // Turning collapsing off must never leave Notes hidden.
        if !allowed { state.collapsedSections.removeAll { $0 == BoardLayout.Section.notes.rawValue } }
        changed()
    }

    func resetBoardLayout() {
        state.boardLayout = BoardLayout()
        state.collapsedSections.removeAll { $0 == BoardLayout.Section.notes.rawValue }
        changed()
    }

    private func cancelDetails() {
        for task in detailTasks.values { task.cancel() }
        detailTasks.removeAll()
        detailTokens.removeAll()
        loadingDetails.removeAll()
    }

    func configureGitHub() {
        sessionGeneration += 1
        cancelDetails()
        accountMismatch = nil
        if let previous = coordinator { Task { await previous.cancel() } }
        coordinator = nil
        githubClient = nil
        isRefreshing = false
        guard state.githubEnabled, !isDemo, !isStopped else { return }
        if let githubOverride {
            githubClient = githubOverride
            coordinator = RefreshCoordinator(client: githubOverride)
            return
        }
        guard let executable = GHClient.discoverExecutable(preferredPath: state.ghExecutablePath) else {
            githubMessage = "GitHub is unavailable. Install gh or choose its executable in Settings."
            return
        }
        let client = githubClientFactory?(executable) ?? GHClient(executableURL: executable)
        githubClient = client
        coordinator = RefreshCoordinator(client: client)
    }

    func answerGitHubSetup(useGitHub: Bool) {
        offersGitHubSetup = false
        if useGitHub { setGitHubEnabled(true) }
    }

    func setGitHubEnabled(_ enabled: Bool) {
        offersGitHubSetup = false
        state.githubEnabled = enabled
        githubMessage = nil
        configureGitHub()
        changed()
        if enabled { Task { await refresh() } }
    }

    func setExecutablePath(_ path: String?) {
        state.ghExecutablePath = path
        configureGitHub()
        changed()
        Task { await refresh() }
    }

    func refresh() async {
        guard isLoaded, !isRestoringBackup, !isPaused, !isStopped, state.githubEnabled, !isDemo, let coordinator
        else { return }
        let generation = sessionGeneration
        isRefreshing = true
        defer { if generation == sessionGeneration { isRefreshing = false } }
        do {
            let result = try await coordinator.refresh(
                pins: state.pins, previous: knownPullRequests, expectedViewerLogin: state.viewerLogin)
            guard generation == sessionGeneration, state.githubEnabled else { return }
            if let expected = state.viewerLogin,
                expected.caseInsensitiveCompare(result.viewerLogin) != .orderedSame
            {
                // Defense for injected clients: another account's result is never applied.
                markAccountMismatch(actual: result.viewerLogin)
                return
            }
            accountMismatch = nil
            state.viewerLogin = result.viewerLogin
            setPullRequests(
                reconcileSnapshots(
                    previous: knownPullRequests, incoming: result.snapshots, pins: state.pins, now: result.fetchedAt))
            isRefreshing = false
            state.lastRefreshAt = result.fetchedAt
            githubMessage =
                result.warning
                ?? (result.isComplete ? nil : "Some GitHub data is incomplete. Cached cards are retained.")
            changed()
        } catch GitHubError.accountMismatch(let actual) {
            guard generation == sessionGeneration else { return }
            // A refresh that asked for an older login can name the one this profile now uses; that is no mismatch.
            if state.viewerLogin?.caseInsensitiveCompare(actual) == .orderedSame { return }
            markAccountMismatch(actual: actual)
        } catch {
            guard generation == sessionGeneration else { return }
            markCardsStale()
            githubMessage = error.localizedDescription
        }
    }

    /// Cards kept only in memory go stale too, so an owner selected afterwards never shows readiness it lost.
    private func markCardsStale() {
        func markStale(_ cards: inout [PullRequestSnapshot]) {
            for index in cards.indices {
                cards[index].isStale = true
                cards[index].readinessIsComplete = false
            }
        }
        markStale(&state.pullRequests)
        markStale(&memoryOnlyPullRequests)
    }

    /// Pauses GitHub for this profile: cached cards stay, marked stale, and no details are fetched.
    private func markAccountMismatch(actual: String) {
        accountMismatch = actual
        markCardsStale()
        githubMessage = nil
        cancelDetails()
    }

    /// Adopts the account `gh` answers as. Cached pull requests belong to the old account and go; pins and notes stay.
    func useCurrentAccount() async {
        guard let actual = accountMismatch else { return }
        accountMismatch = nil
        state.viewerLogin = actual
        state.pullRequests = []
        memoryOnlyPullRequests = []
        state.dismissedIDs = []
        expandedPRs = []
        cancelDetails()
        sessionGeneration += 1
        isRefreshing = false
        restartRefreshes()
        changed()
        await refresh()
    }

    /// Cancels the refresh in flight and starts a new coordinator, so the next refresh never joins one that asked
    /// for the old login, whose mismatch would otherwise come back under the new one.
    private func restartRefreshes() {
        guard let previous = coordinator, let githubClient else { return }
        Task { await previous.cancel() }
        coordinator = RefreshCoordinator(client: githubClient)
    }

    func toggleDetails(_ reference: PullRequestReference) {
        if expandedPRs.contains(reference.id) {
            expandedPRs.remove(reference.id)
            detailTasks.removeValue(forKey: reference.id)?.cancel()
            detailTokens[reference.id] = nil
            loadingDetails.remove(reference.id)
            return
        }
        expandedPRs.insert(reference.id)
        guard !isDemo, state.githubEnabled, accountMismatch == nil, let githubClient,
            !loadingDetails.contains(reference.id)
        else { return }
        loadingDetails.insert(reference.id)
        let generation = sessionGeneration
        let token = UUID()
        detailTokens[reference.id] = token
        detailTasks[reference.id] = Task {
            defer {
                if detailTokens[reference.id] == token {
                    loadingDetails.remove(reference.id)
                    detailTasks[reference.id] = nil
                    detailTokens[reference.id] = nil
                }
            }
            do {
                let details = try await githubClient.details(for: reference)
                try Task.checkCancellation()
                guard generation == sessionGeneration, state.githubEnabled,
                    let index = state.pullRequests.firstIndex(where: { $0.id == reference.id })
                else { return }
                state.pullRequests[index].details = details
                changed()
            } catch is CancellationError {} catch {
                if !Task.isCancelled, detailTokens[reference.id] == token,
                    generation == sessionGeneration && state.githubEnabled
                {
                    githubMessage = "Details are unavailable. The cached card is still available."
                }
            }
        }
    }

    var visiblePRs: [PullRequestSnapshot] {
        guard state.githubEnabled else { return [] }
        return state.pullRequests.filter { !state.dismissedIDs.contains($0.id) }
    }

    /// A section's cards, newest first. The owner selection leaves out other owners' cards, except pinned ones, and
    /// never changes how a card is classified.
    func cards(in section: AttentionSection) -> [PullRequestSnapshot] {
        visiblePRs.filter {
            isShown($0, selection: state.ownerSelection, pins: state.pins)
                && classify($0, isPinned: state.pins.contains($0.reference)).section == section
        }
        .sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
    }

    /// Every card the profile knows now: the saved ones, then those kept only in memory.
    private var knownPullRequests: [PullRequestSnapshot] { state.pullRequests + memoryOnlyPullRequests }

    /// Replaces the cards. While the profile keeps only its selected owners on disk, other owners' cards go to
    /// memory instead of the saved state, unless they are pinned.
    private func setPullRequests(_ cards: [PullRequestSnapshot]) {
        guard state.keepsOnlySelectedOwners else {
            state.pullRequests = cards
            memoryOnlyPullRequests = []
            return
        }
        let kept = retainingSelectedOwners(cards, selection: state.ownerSelection, pins: state.pins)
        let keptIDs = Set(kept.map(\.id))
        state.pullRequests = kept
        memoryOnlyPullRequests = cards.filter { !keptIDs.contains($0.id) }
    }

    /// Moves cards between the saved state and memory after the selection, the pins, or the storage setting change.
    private func reapplyKeptOwners() {
        guard state.keepsOnlySelectedOwners || !memoryOnlyPullRequests.isEmpty else { return }
        setPullRequests(knownPullRequests)
    }

    /// The owners the owner control lists: from cards, pins, and the selection, with counts of cards that are not
    /// dismissed. While the profile keeps only its selected owners on disk, other owners' counts come from the
    /// latest refresh, kept in memory.
    var ownerSummaries: [OwnerSummary] {
        StowCore.ownerSummaries(
            pullRequests: knownPullRequests, pins: state.pins, dismissedIDs: state.dismissedIDs,
            selection: state.ownerSelection, order: state.boardLayout.ownerOrder)
    }

    /// The board header shows the owner control with GitHub on and cards from more than one owner, whenever a
    /// selection is active, so it never hides cards silently, or always when Settings → Board asks.
    var showsOwnerControl: Bool {
        StowCore.showsOwnerControl(
            githubEnabled: state.githubEnabled, pullRequests: visiblePRs, selection: state.ownerSelection,
            alwaysShow: state.boardLayout.alwaysShowOwnerControl)
    }

    /// Chooses whose pull requests show, and saves. A profile that keeps only its selected owners on disk also
    /// refreshes at once, so an owner just added gets its cards.
    func setOwnerSelection(_ selection: OwnerSelection) {
        guard selection != state.ownerSelection else { return }
        state.ownerSelection = selection
        reapplyKeptOwners()
        changed()
        if state.keepsOnlySelectedOwners { Task { await refresh() } }
    }

    /// Settings → Board → Keep only selected owners on disk. Turning it on takes other owners' cards out of the
    /// saved state at once, keeping pins; turning it off saves the cards held in memory again.
    func setKeepsOnlySelectedOwners(_ keeps: Bool) {
        guard keeps != state.keepsOnlySelectedOwners else { return }
        state.keepsOnlySelectedOwners = keeps
        reapplyKeptOwners()
        changed()
    }

    /// The notes the board lists. With Settings → Board → Hide notes linked to hidden owners on, a note linked to
    /// another owner's pull request hides, unless that card is pinned and so shows. Standalone notes always show,
    /// and hiding never closes a detached note's window.
    var visibleNotes: [Note] {
        // Without GitHub there is no owner control to show the selection, so it hides nothing.
        guard state.githubEnabled, state.boardLayout.hidesNotesForHiddenOwners else { return state.notes }
        return state.notes.filter { note in
            isNoteShown(note, selection: state.ownerSelection, hidesLinkedNotes: true)
                || note.pullRequest.map { state.pins.contains($0) } == true
        }
    }

    func pin(_ reference: PullRequestReference) {
        if !state.pins.contains(reference) { state.pins.append(reference) }
        state.dismissedIDs.removeAll { $0 == reference.id }
        // A card held only in memory is saved again once pinned.
        reapplyKeptOwners()
        if !state.pullRequests.contains(where: { $0.id == reference.id }) {
            state.pullRequests.append(.init(reference: reference, title: reference.displayName, isStale: true))
        }
        changed()
        Task { await refresh() }
    }

    func togglePin(_ reference: PullRequestReference) {
        if state.pins.contains(reference) {
            state.pins.removeAll { $0 == reference }
            // Unpinned, a card of an owner outside the selection is no longer saved.
            reapplyKeptOwners()
            changed()
        } else {
            pin(reference)
        }
    }

    func dismiss(_ reference: PullRequestReference) {
        if !state.dismissedIDs.contains(reference.id) { state.dismissedIDs.append(reference.id) }
        changed()
    }

    func restoreDismissal(_ id: String) {
        state.dismissedIDs.removeAll { $0 == id }
        changed()
    }

    @discardableResult func addNote(_ markdown: String = "", reference: PullRequestReference? = nil) -> UUID {
        discardEmptyDraft()
        let note = Note(markdown: markdown, pullRequest: reference)
        state.notes.insert(note, at: 0)
        requestFocus(note.id)
        changed()
        return note.id
    }

    /// A note started by clicking the Notes area, kept only once something is typed into it.
    private(set) var draftNoteID: UUID?

    /// Starts an empty note ready for typing. It disappears again if it is left without text.
    @discardableResult func startNote() -> UUID {
        let id = addNote()
        draftNoteID = id
        return id
    }

    /// Removes the started note if nothing was typed into it, as if it had never been created.
    private func discardEmptyDraft(keeping kept: UUID? = nil) {
        guard let id = draftNoteID, id != kept else { return }
        draftNoteID = nil
        guard let note = note(id), note.markdown.isEmpty, !note.isDetached else { return }
        deleteNote(id)
    }

    func isNoteExpanded(_ id: UUID) -> Bool { expandedNoteIDs.contains(id) }

    func toggleNoteExpanded(_ id: UUID) {
        if expandedNoteIDs.contains(id) {
            expandedNoteIDs.remove(id)
            if id == draftNoteID { discardEmptyDraft() }
        } else {
            expandNote(id)
        }
    }

    private func expandNote(_ id: UUID) {
        discardEmptyDraft(keeping: id)
        if state.boardLayout.oneNoteOpenAtATime { expandedNoteIDs = [id] } else { expandedNoteIDs.insert(id) }
        lastExpandedNoteID = id
    }

    func setShowsBoardTitle(_ shown: Bool) {
        state.boardLayout.showsTitle = shown
        changed()
    }

    func setGroupByOwner(_ grouped: Bool) {
        state.boardLayout.groupByOwner = grouped
        changed()
    }

    func setOwnerOrder(_ order: BoardLayout.OwnerOrder) {
        state.boardLayout.ownerOrder = order
        changed()
    }

    func setAlwaysShowOwnerControl(_ shown: Bool) {
        state.boardLayout.alwaysShowOwnerControl = shown
        changed()
    }

    func setHidesNotesForHiddenOwners(_ hides: Bool) {
        state.boardLayout.hidesNotesForHiddenOwners = hides
        changed()
    }

    /// Settings → Board → Keep always-on-top notes visible when hiding, read when this profile hides.
    func setHideKeepsAlwaysOnTopNotes(_ keeps: Bool) {
        state.hideKeepsAlwaysOnTopNotes = keeps
        changed()
    }

    /// Settings → Profiles → Hide when switching away, read from this profile when a switch leaves it.
    func setHidesWhenSwitchingAway(_ hides: Bool) {
        state.hidesWhenSwitchingAway = hides
        changed()
    }

    func setNotesStartCollapsed(_ collapsed: Bool) {
        state.boardLayout.notesStartCollapsed = collapsed
        changed()
    }

    func setOneNoteOpenAtATime(_ enabled: Bool) {
        state.boardLayout.oneNoteOpenAtATime = enabled
        if enabled, expandedNoteIDs.count > 1 {
            // Keep the note opened most recently; close the rest.
            expandedNoteIDs = lastExpandedNoteID.map { expandedNoteIDs.contains($0) ? [$0] : [] } ?? []
        }
        changed()
    }

    func requestFocus(_ id: UUID) {
        expandNote(id)
        if state.collapsedSections.contains("notes") {
            state.collapsedSections.removeAll { $0 == "notes" }
            changed()
        }
        focusNoteID = id
        focusRequestID = UUID()
    }

    /// Stops for good: timers, watchers, refreshes, and accessories end, and nothing is saved afterwards, because
    /// the profile may release its lock next. To quiet background work and resume later, pause instead.
    func stop() {
        isStopped = true
        // A refresh or detail request still running is discarded when it returns.
        sessionGeneration += 1
        isRefreshing = false
        notesWatcher?.stop()
        notesWatcher = nil
        if let notesPresenter { NSFileCoordinator.removeFilePresenter(notesPresenter) }
        notesPresenter = nil
        cancelDetails()
        for task in accessoryRuns.values { task.cancel() }
        accessoryRuns.removeAll()
        refreshTimer?.cancel()
        accessoryTask?.cancel()
        saveTask?.cancel()
        if let coordinator { Task { await coordinator.cancel() } }
    }

    func note(_ id: UUID) -> Note? { state.notes.first { $0.id == id } }

    func editNote(_ id: UUID, markdown: String) {
        guard let index = state.notes.firstIndex(where: { $0.id == id }), state.notes[index].markdown != markdown else {
            return
        }
        state.notes[index].markdown = markdown
        state.notes[index].updatedAt = .now
        // Typing into a started note keeps it.
        if id == draftNoteID, !markdown.isEmpty { draftNoteID = nil }
        changed()
    }

    func detachNote(_ id: UUID) {
        guard let index = state.notes.firstIndex(where: { $0.id == id }) else { return }
        if id == draftNoteID { draftNoteID = nil }
        state.notes[index].isDetached = true
        changed()
        onDetach?(id)
    }

    func closeDetachedNote(_ id: UUID) {
        guard !isTerminating, let index = state.notes.firstIndex(where: { $0.id == id }) else { return }
        state.notes[index].isDetached = false
        changed()
    }

    func deleteNote(_ id: UUID) {
        deletedNoteIDs.insert(id)
        expandedNoteIDs.remove(id)
        state.notes.removeAll { $0.id == id }
        let removed = state.extensionInstances.filter { $0.noteID == id }
        state.extensionInstances.removeAll { $0.noteID == id }
        for instance in removed {
            accessoryRuns.removeValue(forKey: instance.id)?.cancel()
            accessoryTokens[instance.id] = nil
            Task { await accessoryHost.cancel(instanceID: instance.id, moduleID: instance.moduleID) }
        }
        onDelete?(id)
        changed()
    }

    func toggleAlwaysOnTop(_ id: UUID) {
        guard let index = state.notes.firstIndex(where: { $0.id == id }) else { return }
        state.notes[index].isAlwaysOnTop.toggle()
        changed()
        onDetach?(id)
    }

    func saveFrame(_ frame: WindowFrame, noteID: UUID? = nil) {
        if let noteID, let index = state.notes.firstIndex(where: { $0.id == noteID }) {
            state.notes[index].frame = frame
        } else if noteID == nil {
            state.boardFrame = frame
        }
        changed()
    }

    func pasteOutsideEditor(_ text: String) {
        switch parsePaste(text) {
        case .pin(let reference, let note):
            pin(reference)
            if let note, !note.isEmpty { addNote(note, reference: reference) }
        case .note(let markdown): addNote(markdown)
        }
    }

    func sampleEnabled(noteID: UUID? = nil) -> Bool {
        state.extensionInstances.contains { $0.moduleID == sampleID && $0.noteID == noteID && $0.isEnabled }
    }

    func toggleSample(noteID: UUID? = nil) {
        if let index = state.extensionInstances.firstIndex(where: { $0.moduleID == sampleID && $0.noteID == noteID }) {
            state.extensionInstances[index].isEnabled.toggle()
            let instance = state.extensionInstances[index]
            if !instance.isEnabled {
                accessoryRuns.removeValue(forKey: instance.id)?.cancel()
                accessoryTokens[instance.id] = nil
                accessoryResults[instance.id] = nil
                Task { await accessoryHost.cancel(instanceID: instance.id, moduleID: instance.moduleID) }
            }
        } else {
            state.extensionInstances.append(
                .init(
                    moduleID: sampleID, slot: noteID == nil ? .boardAccessory : .noteAccessory,
                    noteID: noteID, isEnabled: true))
        }
        changed()
        Task { await refreshAccessories() }
    }

    func refreshAccessories() async {
        guard !isRestoringBackup, !isPaused else { return }
        // A refresh that began while the store ran ends once it stops, so a closing profile starts no more
        // accessories. One asked of an already stopped store still runs: tests that silence a store's timers by
        // stopping it, then refresh its accessories by hand.
        let beganRunning = !isStopped
        for id in state.extensionInstances.map(\.id) {
            guard !Task.isCancelled, !isRestoringBackup, !isPaused, !(beganRunning && isStopped) else { return }
            guard let instance = state.extensionInstances.first(where: { $0.id == id && $0.isEnabled }) else {
                continue
            }
            if let existing = accessoryRuns[id] {
                await existing.value
                continue
            }
            let token = UUID()
            accessoryTokens[id] = token
            let task = Task { [weak self] in
                guard let self, !Task.isCancelled,
                    state.extensionInstances.contains(where: { $0.id == id && $0.isEnabled })
                else { return }
                defer {
                    if accessoryTokens[id] == token {
                        accessoryRuns[id] = nil
                        accessoryTokens[id] = nil
                    }
                }
                let request = AccessoryRequest(
                    instanceID: id, slot: instance.slot,
                    configurationVersion: instance.configurationVersion, configuration: instance.configuration)
                let result = await accessoryHost.run(request, moduleID: instance.moduleID, enabled: true)
                guard !Task.isCancelled,
                    state.extensionInstances.contains(where: { $0.id == id && $0.isEnabled })
                else { return }
                accessoryResults[id] = result
            }
            accessoryRuns[id] = task
            await task.value
        }
    }

    func importMarkdown(_ sources: [String]) {
        guard !isRestoringBackup, !sources.isEmpty else { return }
        let imported = sources.map { Note(markdown: $0) }
        state.notes.insert(contentsOf: imported, at: 0)
        if let first = imported.first { requestFocus(first.id) }
        changed()
    }

    private func watchNotesFolder() async {
        notesWatcher?.stop()
        notesWatcher = nil
        if let notesPresenter { NSFileCoordinator.removeFilePresenter(notesPresenter) }
        notesDirectory = await repository.notesDirectory
        // A store stopped meanwhile watches nothing.
        guard !isStopped else { return }
        let presenter = NotesFolderPresenter(directory: notesDirectory) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.isStopped, !self.isTerminating, !self.isRestoringBackup else { return }
                self.changed()
            }
        }
        notesPresenter = presenter
        NSFileCoordinator.addFilePresenter(presenter)
        do {
            notesWatcher = try NotesFolderWatcher(directory: notesDirectory) { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, !self.isStopped, !self.isTerminating, !self.isRestoringBackup else { return }
                    self.changed()
                }
            }
        } catch {
            noteFileMessage = "Automatic file watching is unavailable. Return to Stow to reload external edits."
        }
    }

    func changed() {
        guard isLoaded, !isStopped, !isTerminating, !isRestoringBackup else { return }
        changeRevision &+= 1
        guard !storageNeedsRecovery else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(300))
                try Task.checkCancellation()
                _ = await self?.persist()
            } catch {}
        }
    }

    /// A single task owns snapshot → disk merge → UI merge before the next snapshot is taken.
    /// Cancelling a debounce never cancels a write that has already started.
    private func persist(allowDuringRestore: Bool = false) async -> Bool {
        // Nothing is saved before the profile loads, or once it stops and may have released its lock.
        guard isLoaded, !isStopped, !storageNeedsRecovery, !isRestoringBackup || allowDuringRestore else {
            return false
        }
        if let active = persistenceTask {
            let saved = await active.value
            if saved, persistedRevision != changeRevision { return await persist() }
            return saved
        }
        let task = Task { @MainActor [weak self] () -> Bool in
            guard let self else { return false }
            defer { persistenceTask = nil }
            repeat {
                // A repository closed by a quit the person cancelled opens again before the next write.
                if let reopenTask { await reopenTask.value }
                // A store stopped between writes leaves the rest to its final save.
                guard !isStopped else { return false }
                let revision = changeRevision
                let snapshot = state
                let deletions = deletedNoteIDs
                do {
                    let result = try await repository.saveMerging(snapshot, deletedNoteIDs: deletions)
                    mergeLiveResult(result, snapshot: snapshot)
                    deletedNoteIDs.subtract(deletions)
                    persistedRevision = revision
                    saveError = nil
                } catch {
                    saveError =
                        "Changes are in memory. Saving failed; check the notes folder, available space, and file permissions."
                    return false
                }
            } while persistedRevision != changeRevision
            return true
        }
        persistenceTask = task
        return await task.value
    }

    private func mergeLiveResult(_ result: LiveSaveResult, snapshot: AppState) {
        var previous: [UUID: Note] = [:]
        for note in snapshot.notes { previous[note.id] = note }
        for id in result.externallyDeletedIDs {
            guard let index = state.notes.firstIndex(where: { $0.id == id }), let original = previous[id] else {
                continue
            }
            if state.notes[index].markdown == original.markdown {
                state.notes.remove(at: index)
                state.extensionInstances.removeAll { $0.noteID == id }
                onDelete?(id)
                changeRevision &+= 1
            } else {
                noteFileMessage = "An external deletion conflicted with unsaved text. Your text has been kept."
            }
        }
        for incoming in result.state.notes {
            if let index = state.notes.firstIndex(where: { $0.id == incoming.id }) {
                guard let original = previous[incoming.id] else { continue }
                if state.notes[index].markdown == original.markdown {
                    state.notes[index].markdown = incoming.markdown
                    if incoming.markdown != original.markdown { state.notes[index].updatedAt = incoming.updatedAt }
                } else if incoming.markdown != original.markdown, incoming.markdown != state.notes[index].markdown {
                    let preserved = Note(markdown: incoming.markdown, pullRequest: incoming.pullRequest)
                    state.notes.append(preserved)
                    conflictNoteIDs.insert(preserved.id)
                    changeRevision &+= 1
                    noteFileMessage =
                        "An external edit conflicted with unsaved text. Both versions have been kept as notes."
                }
            } else if previous[incoming.id] == nil, !deletedNoteIDs.contains(incoming.id) {
                state.notes.append(incoming)
            }
        }
        conflictNoteIDs.formUnion(result.conflictNoteIDs)
        if !result.conflictNoteIDs.isEmpty {
            noteFileMessage = "An external edit conflicted with unsaved text. Both versions have been kept as notes."
        }
    }

    /// The final save at quit, from the state in memory now. From here on edits schedule no saves. A save that
    /// succeeds closes the repository, so a save still running cannot write an older state over it.
    func terminationSave() -> Task<Bool, Never> {
        isTerminating = true
        saveTask?.cancel()
        let snapshot = state
        let deletions = deletedNoteIDs
        let writer = repository
        let reopening = reopenTask
        // An empty state saved before the profile loads would delete its notes.
        let blocked = !isLoaded || storageNeedsRecovery || isRestoringBackup || isStopped
        let save = Task.detached {
            guard !blocked else { return false }
            // A quit cancelled before this one may still be reopening the repository.
            await reopening?.value
            do {
                try await writer.saveAndClose(snapshot, deletedNoteIDs: deletions)
                return true
            } catch { return false }
        }
        terminationTask = save
        return save
    }

    /// Undoes a quit the person cancelled: edits schedule saves again, and a repository the final save closed
    /// opens again before the next write, so the profile never silently stops saving.
    func cancelTermination() {
        isTerminating = false
        guard let save = terminationTask else { return }
        terminationTask = nil
        let writer = repository
        reopenTask = Task.detached {
            if await save.value { await writer.reopen() }
        }
    }

    func flush() async -> Bool {
        saveTask?.cancel()
        return await persist()
    }

    /// The last write of a closing profile, after `stop()`. Waits for a restore, recovery, or save still running,
    /// writes the final state, and closes the writer, so nothing writes once the profile releases its lock.
    func saveAndClose() async -> Bool {
        if let restoreTask { _ = await restoreTask.value }
        if let recoveryTask { await recoveryTask.value }
        if let persistenceTask { _ = await persistenceTask.value }
        if let reopenTask { await reopenTask.value }
        guard isStopped, isLoaded, !storageNeedsRecovery, !isRestoringBackup else { return false }
        do {
            try await repository.saveAndClose(state, deletedNoteIDs: deletedNoteIDs)
            return true
        } catch { return false }
    }

    /// Transfers reconcile live files before taking a single in-memory snapshot.
    func portableSnapshot() async throws -> AppState {
        guard !isRestoringBackup, await flush(), !isRestoringBackup else {
            throw DataTransferFileError.cannotSynchronize
        }
        return state
    }

    /// Backs up unreadable saved data and starts fresh. A closing profile waits for it to finish.
    func recoverState() async {
        guard !isStopped, recoveryTask == nil else { return }
        let recovery = Task { await recover() }
        recoveryTask = recovery
        defer { recoveryTask = nil }
        await recovery.value
    }

    private func recover() async {
        guard !isStopped else { return }
        do {
            try await repository.recoverByBackingUp()
            storageNeedsRecovery = false
            _ = await flush()
            await watchNotesFolder()
        } catch { saveError = "Recovery could not create a backup. The original files are unchanged." }
    }

    /// Replaces the profile's notes and settings with a backup. A closing profile waits for it to finish.
    func restoreBackup(_ replacement: AppState) async -> Bool {
        guard restoreTask == nil else { return false }
        let restore = Task { await replaceState(with: replacement) }
        restoreTask = restore
        defer { restoreTask = nil }
        return await restore.value
    }

    private func replaceState(with replacement: AppState) async -> Bool {
        guard !isRestoringBackup, !isTerminating, !isStopped, (try? StowBackup.encode(replacement)) != nil else {
            return false
        }
        isRestoringBackup = true
        sessionGeneration += 1
        cancelDetails()
        if let previous = coordinator { await previous.cancel() }
        coordinator = nil
        githubClient = nil
        isRefreshing = false
        for task in accessoryRuns.values { task.cancel() }
        accessoryRuns.removeAll()
        accessoryTokens.removeAll()
        defer {
            isRestoringBackup = false
            configureGitHub()
        }
        saveTask?.cancel()
        if let active = persistenceTask { _ = await active.value }
        if !storageNeedsRecovery, !(await persist(allowDuringRestore: true)) { return false }
        // A profile stopped while this waited writes nothing more.
        guard !isStopped else { return false }
        // Preserve the current in-memory version as well as the repository's original files.
        do {
            let folder = stateURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: folder, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let backup = folder.appendingPathComponent("pre-restore-\(UUID().uuidString).stowbackup")
            try DataTransferFiles.writePrivateAtomically(StowBackup.encode(state), to: backup)
            // A received backup never chooses this Mac's GitHub CLI or turns GitHub access on.
            var restored = replacement.keepingMachineLocalSettings(from: state)
            for index in restored.pullRequests.indices {
                restored.pullRequests[index].isStale = true
                restored.pullRequests[index].readinessIsComplete = false
            }
            let result = try await repository.restore(restored)
            sessionGeneration += 1
            cancelDetails()
            for task in accessoryRuns.values { task.cancel() }
            accessoryRuns.removeAll()
            accessoryTokens.removeAll()
            accessoryResults.removeAll()
            state = result.state
            memoryOnlyPullRequests = []
            deletedNoteIDs.removeAll()
            conflictNoteIDs.removeAll()
            noteFileMessage = nil
            storageNeedsRecovery = false
            saveError = nil
            changeRevision &+= 1
            persistedRevision = changeRevision
            theme.apply(state.appearance)
            await watchNotesFolder()
            onRestoreWindows?()
            return true
        } catch {
            saveError = "The backup could not be restored. Your previous files and in-memory notes have been kept."
            return false
        }
    }

    static func openLink(_ url: URL) {
        guard ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return }
        NSWorkspace.shared.open(url)
    }
}
