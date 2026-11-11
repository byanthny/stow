import AppKit
import Observation
import StowCore
import StowUpdates

/// Settings → Updates: daily checks while on, Check for updates… on request, and the board notice.
@MainActor @Observable
final class UpdateMonitor {
    /// Asks GitHub for Stow's releases; tests replace it.
    typealias Fetch = @Sendable () async throws -> [StowRelease]
    /// The one request an update check makes.
    static let github: Fetch = { try await ReleaseFeed.fetchReleases() }

    private(set) var settings = UpdateSettings()
    /// Why the settings couldn't be saved; nil once a save works.
    private(set) var problem: String?
    /// This copy's version.
    let running: ReleaseVersion?
    /// Says what Check for updates… found. Tests replace it.
    @ObservationIgnored var report: @MainActor (UpdateOutcome, ReleaseVersion?) -> Void = UpdateMonitor.showAlert
    @ObservationIgnored private let catalog: ProfileCatalog
    @ObservationIgnored private let fetch: Fetch
    @ObservationIgnored private var check: Task<UpdateOutcome, Never>?
    @ObservationIgnored private var schedule: Task<Void, Never>?
    @ObservationIgnored private var saving: Task<Void, any Error>?

    init(catalog: ProfileCatalog, running: ReleaseVersion?, fetch: @escaping Fetch) {
        self.catalog = catalog
        self.running = running
        self.fetch = fetch
    }

    /// The release the board offers, if any.
    var notice: StowRelease? { running.flatMap { settings.notice(running: $0) } }

    /// Takes the saved settings, and starts the daily check when they have it on.
    func start(with saved: UpdateSettings) {
        settings = saved
        reschedule()
    }

    /// Turns daily checks on or off; throws, keeping the old value, when the setting can't be saved.
    func setChecksForUpdates(_ enabled: Bool) async throws {
        let previous = settings.checksForUpdates
        settings.checksForUpdates = enabled
        do {
            try await save()
        } catch {
            if settings.checksForUpdates == enabled { settings.checksForUpdates = previous }
            throw error
        }
        reschedule()
    }

    /// Check for updates…: asks now, whatever the setting, and says what it found.
    func checkAndReport() async {
        report(await runCheck(), running)
    }

    /// Hides the notice until a newer release is out.
    func dismissNotice() {
        guard let notice else { return }
        settings.dismissedVersion = notice.version
        Task { try? await save() }
    }

    /// While on, checks hourly whether a day has passed since the last check that worked.
    private func reschedule() {
        schedule?.cancel()
        schedule = nil
        guard settings.checksForUpdates else { return }
        schedule = Task { [weak self] in
            while !Task.isCancelled {
                guard await self?.checkIfDue() != nil else { return }
                try? await Task.sleep(for: .seconds(60 * 60))
            }
        }
    }

    private func checkIfDue() async {
        guard UpdatePolicy.standard.isDue(lastCheck: settings.lastCheckAt, now: .now) else { return }
        _ = await runCheck()
    }

    /// One check at a time: asking while one runs gets its outcome.
    private func runCheck() async -> UpdateOutcome {
        if let check { return await check.value }
        let task = Task { await performCheck() }
        check = task
        let outcome = await task.value
        if check == task { check = nil }
        return outcome
    }

    private func performCheck() async -> UpdateOutcome {
        guard let running else { return .failed(.unknownVersion) }
        let started = Date.now
        let result: Result<[StowRelease], UpdateCheckError>
        do {
            result = .success(try await fetch())
        } catch {
            result = .failure(error as? UpdateCheckError ?? .unreachable)
        }
        let outcome = settings.record(result, running: running, at: started)
        // With the setting off, a check leaves nothing on disk.
        if settings.checksForUpdates { try? await save() }
        return outcome
    }

    /// Saves the settings as they are when the write starts, after any write still running.
    private func save() async throws {
        let previous = saving
        let task = Task {
            _ = await previous?.result
            do {
                try await catalog.setUpdateSettings(settings)
                problem = nil
            } catch {
                problem =
                    error as? ProfileError == .unwritable
                    ? "Stow couldn’t save its update settings. Check that the data folder can be written to and has space."
                    : profileProblem(error, name: "Stow")
                throw error
            }
        }
        saving = task
        try await task.value
    }

    /// The alert Check for updates… shows.
    static func showAlert(_ outcome: UpdateOutcome, running: ReleaseVersion?) {
        let alert = NSAlert()
        let current = running.map { "You have Stow \($0)." } ?? ""
        switch outcome {
        case .available(let release):
            alert.messageText = "Stow \(release.version) is available"
            alert.informativeText = "\(current) Its release page has the download and what changed."
            alert.addButton(withTitle: "View release")
            alert.addButton(withTitle: "Later")
            if alert.runModal() == .alertFirstButtonReturn { AppStore.openLink(release.page) }
        case .upToDate:
            alert.messageText = "Stow is up to date"
            alert.informativeText = current
            alert.addButton(withTitle: "OK")
            alert.runModal()
        case .failed(let error):
            alert.messageText = "Stow couldn’t check for updates"
            alert.informativeText = error.errorDescription ?? ""
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
}

extension ReleaseVersion {
    /// This copy of Stow's version, from its Info.plist.
    static var running: ReleaseVersion? {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String).flatMap(ReleaseVersion.init)
    }
}
