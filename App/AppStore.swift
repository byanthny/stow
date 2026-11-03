import AppKit
import Observation
import StowCore
import StowExtensionSDK
import StowExtensions
import StowGitHub
import StowSampleExtension

@MainActor @Observable
final class AppStore {
    var state = AppState()
    var isLoaded = false
    var isRefreshing = false
    var saveError: String?
    var githubMessage: String?
    var storageNeedsRecovery = false
    var expandedPRs: Set<String> = []
    var loadingDetails: Set<String> = []
    var accessoryResults: [UUID: AccessoryResult] = [:]
    var focusNoteID: UUID?
    var focusRequestID = UUID()
    var isTerminating = false
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
    let sampleID = "org.stow.sample"
    @ObservationIgnored private let repository: StateRepository
    @ObservationIgnored private let accessoryHost: AccessoryHost
    @ObservationIgnored private let githubOverride: (any GitHubClient)?
    @ObservationIgnored private var coordinator: RefreshCoordinator?
    @ObservationIgnored private var githubClient: (any GitHubClient)?
    @ObservationIgnored private var detailTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var detailTokens: [String: UUID] = [:]
    @ObservationIgnored private var accessoryRuns: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var accessoryTokens: [UUID: UUID] = [:]
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var persistenceTask: Task<Bool, Never>?
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
        accessoryProviders: [any AccessoryProvider] = [SyntheticAccessoryProvider()]
    ) {
        self.stateURL = stateURL
        self.notesDirectory = stateURL.deletingLastPathComponent().appendingPathComponent("notes", isDirectory: true)
        self.isDemo = isDemo
        self.githubOverride = githubClient
        self.accessoryHost = AccessoryHost(providers: accessoryProviders)
        repository = StateRepository(url: stateURL)
    }

    func start() async {
        do { state = try await repository.load() } catch {
            storageNeedsRecovery = true
            saveError = "Saved data could not be opened. Your original file has been preserved."
        }
        if isDemo && state.notes.isEmpty && !storageNeedsRecovery {
            state = DemoContent.state()
        }
        for index in state.pullRequests.indices {
            state.pullRequests[index].isStale = true
            state.pullRequests[index].readinessIsComplete = false
        }
        ThemeController.shared.apply(state.appearance)
        isLoaded = true
        if !storageNeedsRecovery {
            _ = await persist()
            await watchNotesFolder()
        }
        configureGitHub()
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
        ThemeController.shared.apply(valid)
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

    private func cancelDetails() {
        for task in detailTasks.values { task.cancel() }
        detailTasks.removeAll()
        detailTokens.removeAll()
        loadingDetails.removeAll()
    }

    func configureGitHub() {
        sessionGeneration += 1
        cancelDetails()
        if let previous = coordinator { Task { await previous.cancel() } }
        coordinator = nil
        githubClient = nil
        isRefreshing = false
        guard state.githubEnabled, !isDemo else { return }
        if let githubOverride {
            githubClient = githubOverride
            coordinator = RefreshCoordinator(client: githubOverride)
            return
        }
        guard let executable = GHClient.discoverExecutable(preferredPath: state.ghExecutablePath) else {
            githubMessage = "GitHub is unavailable. Install gh or choose its executable in Settings."
            return
        }
        let client = GHClient(executableURL: executable)
        githubClient = client
        coordinator = RefreshCoordinator(client: client)
    }

    func setGitHubEnabled(_ enabled: Bool) {
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
        guard isLoaded, !isRestoringBackup, state.githubEnabled, !isDemo, let coordinator else { return }
        let generation = sessionGeneration
        isRefreshing = true
        defer { if generation == sessionGeneration { isRefreshing = false } }
        do {
            let result = try await coordinator.refresh(
                pins: state.pins, previous: state.pullRequests, expectedViewerLogin: state.viewerLogin)
            guard generation == sessionGeneration, state.githubEnabled else { return }
            if let previousLogin = state.viewerLogin, previousLogin != result.viewerLogin {
                // Cached PRs belong to the authenticated account; personal notes never do.
                state.pullRequests = []
                state.dismissedIDs = []
                expandedPRs = []
                cancelDetails()
                sessionGeneration += 1
            }
            state.viewerLogin = result.viewerLogin
            state.pullRequests = reconcileSnapshots(
                previous: state.pullRequests, incoming: result.snapshots,
                pins: state.pins, now: result.fetchedAt)
            isRefreshing = false
            state.lastRefreshAt = result.fetchedAt
            githubMessage =
                result.warning
                ?? (result.isComplete ? nil : "Some GitHub data is incomplete. Cached cards are retained.")
            changed()
        } catch {
            guard generation == sessionGeneration else { return }
            for index in state.pullRequests.indices {
                state.pullRequests[index].isStale = true
                state.pullRequests[index].readinessIsComplete = false
            }
            githubMessage = error.localizedDescription
        }
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
        guard !isDemo, state.githubEnabled, let githubClient,
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

    func cards(in section: AttentionSection) -> [PullRequestSnapshot] {
        visiblePRs.filter { classify($0, isPinned: state.pins.contains($0.reference)).section == section }
            .sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
    }

    func pin(_ reference: PullRequestReference) {
        if !state.pins.contains(reference) { state.pins.append(reference) }
        state.dismissedIDs.removeAll { $0 == reference.id }
        if !state.pullRequests.contains(where: { $0.id == reference.id }) {
            state.pullRequests.append(.init(reference: reference, title: reference.displayName, isStale: true))
        }
        changed()
        Task { await refresh() }
    }

    func togglePin(_ reference: PullRequestReference) {
        if state.pins.contains(reference) {
            state.pins.removeAll { $0 == reference }
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
        let note = Note(markdown: markdown, pullRequest: reference)
        state.notes.insert(note, at: 0)
        requestFocus(note.id)
        changed()
        return note.id
    }

    func requestFocus(_ id: UUID) {
        if state.collapsedSections.contains("notes") {
            state.collapsedSections.removeAll { $0 == "notes" }
            changed()
        }
        focusNoteID = id
        focusRequestID = UUID()
    }

    func stop() {
        isStopped = true
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
        changed()
    }

    func detachNote(_ id: UUID) {
        guard let index = state.notes.firstIndex(where: { $0.id == id }) else { return }
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
        guard !isRestoringBackup else { return }
        for id in state.extensionInstances.map(\.id) {
            guard !Task.isCancelled, !isRestoringBackup else { return }
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
        let presenter = NotesFolderPresenter(directory: notesDirectory) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !isStopped, !isTerminating, !isRestoringBackup else { return }
                changed()
            }
        }
        notesPresenter = presenter
        NSFileCoordinator.addFilePresenter(presenter)
        do {
            notesWatcher = try NotesFolderWatcher(directory: notesDirectory) { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, !isStopped, !isTerminating, !isRestoringBackup else { return }
                    changed()
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
        guard !storageNeedsRecovery, !isRestoringBackup || allowDuringRestore else { return false }
        if let active = persistenceTask {
            let saved = await active.value
            if saved, persistedRevision != changeRevision { return await persist() }
            return saved
        }
        let task = Task { @MainActor [weak self] () -> Bool in
            guard let self else { return false }
            defer { persistenceTask = nil }
            repeat {
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

    func terminationSave() -> Task<Bool, Never> {
        saveTask?.cancel()
        let snapshot = state
        let deletions = deletedNoteIDs
        let writer = repository
        let blocked = storageNeedsRecovery || isRestoringBackup
        return Task.detached {
            guard !blocked else { return false }
            do {
                try await writer.saveAndClose(snapshot, deletedNoteIDs: deletions)
                return true
            } catch { return false }
        }
    }

    func flush() async -> Bool {
        saveTask?.cancel()
        return await persist()
    }

    /// Transfers reconcile live files before taking a single in-memory snapshot.
    func portableSnapshot() async throws -> AppState {
        guard !isRestoringBackup, await flush(), !isRestoringBackup else {
            throw DataTransferFileError.cannotSynchronize
        }
        return state
    }

    func recoverState() async {
        do {
            try await repository.recoverByBackingUp()
            storageNeedsRecovery = false
            _ = await flush()
            await watchNotesFolder()
        } catch { saveError = "Recovery could not create a backup. The original files are unchanged." }
    }

    func restoreBackup(_ replacement: AppState) async -> Bool {
        guard !isRestoringBackup, !isTerminating, (try? StowBackup.encode(replacement)) != nil else { return false }
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
        // Preserve the current in-memory version as well as the repository's original files.
        do {
            let folder = stateURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: folder, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let backup = folder.appendingPathComponent("pre-restore-\(UUID().uuidString).stowbackup")
            try DataTransferFiles.writePrivateAtomically(StowBackup.encode(state), to: backup)
            var restored = replacement
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
            deletedNoteIDs.removeAll()
            conflictNoteIDs.removeAll()
            noteFileMessage = nil
            storageNeedsRecovery = false
            saveError = nil
            changeRevision &+= 1
            persistedRevision = changeRevision
            ThemeController.shared.apply(state.appearance)
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
