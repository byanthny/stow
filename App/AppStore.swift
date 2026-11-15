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
    var memoryOnlyPullRequests: [PullRequestSnapshot] = []
    var expandedPRs: Set<String> = []
    /// Board notes shown open this session; `boardLayout` decides the starting state.
    var expandedNoteIDs: Set<UUID> = []
    /// A note started by clicking the Notes area, kept only once something is typed into it.
    var draftNoteID: UUID?
    /// The Merged group starts collapsed each launch; its state is kept only in memory.
    var mergedGroupIsExpanded = false
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
    /// The folder holding every profile. A `gh` inside it is never launched.
    let dataFolder: URL
    let isDemo: Bool
    /// A profile this Mac has not seen before, which opens with GitHub and accessories off.
    let isArrival: Bool
    let sampleID = "org.stow.sample"
    @ObservationIgnored let repository: StateRepository
    @ObservationIgnored let accessoryHost: AccessoryHost
    @ObservationIgnored let githubOverride: (any GitHubClient)?
    @ObservationIgnored let githubClientFactory: (@MainActor (URL) -> any GitHubClient)?
    @ObservationIgnored var coordinator: RefreshCoordinator?
    @ObservationIgnored var githubClient: (any GitHubClient)?
    @ObservationIgnored var detailTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored var detailTokens: [String: UUID] = [:]
    @ObservationIgnored var accessoryRuns: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored var accessoryTokens: [UUID: UUID] = [:]
    @ObservationIgnored var saveTask: Task<Void, Never>?
    @ObservationIgnored var persistenceTask: Task<Bool, Never>?
    @ObservationIgnored var restoreTask: Task<Bool, Never>?
    @ObservationIgnored var recoveryTask: Task<Void, Never>?
    /// The final save of the quit in progress.
    @ObservationIgnored var terminationTask: Task<Bool, Never>?
    /// Reopens the repository after a quit the person cancelled. Writes wait for it.
    @ObservationIgnored var reopenTask: Task<Void, Never>?
    @ObservationIgnored var notesPresenter: NotesFolderPresenter?
    @ObservationIgnored var notesWatcher: NotesFolderWatcher?
    @ObservationIgnored var changeRevision: UInt64 = 0
    @ObservationIgnored var persistedRevision: UInt64 = 0
    @ObservationIgnored var deletedNoteIDs: Set<UUID> = []
    @ObservationIgnored private(set) var isStopped = false
    @ObservationIgnored private(set) var refreshTimer: Task<Void, Never>?
    /// When a refresh last asked GitHub.
    @ObservationIgnored var lastRefreshAttempt: ContinuousClock.Instant?
    /// The time activation refreshes compare with the last attempt; tests replace it.
    @ObservationIgnored var now: () -> ContinuousClock.Instant = { .now }
    @ObservationIgnored private(set) var accessoryTask: Task<Void, Never>?
    /// How often the refresh and accessory loops wake; tests shorten it.
    @ObservationIgnored var backgroundInterval: Duration = .seconds(120)
    @ObservationIgnored var sessionGeneration = 0

    /// Without a data folder, the profile's own folder stands in for it.
    init(
        stateURL: URL, dataFolder: URL? = nil, isDemo: Bool = false, githubClient: (any GitHubClient)? = nil,
        githubClientFactory: (@MainActor (URL) -> any GitHubClient)? = nil,
        accessoryProviders: [any AccessoryProvider] = [SyntheticAccessoryProvider()], arrival: Bool = false
    ) {
        self.stateURL = stateURL
        self.dataFolder = dataFolder ?? stateURL.deletingLastPathComponent()
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
        for index in state.pullRequests.indices {
            state.pullRequests[index].markStale()
            state.pullRequests[index].readinessIsComplete = false
        }
        // Demo content sets which of its cards are fresh.
        if isDemo && state.notes.isEmpty && !storageNeedsRecovery {
            state = DemoContent.state()
        }
        theme.apply(state.appearance)
        if !state.boardLayout.notesStartCollapsed {
            expandedNoteIDs = Set(state.notes.map(\.id))
        }
        isLoaded = true
        if !storageNeedsRecovery {
            _ = await persist()
            await watchNotesFolder()
        }
        configureGitHub()
        // A store stopped while it loaded starts no timers.
        guard !isStopped else { return }
        refreshTimer = repeating(every: backgroundInterval, immediately: false) { await $0.refresh() }
        accessoryTask = repeating(every: backgroundInterval, immediately: true) { await $0.refreshAccessories() }
    }

    /// Runs `work` every `interval` until cancelled or the store is gone, holding the store only while it runs.
    private func repeating(
        every interval: Duration, immediately: Bool, _ work: @escaping @MainActor (AppStore) async -> Void
    ) -> Task<Void, Never> {
        Task { [weak self] in
            var waits = !immediately
            while !Task.isCancelled {
                if waits { try? await Task.sleep(for: interval) }
                waits = true
                guard !Task.isCancelled, let self else { return }
                await work(self)
            }
        }
    }

    func cancelDetails() {
        for task in detailTasks.values { task.cancel() }
        detailTasks.removeAll()
        detailTokens.removeAll()
        loadingDetails.removeAll()
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

    static func openLink(_ url: URL) {
        guard url.isWebLink else { return }
        NSWorkspace.shared.open(url)
    }
}
