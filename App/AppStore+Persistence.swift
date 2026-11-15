import AppKit
import StowCore

extension AppStore {
    func watchNotesFolder() async {
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
    func persist(allowDuringRestore: Bool = false) async -> Bool {
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
                    if incoming.markdown != original.markdown {
                        state.notes[index].markdown = incoming.markdown
                        state.notes[index].updatedAt = incoming.updatedAt
                    }
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
                restored.pullRequests[index].markStale()
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
}
