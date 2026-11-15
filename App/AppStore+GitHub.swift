import Foundation
import StowCore
import StowGitHub

extension AppStore {
    func configureGitHub() {
        sessionGeneration += 1
        cancelDetails()
        accountMismatch = nil
        if let previous = coordinator { Task { await previous.cancel() } }
        coordinator = nil
        githubClient = nil
        isRefreshing = false
        guard base.githubEnabled, !isDemo, !isStopped else { return }
        if let githubOverride {
            githubClient = githubOverride
            coordinator = RefreshCoordinator(client: githubOverride)
            return
        }
        guard
            let executable = GHClient.discoverExecutable(preferredPath: base.ghExecutablePath, excluding: dataFolder)
        else {
            githubMessage = "GitHub is unavailable. Install gh or choose its executable in Settings."
            return
        }
        let client = githubClientFactory?(executable) ?? GHClient(executableURL: executable, excluding: dataFolder)
        githubClient = client
        coordinator = RefreshCoordinator(client: client)
    }

    func answerGitHubSetup(useGitHub: Bool) {
        offersGitHubSetup = false
        if useGitHub { setGitHubEnabled(true) }
    }

    func setGitHubEnabled(_ enabled: Bool) {
        offersGitHubSetup = false
        base.githubEnabled = enabled
        githubMessage = nil
        configureGitHub()
        changed()
        if enabled { runOwned { await $0.refresh() } }
    }

    func setExecutablePath(_ path: String?) {
        base.ghExecutablePath = path
        configureGitHub()
        changed()
        runOwned { await $0.refresh() }
    }

    func refresh() async {
        guard isLoaded, !isRestoringBackup, !isPaused, !isStopped, base.githubEnabled, !isDemo, let coordinator
        else { return }
        let attempt = now()
        lastRefreshAttempt = attempt
        let generation = sessionGeneration
        isRefreshing = true
        defer { if generation == sessionGeneration { isRefreshing = false } }
        do {
            let result = try await coordinator.refresh(
                pins: base.pins, previous: knownPullRequests, expectedViewerLogin: base.viewerLogin)
            guard generation == sessionGeneration, base.githubEnabled else { return }
            if let expected = base.viewerLogin,
                expected.caseInsensitiveCompare(result.viewerLogin) != .orderedSame
            {
                // Defense for injected clients: another account's result is never applied.
                forgetFailedAttempt(attempt)
                markAccountMismatch(actual: result.viewerLogin)
                return
            }
            accountMismatch = nil
            base.viewerLogin = result.viewerLogin
            setPullRequests(
                reconcileSnapshots(
                    previous: knownPullRequests, incoming: result.snapshots, pins: base.pins, now: result.fetchedAt,
                    keepTime: base.terminalCardKeepTime))
            isRefreshing = false
            base.lastRefreshAt = result.fetchedAt
            githubMessage =
                result.warning
                ?? (result.isComplete ? nil : "Some GitHub data is incomplete. Cached cards are retained.")
            changed()
        } catch GitHubError.accountMismatch(let actual) {
            forgetFailedAttempt(attempt)
            guard generation == sessionGeneration else { return }
            // A refresh that asked for an older login can name the one this profile now uses; that is no mismatch.
            if base.viewerLogin?.caseInsensitiveCompare(actual) == .orderedSame { return }
            markAccountMismatch(actual: actual)
        } catch {
            forgetFailedAttempt(attempt)
            guard generation == sessionGeneration else { return }
            markCardsStale()
            githubMessage = error.localizedDescription
        }
    }

    /// Refreshes as Stow comes forward, unless a refresh that didn't fail asked GitHub within the last minute.
    func refreshOnActivation() async {
        if let lastRefreshAttempt, now() < lastRefreshAttempt + .seconds(60) { return }
        await refresh()
    }

    /// Lets the next activation refresh, unless a later attempt has started since.
    private func forgetFailedAttempt(_ attempt: ContinuousClock.Instant) {
        if lastRefreshAttempt == attempt { lastRefreshAttempt = nil }
    }

    /// Cards kept only in memory go stale too, so an owner selected afterwards never shows readiness it lost.
    private func markCardsStale() {
        func markStale(_ cards: inout [PullRequestSnapshot]) {
            for index in cards.indices {
                cards[index].markStale()
                cards[index].readinessIsComplete = false
            }
        }
        markStale(&base.pullRequests)
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
        base.viewerLogin = actual
        base.pullRequests = []
        memoryOnlyPullRequests = []
        base.dismissedIDs = []
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
        guard !isDemo, base.githubEnabled, accountMismatch == nil, let githubClient,
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
                guard generation == sessionGeneration, base.githubEnabled,
                    let index = base.pullRequests.firstIndex(where: { $0.id == reference.id })
                else { return }
                base.pullRequests[index].details = details
                changed()
            } catch is CancellationError {} catch {
                if !Task.isCancelled, detailTokens[reference.id] == token,
                    generation == sessionGeneration && base.githubEnabled
                {
                    githubMessage = "Details are unavailable. The cached card is still available."
                }
            }
        }
    }

    var visiblePRs: [PullRequestSnapshot] {
        guard base.githubEnabled else { return [] }
        return base.pullRequests.filter { !base.dismissedIDs.contains($0.id) }
    }

    /// A section's cards, newest first. The owner selection leaves out other owners' cards, except pinned ones, and
    /// never changes how a card is classified. Unpinned merged and closed cards are in `mergedCards` instead.
    func cards(in section: AttentionSection) -> [PullRequestSnapshot] {
        let cards = visiblePRs.filter {
            let isPinned = base.pins.contains($0.reference)
            return isShown($0, selection: base.ownerSelection, pins: base.pins)
                && classify($0, isPinned: isPinned).section == section && (isPinned || !$0.isTerminal)
        }
        return pinnedFirst(cards, pins: base.pins)
    }

    /// The section identifier of the Merged group, which sits under Waiting and isn't part of the saved order.
    static let mergedGroupID = "merged"

    /// The Merged group's cards: unpinned merged and closed ones of the selected owners, newest first.
    var mergedCards: [PullRequestSnapshot] {
        let cards = visiblePRs.filter {
            $0.isTerminal && !base.pins.contains($0.reference)
                && isShown($0, selection: base.ownerSelection, pins: base.pins)
        }
        return pinnedFirst(cards, pins: [])
    }

    /// Every card the profile knows now: the saved ones, then those kept only in memory.
    private var knownPullRequests: [PullRequestSnapshot] { base.pullRequests + memoryOnlyPullRequests }

    /// Replaces the cards. While the profile keeps only its selected owners on disk, other owners' cards go to
    /// memory instead of the saved state, unless they are pinned.
    private func setPullRequests(_ cards: [PullRequestSnapshot]) {
        guard base.keepsOnlySelectedOwners else {
            base.pullRequests = cards
            memoryOnlyPullRequests = []
            return
        }
        let kept = retainingSelectedOwners(cards, selection: base.ownerSelection, pins: base.pins)
        let keptIDs = Set(kept.map(\.id))
        base.pullRequests = kept
        memoryOnlyPullRequests = cards.filter { !keptIDs.contains($0.id) }
    }

    /// Moves cards between the saved state and memory after the selection, the pins, or the storage setting change.
    private func reapplyKeptOwners() {
        guard base.keepsOnlySelectedOwners || !memoryOnlyPullRequests.isEmpty else { return }
        setPullRequests(knownPullRequests)
    }

    /// The owners the owner control lists: from cards, pins, and the selection, with counts of cards that are not
    /// dismissed. While the profile keeps only its selected owners on disk, other owners' counts come from the
    /// latest refresh, kept in memory.
    var ownerSummaries: [OwnerSummary] {
        StowCore.ownerSummaries(
            pullRequests: knownPullRequests, pins: base.pins, dismissedIDs: base.dismissedIDs,
            selection: base.ownerSelection, order: base.boardLayout.ownerOrder)
    }

    /// The board header shows the owner control with GitHub on and cards from more than one owner, whenever a
    /// selection is active, so it never hides cards silently, or always when Settings → Board asks.
    var showsOwnerControl: Bool {
        StowCore.showsOwnerControl(
            githubEnabled: base.githubEnabled, pullRequests: visiblePRs, selection: base.ownerSelection,
            alwaysShow: base.boardLayout.alwaysShowOwnerControl)
    }

    /// Chooses whose pull requests show, and saves. A profile that keeps only its selected owners on disk also
    /// refreshes at once, so an owner just added gets its cards.
    func setOwnerSelection(_ selection: OwnerSelection) {
        guard selection != base.ownerSelection else { return }
        base.ownerSelection = selection
        reapplyKeptOwners()
        changed()
        if base.keepsOnlySelectedOwners { runOwned { await $0.refresh() } }
    }

    /// Settings → Board → Keep only selected owners on disk. Turning it on takes other owners' cards out of the
    /// saved state at once, keeping pins; turning it off saves the cards held in memory again.
    func setKeepsOnlySelectedOwners(_ keeps: Bool) {
        guard keeps != base.keepsOnlySelectedOwners else { return }
        base.keepsOnlySelectedOwners = keeps
        reapplyKeptOwners()
        changed()
    }

    /// Settings → Board → Keep merged and closed. A shorter time takes cards already past it off the board at once.
    func setTerminalCardKeepTime(_ keepTime: TerminalCardKeepTime) {
        guard keepTime != base.terminalCardKeepTime else { return }
        base.terminalCardKeepTime = keepTime
        setPullRequests(
            droppingExpiredTerminalCards(knownPullRequests, pins: base.pins, keepTime: keepTime, now: .now))
        changed()
    }

    /// The notes the board lists. With Settings → Board → Hide notes linked to hidden owners on, a note linked to
    /// another owner's pull request hides, unless that card is pinned and so shows. Standalone notes always show,
    /// and hiding never closes a detached note's window.
    var visibleNotes: [NoteModel] {
        // Without GitHub there is no owner control to show the selection, so it hides nothing.
        guard base.githubEnabled, base.boardLayout.hidesNotesForHiddenOwners else { return notes }
        return notes.filter { note in
            isNoteShown(linkedTo: note.pullRequest, selection: base.ownerSelection, hidesLinkedNotes: true)
                || note.pullRequest.map { base.pins.contains($0) } == true
        }
    }

    func pin(_ reference: PullRequestReference) {
        if !base.pins.contains(reference) { base.pins.append(reference) }
        base.dismissedIDs.removeAll { $0 == reference.id }
        // A card held only in memory is saved again once pinned.
        reapplyKeptOwners()
        if !base.pullRequests.contains(where: { $0.id == reference.id }) {
            base.pullRequests.append(.init(reference: reference, title: reference.displayName, isStale: true))
        }
        changed()
        runOwned { await $0.refresh() }
    }

    func togglePin(_ reference: PullRequestReference) {
        if base.pins.contains(reference) {
            base.pins.removeAll { $0 == reference }
            // Unpinned, a card of an owner outside the selection is no longer saved.
            reapplyKeptOwners()
            changed()
        } else {
            pin(reference)
        }
    }

    func dismiss(_ reference: PullRequestReference) {
        if !base.dismissedIDs.contains(reference.id) { base.dismissedIDs.append(reference.id) }
        changed()
    }

    func restoreDismissal(_ id: String) {
        base.dismissedIDs.removeAll { $0 == id }
        changed()
    }
}
