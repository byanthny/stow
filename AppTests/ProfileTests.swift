import AppKit
import Foundation
import StowExtensionSDK
import StowGitHub
import StowSampleExtension
import XCTest

@testable import Stow
// The catalog's test seams are internal.
@testable import StowCore

/// Profile sessions on synthetic state in temporary folders, never the normal data folder.
@MainActor
final class ProfileTests: XCTestCase {
    func testDataFolderOpensAsSingleProfileWithoutWritingIndex() async throws {
        // A folder saved by a build without profiles, then a new installation.
        for seeded in [true, false] {
            let folder = try makeDirectory()
            defer { try? FileManager.default.removeItem(at: folder) }
            if seeded { try await seed(folder) }
            let manager = ProfileManager(dataFolder: folder, isDemo: false)
            defer { stop(manager) }
            let opened = await manager.start()
            XCTAssertTrue(opened)
            XCTAssertEqual(manager.profiles.map(\.isDataFolder), [true])
            XCTAssertEqual(manager.sessions.count, 1)
            let session = try XCTUnwrap(manager.activeSession)
            XCTAssertEqual(session.entry.name, "Stow")
            XCTAssertEqual(manager.lastActiveID, session.entry.id)
            XCTAssertFalse(manager.showsProfileNames)
            XCTAssertEqual(session.board.title, "Stow")
            XCTAssertTrue(session.board.isVisible)
            session.showSettings()
            XCTAssertEqual(session.settingsWindow?.title, "Stow settings")
            // A new installation still asks before using GitHub.
            XCTAssertEqual(session.store.offersGitHubSetup, !seeded)
            let saved = await session.store.flush()
            XCTAssertTrue(saved)
            XCTAssertTrue(exists("state.json", in: folder))
            for name in [ProfileIndex.filename, ProfileIdentity.filename, ProfileCatalog.profilesDirectoryName] {
                XCTAssertFalse(exists(name, in: folder), "\(name) must not be written")
            }
        }
    }

    func testProfileLockedElsewhereStaysClosed() async throws {
        let folder = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        try await seed(folder)
        let stateURL = folder.appendingPathComponent("state.json")
        let before = try Data(contentsOf: stateURL)
        // flock refuses a second lock on the file within one process, as it would for another process.
        guard case .acquired(let held) = StateLock.acquire(forStateAt: stateURL) else {
            return XCTFail("The test could not take the profile lock")
        }
        defer { held.release() }
        let manager = ProfileManager(dataFolder: folder, isDemo: false)
        defer { stop(manager) }
        let opened = await manager.start()
        XCTAssertFalse(opened)
        XCTAssertTrue(manager.sessions.isEmpty)
        XCTAssertNil(manager.activeSession)
        XCTAssertEqual(manager.profiles.count, 1)
        XCTAssertEqual(try Data(contentsOf: stateURL), before)
    }

    func testStopClosesWindowsKeepsNotesDetachedAndReleasesLock() async throws {
        let folder = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        try await seed(folder, detached: true)
        let manager = ProfileManager(dataFolder: folder, isDemo: false)
        defer { stop(manager) }
        let opened = await manager.start()
        XCTAssertTrue(opened)
        let session = try XCTUnwrap(manager.activeSession)
        let note = try XCTUnwrap(session.store.state.notes.first)
        let board = try XCTUnwrap(session.board)
        let noteWindow = try XCTUnwrap(session.noteWindows[note.id])
        XCTAssertTrue(noteWindow.isVisible)
        XCTAssertEqual(noteWindow.title, "Synthetic profile note")

        session.stop()
        XCTAssertNil(session.board)
        XCTAssertTrue(session.noteWindows.isEmpty)
        XCTAssertFalse(board.isVisible)
        XCTAssertFalse(noteWindow.isVisible)
        // Closing a profile's windows is not closing its notes; they reopen with the profile.
        XCTAssertEqual(session.store.note(note.id)?.isDetached, true)
        // A stopped session is never the one menus act on.
        XCTAssertNil(manager.activeSession)
        guard case .acquired(let lock) = StateLock.acquire(forStateAt: folder.appendingPathComponent("state.json"))
        else { return XCTFail("Stopping must release the profile lock") }
        lock.release()
    }

    func testSettingsSharesThePinnedWindowsLevel() async throws {
        let folder = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        try await seed(folder, detached: true)
        let manager = makeManager(folder)
        defer { stop(manager) }
        let started = await manager.start()
        XCTAssertTrue(started)
        let session = try XCTUnwrap(manager.activeSession)
        let note = try XCTUnwrap(session.store.state.notes.first)
        session.showSettings()
        let settings = try XCTUnwrap(session.settingsWindow)
        // The board and detached notes start pinned.
        XCTAssertEqual(settings.level, .floating, "A pinned board never covers Settings")

        session.store.toggleBoardAlwaysOnTop()
        session.store.toggleAlwaysOnTop(note.id)
        XCTAssertEqual(session.board?.level, .normal)
        XCTAssertEqual(session.noteWindows[note.id]?.level, .normal)
        XCTAssertEqual(settings.level, .normal, "With nothing pinned, Settings is an ordinary window")

        session.store.toggleAlwaysOnTop(note.id)
        XCTAssertEqual(settings.level, .floating, "Nor does a note kept on top")
    }

    func testTwoProfilesStayIsolated() async throws {
        let folder = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        try await seed(folder)
        let workEntry = try await addProfile("Work", in: folder)
        let manager = makeManager(folder)
        defer { stop(manager) }
        let started = await manager.start()
        XCTAssertTrue(started)
        let opened = await manager.open(workEntry.id)
        XCTAssertTrue(opened)
        let main = try XCTUnwrap(manager.sessions.values.first { $0.entry.isDataFolder })
        let work = try XCTUnwrap(manager.sessions[workEntry.id])
        XCTAssertTrue(manager.showsProfileNames)
        XCTAssertEqual(main.entry.name, "Stow")
        XCTAssertEqual(main.board.title, "Stow")
        XCTAssertEqual(work.board.title, "Work")

        let mainNote = main.store.addNote("Synthetic note kept in Stow")
        let workNote = work.store.addNote("Synthetic note kept in Work")
        work.store.detachNote(workNote)
        XCTAssertEqual(work.noteWindows[workNote]?.title, "Synthetic note kept in Work — Work")
        work.showSettings()
        XCTAssertEqual(work.settingsWindow?.title, "Work settings")
        let mainSaved = await main.store.flush()
        let workSaved = await work.store.flush()
        XCTAssertTrue(mainSaved)
        XCTAssertTrue(workSaved)

        for (session, own, other) in [(main, mainNote, workNote), (work, workNote, mainNote)] {
            let saved = try await StateRepository(url: session.store.stateURL).load()
            XCTAssertTrue(saved.notes.contains { $0.id == own }, session.entry.name)
            XCTAssertFalse(saved.notes.contains { $0.id == other }, session.entry.name)
            let files = try FileManager.default.contentsOfDirectory(atPath: session.store.notesDirectory.path)
            XCTAssertTrue(files.contains("\(own.uuidString).md"), session.entry.name)
            XCTAssertFalse(files.contains("\(other.uuidString).md"), session.entry.name)
        }
        XCTAssertNotEqual(
            main.store.notesDirectory.standardizedFileURL, work.store.notesDirectory.standardizedFileURL)
    }

    // MARK: Account mismatch

    func testMismatchPausesAndKeepsCachedCards() async throws {
        let (manager, session, client) = try await startMismatchProfile()
        defer { stop(manager) }
        let store = session.store
        await client.set(login: "other-account")
        await store.refresh()
        XCTAssertEqual(store.accountMismatch, "other-account")
        XCTAssertEqual(store.state.viewerLogin, "old-account")
        XCTAssertEqual(store.state.pullRequests.map(\.title), ["Synthetic cached card"])
        XCTAssertTrue(store.state.pullRequests.allSatisfy { $0.isStale && !$0.readinessIsComplete })
        XCTAssertEqual(store.state.dismissedIDs, ["dismissed"])
        // Refreshes keep checking while mismatched.
        await store.refresh()
        let refreshes = await client.refreshes
        XCTAssertEqual(refreshes, 2)
        XCTAssertEqual(store.state.pullRequests.map(\.title), ["Synthetic cached card"])
    }

    func testResultWithAnotherLoginIsNeverApplied() async throws {
        // An injected client that does not throw: the store guards on its own.
        let (manager, session, client) = try await startMismatchProfile()
        defer { stop(manager) }
        await client.set(login: "Other-Account", throwing: false)
        await session.store.refresh()
        XCTAssertEqual(session.store.accountMismatch, "Other-Account")
        XCTAssertEqual(session.store.state.viewerLogin, "old-account")
        XCTAssertEqual(session.store.state.pullRequests.map(\.title), ["Synthetic cached card"])
    }

    func testUseCurrentAccountClearsCacheKeepsNotesAndPins() async throws {
        let (manager, session, client) = try await startMismatchProfile()
        defer { stop(manager) }
        let store = session.store
        await client.set(login: "other-account")
        await store.refresh()
        let pin = try XCTUnwrap(store.state.pins.first)
        store.expandedPRs = [pin.id]
        await store.useCurrentAccount()
        XCTAssertNil(store.accountMismatch)
        XCTAssertEqual(store.state.viewerLogin, "other-account")
        XCTAssertTrue(store.state.dismissedIDs.isEmpty)
        XCTAssertTrue(store.expandedPRs.isEmpty)
        XCTAssertEqual(store.state.pullRequests.map(\.title), ["Synthetic card of the other account"])
        XCTAssertEqual(store.state.pins, [pin])
        XCTAssertEqual(store.state.notes.map(\.markdown), ["Synthetic profile note"])
    }

    func testDetailsRefusedWhileMismatched() async throws {
        let (manager, session, client) = try await startMismatchProfile()
        defer { stop(manager) }
        let store = session.store
        await client.set(login: "other-account")
        await store.refresh()
        let reference = try XCTUnwrap(store.state.pullRequests.first?.reference)
        store.toggleDetails(reference)
        try await Task.sleep(for: .milliseconds(100))
        let requests = await client.detailRequests
        XCTAssertEqual(requests, 0)
        XCTAssertTrue(store.loadingDetails.isEmpty)
    }

    func testAccountReturningClearsMismatch() async throws {
        let (manager, session, client) = try await startMismatchProfile()
        defer { stop(manager) }
        let store = session.store
        await client.set(login: "other-account")
        await store.refresh()
        XCTAssertNotNil(store.accountMismatch)
        await client.set(login: "OLD-account")
        await store.refresh()
        XCTAssertNil(store.accountMismatch)
        XCTAssertEqual(store.state.viewerLogin?.lowercased(), "old-account")
        XCTAssertEqual(store.state.pullRequests.map(\.title), ["Synthetic card of the old account"])
    }

    func testUseCurrentAccountDuringASlowRefreshKeepsTheNewAccount() async throws {
        let folder = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let reference = PullRequestReference(owner: "example", repository: "fixture", number: 1)
        try await seed(folder) { state in
            state.githubEnabled = true
            state.viewerLogin = "old-account"
            state.pins = [reference]
            state.pullRequests = [.init(reference: reference, title: "Synthetic cached card")]
        }
        let client = SlowMismatchClient(reference: reference)
        let manager = makeManager(folder, githubOverride: { _ in client })
        defer { stop(manager) }
        let started = await manager.start()
        XCTAssertTrue(started)
        let store = try XCTUnwrap(manager.activeSession).store
        await store.refresh()
        XCTAssertEqual(store.accountMismatch, "other-account")

        // A refresh for the old login starts just before the person chooses Use other-account here, and gh
        // answers it slowly.
        await client.holdNextMismatch()
        let slow = Task { await store.refresh() }
        let holding = await waitUntil { await client.isHolding }
        XCTAssertTrue(holding)
        let adopting = Task { await store.useCurrentAccount() }
        // The new account's refresh does not join the slow one.
        let refreshedApart = await waitUntil { await client.refreshes == 3 }
        XCTAssertTrue(refreshedApart)
        await client.release()
        await adopting.value
        await slow.value
        XCTAssertNil(store.accountMismatch, "The slow answer for the old login must not bring the banner back")
        XCTAssertEqual(store.state.viewerLogin, "other-account")
        XCTAssertEqual(store.state.pullRequests.map(\.title), ["Synthetic card of the other account"])
    }

    private func startMismatchProfile() async throws -> (ProfileManager, ProfileSession, MismatchClient) {
        let folder = try makeDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let reference = PullRequestReference(owner: "example", repository: "fixture", number: 1)
        try await seed(folder) { state in
            state.githubEnabled = true
            state.viewerLogin = "old-account"
            state.pins = [reference]
            state.dismissedIDs = ["dismissed"]
            state.pullRequests = [.init(reference: reference, title: "Synthetic cached card")]
        }
        let client = MismatchClient(reference: reference)
        let manager = makeManager(folder, githubOverride: { _ in client })
        let started = await manager.start()
        XCTAssertTrue(started)
        return (manager, try XCTUnwrap(manager.activeSession), client)
    }

    func testProfilesShareOneClientPerGHLocation() async throws {
        let folder = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        var made: [URL] = []
        let manager = ProfileManager(
            dataFolder: folder, isDemo: false,
            githubClientMaker: { url in
                made.append(url)
                return CountingClient()
            })
        let first = manager.githubClient(for: URL(fileURLWithPath: "/synthetic/bin/gh"))
        let second = manager.githubClient(for: URL(fileURLWithPath: "/synthetic/bin/../bin/gh"))
        let other = manager.githubClient(for: URL(fileURLWithPath: "/synthetic/other/gh"))
        XCTAssertTrue(first as AnyObject === second as AnyObject)
        XCTAssertFalse(first as AnyObject === other as AnyObject)
        XCTAssertEqual(made.count, 2)
    }

    func testRateLimitPausesEveryProfileOnTheClient() async throws {
        let reference = PullRequestReference(owner: "example", repository: "fixture", number: 1)
        let transport = RateLimitedTransport()
        let client = GHClient(transport: transport)
        var stores: [AppStore] = []
        for _ in 0..<2 {
            let folder = try makeDirectory()
            addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
            try await seed(folder) { state in
                state.githubEnabled = true
                state.pins = [reference]
            }
            let store = AppStore(
                stateURL: folder.appendingPathComponent("state.json"), githubClient: client,
                accessoryProviders: [])
            await store.start()
            addTeardownBlock { @MainActor in store.stop() }
            stores.append(store)
        }
        let (a, b) = (stores[0], stores[1])
        await a.refresh()
        let afterA = transport.calls
        XCTAssertGreaterThan(afterA, 0)
        XCTAssertEqual(a.githubMessage?.hasPrefix("GitHub requests are paused"), true)
        await b.refresh()
        XCTAssertEqual(transport.calls, afterA, "B must not reach GitHub while A's backoff holds")
        XCTAssertEqual(b.githubMessage?.hasPrefix("GitHub requests are paused"), true)
    }

    func testHideOrdersOutEveryWindowAndPausesRefresh() async throws {
        let folder = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        try await seed(folder) { state in
            state.githubEnabled = true
            state.notes = [
                Note(markdown: "Synthetic floating note", isDetached: true, isAlwaysOnTop: true),
                Note(markdown: "Synthetic ordinary note", isDetached: true, isAlwaysOnTop: false),
            ]
        }
        let client = CountingClient()
        let manager = makeManager(folder, githubOverride: { _ in client })
        defer { stop(manager) }
        let started = await manager.start()
        XCTAssertTrue(started)
        let session = try XCTUnwrap(manager.activeSession)
        let id = session.entry.id
        session.showSettings()
        let windows = windows(of: session)
        XCTAssertEqual(windows.count, 4)
        XCTAssertTrue(windows.allSatisfy(\.isVisible))
        let frames = windows.map(\.frame)
        let levels = windows.map(\.level)
        await session.store.refresh()
        let refreshesBeforeHiding = await client.refreshes
        XCTAssertEqual(refreshesBeforeHiding, 1)

        manager.hide(id)
        XCTAssertTrue(session.isHidden)
        XCTAssertTrue(session.store.isPaused)
        for window in windows {
            XCTAssertFalse(window.isVisible, window.title)
            XCTAssertFalse(window.isMiniaturized, window.title)
        }
        // The refresh timer and app activation call refresh; a hidden profile does not poll GitHub.
        await session.store.refresh()
        let refreshesWhileHidden = await client.refreshes
        XCTAssertEqual(refreshesWhileHidden, 1)

        manager.show(id)
        XCTAssertFalse(session.isHidden)
        XCTAssertFalse(session.store.isPaused)
        XCTAssertTrue(windows.allSatisfy(\.isVisible))
        XCTAssertEqual(windows.map(\.frame), frames)
        XCTAssertEqual(windows.map(\.level), levels)
        let refreshedOnShow = await waitUntil { await client.refreshes == 2 }
        XCTAssertTrue(refreshedOnShow)
        try await Task.sleep(for: .milliseconds(200))
        let refreshesAfterShowing = await client.refreshes
        XCTAssertEqual(refreshesAfterShowing, 2)
    }

    func testHideKeepsAlwaysOnTopNotesWhenEnabled() async throws {
        let folder = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let floating = Note(markdown: "Synthetic floating note", isDetached: true, isAlwaysOnTop: true)
        let ordinary = Note(markdown: "Synthetic ordinary note", isDetached: true, isAlwaysOnTop: false)
        try await seed(folder) { state in
            state.notes = [floating, ordinary]
            state.hideKeepsAlwaysOnTopNotes = true
        }
        let manager = makeManager(folder)
        defer { stop(manager) }
        let started = await manager.start()
        XCTAssertTrue(started)
        let session = try XCTUnwrap(manager.activeSession)
        let floatingWindow = try XCTUnwrap(session.noteWindows[floating.id])
        let ordinaryWindow = try XCTUnwrap(session.noteWindows[ordinary.id])

        manager.hide(session.entry.id)
        XCTAssertTrue(session.isHidden)
        XCTAssertFalse(session.board.isVisible)
        XCTAssertFalse(ordinaryWindow.isVisible)
        XCTAssertTrue(floatingWindow.isVisible)
        XCTAssertEqual(floatingWindow.level, .floating)

        manager.show(session.entry.id)
        XCTAssertTrue(session.board.isVisible)
        XCTAssertTrue(ordinaryWindow.isVisible)
        XCTAssertTrue(floatingWindow.isVisible)
    }

    func testOpeningAnOpenProfileBringsItForward() async throws {
        let folder = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        try await seed(folder)
        let workEntry = try await addProfile("Work", in: folder)
        let manager = makeManager(folder)
        defer { stop(manager) }
        let started = await manager.start()
        XCTAssertTrue(started)
        let main = try XCTUnwrap(manager.activeSession)
        let opened = await manager.open(workEntry.id)
        XCTAssertTrue(opened)
        let work = try XCTUnwrap(manager.sessions[workEntry.id])
        assertForward(work, in: manager)

        let reopened = await manager.open(main.entry.id)
        XCTAssertTrue(reopened)
        XCTAssertEqual(manager.sessions.count, 2)
        XCTAssertTrue(manager.sessions[main.entry.id] === main)
        assertForward(main, in: manager)
    }

    func testWindowBecomingKeyMakesItsProfileLastActive() async throws {
        let folder = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        try await seed(folder, detached: true)
        let workEntry = try await addProfile("Work", in: folder)
        let manager = makeManager(folder)
        defer { stop(manager) }
        let started = await manager.start()
        XCTAssertTrue(started)
        let main = try XCTUnwrap(manager.activeSession)
        let opened = await manager.open(workEntry.id)
        XCTAssertTrue(opened)
        XCTAssertEqual(manager.lastActiveID, workEntry.id)

        // AppKit posts this when a window becomes key. A test host that is not the active app gets no key
        // changes, so the test posts it for a detached note and then for Settings.
        let note = try XCTUnwrap(main.noteWindows.values.first)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: note)
        XCTAssertEqual(manager.lastActiveID, main.entry.id)
        let work = try XCTUnwrap(manager.sessions[workEntry.id])
        work.showSettings()
        let settings = try XCTUnwrap(work.settingsWindow)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: settings)
        XCTAssertEqual(manager.lastActiveID, workEntry.id)
        XCTAssertTrue(manager.activeSession === work)
    }

    func testRapidHideShowCloseOpenLeavesConsistentState() async throws {
        let folder = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        try await seed(folder, detached: true)
        let workEntry = try await addProfile("Work", in: folder)
        let earlierWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        let manager = makeManager(folder)
        defer { stop(manager) }
        let started = await manager.start()
        XCTAssertTrue(started)
        let mainID = try XCTUnwrap(manager.activeSession).entry.id
        let workID = workEntry.id
        let opened = await manager.open(workID)
        XCTAssertTrue(opened)
        let workNote = try XCTUnwrap(manager.sessions[workID]).store.addNote("Synthetic work note")
        manager.sessions[workID]?.store.detachNote(workNote)

        enum Operation { case open, hide, show, close }
        let script: [(Operation, UUID)] = [
            (.hide, mainID), (.close, workID), (.show, workID), (.open, workID), (.hide, workID),
            (.show, mainID), (.close, mainID), (.open, mainID), (.hide, mainID), (.show, workID),
            (.close, workID), (.hide, mainID), (.open, workID), (.close, mainID), (.show, mainID),
            (.hide, workID), (.open, mainID), (.close, workID), (.show, workID), (.hide, mainID),
        ]
        XCTAssertEqual(script.count, 20)
        // Applied in order, the script leaves the first profile open and hidden and the work profile closed.
        enum Outcome { case closed, shown, hidden }
        var expected: [UUID: Outcome] = [mainID: .shown, workID: .shown]
        for (operation, id) in script {
            switch (operation, expected[id]) {
            case (.open, _): expected[id] = .shown
            case (.close, _): expected[id] = .closed
            case (.hide, .shown): expected[id] = .hidden
            case (.show, .hidden): expected[id] = .shown
            default: break
            }
        }
        XCTAssertEqual(expected, [mainID: .hidden, workID: .closed])

        // Each request goes out in its own task, without waiting for the others. Main-actor tasks start in the
        // order they were made, so requests reach the manager in script order. Most hides and shows arrive while
        // an open or close of their profile is pending, so they wait in its queue.
        var pending: [Task<Void, Never>] = []
        for (operation, id) in script {
            pending.append(
                Task {
                    switch operation {
                    case .open: await manager.open(id)
                    case .close: _ = await manager.close(id)
                    case .hide: manager.hide(id)
                    case .show: manager.show(id)
                    }
                })
        }
        for task in pending { await task.value }
        let settled = await waitUntil { !manager.hasPendingRequests }
        XCTAssertTrue(settled)

        for id in [mainID, workID] {
            let stateURL = try XCTUnwrap(manager.profiles.first { $0.id == id }).folder
                .appendingPathComponent("state.json")
            let lock = StateLock.acquire(forStateAt: stateURL)
            if let session = manager.sessions[id] {
                XCTAssertTrue(isHeld(lock), "An open profile holds its lock")
                let board = try XCTUnwrap(session.board)
                XCTAssertEqual(board.isVisible, !session.isHidden)
                XCTAssertEqual(session.store.isPaused, session.isHidden)
                for window in session.noteWindows.values { XCTAssertEqual(window.isVisible, !session.isHidden) }
            } else {
                guard case .acquired(let free) = lock else {
                    XCTFail("A closed profile must not keep its lock")
                    continue
                }
                free.release()
            }
        }
        for window in NSApp.windows where window.isVisible && !earlierWindows.contains(ObjectIdentifier(window)) {
            XCTAssertNotNil(manager.session(owning: window), "Orphan window \(window.title)")
        }
        // The first profile ends hidden only if the last hide waited for the close and the open queued before it.
        XCTAssertEqual(manager.sessions[mainID]?.isHidden, true)
        XCTAssertNil(manager.sessions[workID])

        // The manager still opens and closes normally afterwards, and no note was lost.
        let reopened = await manager.open(workID)
        XCTAssertTrue(reopened)
        let closed = await manager.close(mainID)
        XCTAssertTrue(closed)
        let work = try XCTUnwrap(manager.sessions[workID])
        XCTAssertTrue(work.board.isVisible)
        XCTAssertFalse(work.isHidden)
        XCTAssertEqual(work.store.note(workNote)?.markdown, "Synthetic work note")
        XCTAssertNil(manager.sessions[mainID])
        let mainState = try await StateRepository(url: folder.appendingPathComponent("state.json")).load()
        XCTAssertEqual(mainState.notes.count, 1)
    }

    func testSwitchAfterHidingTheLastActiveProfileStartsFromTheVisibleOne() async throws {
        let folder = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        try await seed(folder)
        let workEntry = try await addProfile("Work", in: folder)
        let manager = makeManager(folder)
        defer { stop(manager) }
        let started = await manager.start()
        XCTAssertTrue(started)
        let main = try XCTUnwrap(manager.activeSession)
        let opened = await manager.open(workEntry.id)
        XCTAssertTrue(opened)
        let work = try XCTUnwrap(manager.sessions[workEntry.id])
        XCTAssertEqual(manager.lastActiveID, workEntry.id)

        // While Stow is inactive no window is key, so only the sessions say which profile is on screen.
        manager.hide(workEntry.id)
        // When the test host is the active app, as on CI, AppKit makes the remaining board key during the hide,
        // which records Stow as last active. Mark Work as last active, as it stays while Stow is inactive.
        work.onActivate?()
        XCTAssertEqual(manager.lastActiveID, workEntry.id)
        XCTAssertTrue(manager.activeSession === main, "Menus act on the profile that shows")

        await manager.switchTo(workEntry.id)
        assertForward(work, in: manager)
        XCTAssertTrue(main.isHidden, "The switch leaves the profile that was on screen")

        // With every profile hidden, the most recently active one is still the one menus act on.
        manager.hide(workEntry.id)
        XCTAssertTrue(manager.activeSession === work)
    }

    func testCloseReleasesLockAndReopenRestoresWindows() async throws {
        let folder = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        try await seed(folder, detached: true)
        let manager = makeManager(folder)
        defer { stop(manager) }
        let started = await manager.start()
        XCTAssertTrue(started)
        let session = try XCTUnwrap(manager.activeSession)
        let id = session.entry.id
        let note = try XCTUnwrap(session.store.state.notes.first)
        let board = try XCTUnwrap(session.board)
        let noteWindow = try XCTUnwrap(session.noteWindows[note.id])
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let boardFrame = NSRect(
            x: screen.minX + 50, y: screen.minY + 60, width: min(390, screen.width), height: min(580, screen.height))
        let noteFrame = NSRect(
            x: screen.minX + 30, y: screen.minY + 40, width: min(360, screen.width), height: min(400, screen.height))
        board.setFrame(boardFrame, display: true)
        noteWindow.setFrame(noteFrame, display: true)
        session.windowDidMove(Notification(name: NSWindow.didMoveNotification, object: board))
        session.windowDidMove(Notification(name: NSWindow.didMoveNotification, object: noteWindow))
        session.store.editNote(note.id, markdown: "Final edit right before closing")

        let closed = await manager.close(id)
        XCTAssertTrue(closed)
        XCTAssertNil(manager.sessions[id])
        XCTAssertNil(manager.activeSession)
        XCTAssertFalse(board.isVisible)
        XCTAssertFalse(noteWindow.isVisible)
        let stateURL = folder.appendingPathComponent("state.json")
        guard case .acquired(let lock) = StateLock.acquire(forStateAt: stateURL) else {
            return XCTFail("Closing must release the profile lock")
        }
        let saved = try await StateRepository(url: stateURL).load()
        lock.release()
        XCTAssertEqual(saved.notes.first?.markdown, "Final edit right before closing")
        XCTAssertEqual(saved.notes.first?.isDetached, true)

        let reopened = await manager.open(id)
        XCTAssertTrue(reopened)
        let restored = try XCTUnwrap(manager.sessions[id])
        XCTAssertFalse(restored === session)
        XCTAssertTrue(restored.board.isVisible)
        XCTAssertEqual(restored.board.frame, boardFrame)
        let restoredNote = try XCTUnwrap(restored.noteWindows[note.id])
        XCTAssertTrue(restoredNote.isVisible)
        XCTAssertEqual(restoredNote.frame, noteFrame)
        XCTAssertEqual(restored.store.note(note.id)?.markdown, "Final edit right before closing")
    }

    func testCloseAsksBeforeDiscardingUnsavedChanges() async throws {
        let folder = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        try await seed(folder)
        let questions = Recorder(answers: [false, true])
        let manager = makeManager(folder)
        manager.confirmClosingWithoutSaving = { entry in questions.answer(entry) }
        defer { stop(manager) }
        let started = await manager.start()
        XCTAssertTrue(started)
        let session = try XCTUnwrap(manager.activeSession)
        let id = session.entry.id
        let note = try XCTUnwrap(session.store.state.notes.first)
        let notes = session.store.notesDirectory
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: notes.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: notes.path) }
        session.store.editNote(note.id, markdown: "Synthetic edit that cannot be saved")

        let keptOpen = await manager.close(id)
        XCTAssertFalse(keptOpen)
        XCTAssertEqual(questions.names, ["Stow"])
        XCTAssertTrue(manager.sessions[id] === session)
        XCTAssertTrue(session.board.isVisible)
        XCTAssertTrue(isHeld(StateLock.acquire(forStateAt: folder.appendingPathComponent("state.json"))))
        XCTAssertEqual(session.store.note(note.id)?.markdown, "Synthetic edit that cannot be saved")

        let closed = await manager.close(id)
        XCTAssertTrue(closed)
        XCTAssertEqual(questions.names, ["Stow", "Stow"])
        XCTAssertNil(manager.sessions[id])
        XCTAssertFalse(session.board?.isVisible == true)
        guard case .acquired(let lock) = StateLock.acquire(forStateAt: folder.appendingPathComponent("state.json"))
        else { return XCTFail("Closing without saving must still release the profile lock") }
        lock.release()
    }

    func testClosedProfileStartsNoAccessoriesWhenItsResumeRefreshReturns() async throws {
        let folder = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        try await seed(folder) { state in
            state.githubEnabled = true
            state.extensionInstances = [
                ExtensionInstanceState(moduleID: "org.stow.sample", slot: .boardAccessory, isEnabled: false)
            ]
        }
        let delayed = DelayedClient()
        let provider = RecordingAccessoryProvider()
        let manager = makeManager(folder, githubOverride: { _ in delayed }, accessoryProviders: [provider])
        defer { stop(manager) }
        let started = await manager.start()
        XCTAssertTrue(started)
        let session = try XCTUnwrap(manager.activeSession)
        // Turned on without a refresh, so the first accessory run would be the one showing the profile starts.
        session.store.state.extensionInstances[0].isEnabled = true

        manager.hide(session.entry.id)
        manager.show(session.entry.id)
        let refreshing = await waitUntil { await delayed.hasStarted }
        XCTAssertTrue(refreshing)
        let closed = await manager.close(session.entry.id)
        XCTAssertTrue(closed)
        await delayed.release()
        // Allow the resumed refresh to return and a wrongly started accessory to run.
        try await Task.sleep(for: .milliseconds(300))
        let startedIDs = await provider.startedIDs
        XCTAssertEqual(startedIDs, [], "A closed profile must not start its accessories")
    }

    func testClosingDuringAnAccessoryRunStartsNoMoreAccessories() async throws {
        let folder = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let slowNote = Note(markdown: "Synthetic note with a slow accessory")
        let quickNote = Note(markdown: "Synthetic note with a quick accessory")
        let slow = ExtensionInstanceState(
            moduleID: "org.stow.sample", slot: .noteAccessory, noteID: slowNote.id, isEnabled: true)
        let quick = ExtensionInstanceState(
            moduleID: "org.stow.sample", slot: .noteAccessory, noteID: quickNote.id, isEnabled: true)
        try await seed(folder) { state in
            state.notes = [slowNote, quickNote]
            state.extensionInstances = [slow, quick]
        }
        let provider = RecordingAccessoryProvider(holding: slow.id)
        let manager = makeManager(folder, accessoryProviders: [provider])
        defer { stop(manager) }
        let started = await manager.start()
        XCTAssertTrue(started)
        let session = try XCTUnwrap(manager.activeSession)
        let slowStarted = await waitUntil { await provider.startedIDs == [slow.id] }
        XCTAssertTrue(slowStarted)

        // Showing the profile starts a refresh that waits on the slow accessory before the quick one.
        manager.hide(session.entry.id)
        manager.show(session.entry.id)
        let closed = await manager.close(session.entry.id)
        XCTAssertTrue(closed)
        await provider.release()
        try await Task.sleep(for: .milliseconds(300))
        let startedIDs = await provider.startedIDs
        XCTAssertEqual(startedIDs, [slow.id], "A closed profile must not start its next accessory")
    }

    func testCloseWaitsForARecoveryAlreadyRunning() async throws {
        let folder = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let stateURL = folder.appendingPathComponent("state.json")
        let damaged = Data("synthetic damaged state".utf8)
        try damaged.write(to: stateURL)
        let manager = makeManager(folder, githubOverride: { _ in CountingClient() })
        // The damaged state cannot be saved, so a close that runs before the recovery finishes asks first.
        manager.confirmClosingWithoutSaving = { _ in true }
        defer { stop(manager) }
        let started = await manager.start()
        XCTAssertTrue(started)
        let session = try XCTUnwrap(manager.activeSession)
        XCTAssertTrue(session.store.storageNeedsRecovery)

        let recovery = Task { await session.store.recoverState() }
        // Two turns of the main actor let the recovery pass its checks and start moving files.
        await Task.yield()
        await Task.yield()
        let closed = await manager.close(session.entry.id)
        XCTAssertTrue(closed)
        // The close waited for the recovery: the damaged file is kept, and fresh state was saved before the lock
        // was released.
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        let backup = try XCTUnwrap(names.first { $0.hasPrefix("state.json.backup-") })
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(backup)), damaged)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stateURL.path), "The final save ran after the recovery")
        let fresh = try await StateRepository(url: stateURL).load()
        XCTAssertTrue(fresh.notes.isEmpty)
        guard case .acquired(let lock) = StateLock.acquire(forStateAt: stateURL) else {
            return XCTFail("Closing must release the profile lock")
        }
        lock.release()
        let closedTree = try tree(folder)
        await recovery.value
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(try tree(folder), closedTree, "Nothing may change once the lock is released")
    }

    func testUnreadableStateStartsAndRecoversWithGitHubAndAccessoriesOff() async throws {
        let folder = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let stateURL = folder.appendingPathComponent("state.json")
        try Data("synthetic damaged state".utf8).write(to: stateURL)
        let client = CountingClient()
        let provider = RecordingAccessoryProvider()
        let manager = makeManager(folder, githubOverride: { _ in client }, accessoryProviders: [provider])
        defer { stop(manager) }
        let started = await manager.start()
        XCTAssertTrue(started)
        let store = try XCTUnwrap(manager.activeSession).store
        XCTAssertTrue(store.storageNeedsRecovery)
        // Nothing turns on unless the person turns it on, also when saved state cannot be read.
        XCTAssertFalse(store.state.githubEnabled)
        XCTAssertTrue(store.state.extensionInstances.allSatisfy { !$0.isEnabled })
        XCTAssertTrue(store.offersGitHubSetup, "The usual offer turns GitHub back on with one click")
        await store.refresh()

        await store.recoverState()
        XCTAssertFalse(store.storageNeedsRecovery)
        let recovered = try await StateRepository(url: stateURL).load()
        XCTAssertFalse(recovered.githubEnabled)
        XCTAssertTrue(recovered.extensionInstances.allSatisfy { !$0.isEnabled })
        await store.refresh()
        await store.refreshAccessories()
        let refreshes = await client.refreshes
        XCTAssertEqual(refreshes, 0, "GitHub stays off until the person turns it on")
        let accessories = await provider.startedIDs
        XCTAssertEqual(accessories, [])
    }

    func testRefreshFinishingAfterCloseWritesNothing() async throws {
        let folder = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        try await seed(folder) { $0.githubEnabled = true }
        let workEntry = try await addProfile("Work", in: folder)
        let delayed = DelayedClient()
        let manager = makeManager(folder, githubOverride: { $0.isDataFolder ? delayed : nil })
        defer { stop(manager) }
        let started = await manager.start()
        XCTAssertTrue(started)
        let main = try XCTUnwrap(manager.activeSession)
        let opened = await manager.open(workEntry.id)
        XCTAssertTrue(opened)
        let work = try XCTUnwrap(manager.sessions[workEntry.id])
        let workSaved = await work.store.flush()
        XCTAssertTrue(workSaved)
        let workStateURL = work.store.stateURL
        let workBefore = try Data(contentsOf: workStateURL)
        let note = try XCTUnwrap(main.store.state.notes.first)

        let refresh = Task { await main.store.refresh() }
        let refreshStarted = await waitUntil { await delayed.hasStarted }
        XCTAssertTrue(refreshStarted)
        main.store.editNote(note.id, markdown: "Last edit before the profile closed")
        let closed = await manager.close(main.entry.id)
        XCTAssertTrue(closed)
        let mainStateURL = folder.appendingPathComponent("state.json")
        let afterClose = try Data(contentsOf: mainStateURL)
        let noteFile = main.store.notesDirectory.appendingPathComponent("\(note.id.uuidString).md")
        let noteAfterClose = try Data(contentsOf: noteFile)
        XCTAssertEqual(String(decoding: noteAfterClose, as: UTF8.self), "Last edit before the profile closed")
        // The lock is free, so a write from here on would come after its release.
        guard case .acquired(let lock) = StateLock.acquire(forStateAt: mainStateURL) else {
            return XCTFail("Closing must release the profile lock")
        }
        defer { lock.release() }

        await delayed.release()
        await refresh.value
        // Allow a wrongly scheduled debounced save to run.
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(try Data(contentsOf: mainStateURL), afterClose)
        XCTAssertEqual(try Data(contentsOf: noteFile), noteAfterClose)
        XCTAssertTrue(main.store.state.pullRequests.isEmpty, "A late result must not land in the closed profile")
        XCTAssertNil(main.store.state.viewerLogin)
        // A closed profile's store never saves again, even when asked, as app activation asks every store.
        main.store.editNote(note.id, markdown: "Edit after the profile closed")
        let flushedAfterClose = await main.store.flush()
        XCTAssertFalse(flushedAfterClose)
        XCTAssertEqual(try Data(contentsOf: mainStateURL), afterClose)
        XCTAssertEqual(try Data(contentsOf: noteFile), noteAfterClose)
        XCTAssertEqual(try Data(contentsOf: workStateURL), workBefore)
        XCTAssertTrue(work.store.state.pullRequests.isEmpty, "A late result must not land in another profile")
    }

    func testExternalEditWhileHiddenIsKept() async throws {
        let folder = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        try await seed(folder)
        let manager = makeManager(folder)
        defer { stop(manager) }
        let started = await manager.start()
        XCTAssertTrue(started)
        let session = try XCTUnwrap(manager.activeSession)
        let note = try XCTUnwrap(session.store.state.notes.first)
        let file = session.store.notesDirectory.appendingPathComponent("\(note.id.uuidString).md")

        manager.hide(session.entry.id)
        let external = "# Edited in another app while the profile was hidden\n"
        try Data(external.utf8).write(to: file, options: .atomic)
        // Give the notes folder watcher time to notice while the profile is still hidden.
        try await Task.sleep(for: .milliseconds(600))
        manager.show(session.entry.id)
        let saved = await session.store.flush()
        XCTAssertTrue(saved)

        XCTAssertEqual(session.store.note(note.id)?.markdown, external)
        XCTAssertEqual(session.store.state.notes.count, 1)
        XCTAssertTrue(session.store.conflictNoteIDs.isEmpty)
        XCTAssertNil(session.store.noteFileMessage)
        let files = try FileManager.default.contentsOfDirectory(atPath: session.store.notesDirectory.path)
            .filter { $0.hasSuffix(".md") }
        XCTAssertEqual(files, ["\(note.id.uuidString).md"])
        XCTAssertEqual(try Data(contentsOf: file), Data(external.utf8))
    }

    func testArrivalProfileOpensWithGitHubAndAccessoriesOff() async throws {
        let folder = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        try await seed(folder)
        // A profile folder copied in from another Mac, which this one has not seen.
        var copied = AppState()
        copied.githubEnabled = true
        copied.ghExecutablePath = "/synthetic/elsewhere/gh"
        copied.notes = [Note(markdown: "Synthetic note from another Mac")]
        copied.extensionInstances = [
            ExtensionInstanceState(moduleID: "org.stow.sample", slot: .boardAccessory, isEnabled: true)
        ]
        let arrivalID = try await addArrival(in: folder, state: copied)
        let client = CountingClient()
        let manager = makeManager(folder, githubOverride: { _ in client })
        defer { stop(manager) }
        let started = await manager.start()
        XCTAssertTrue(started)
        XCTAssertEqual(manager.profiles.first { $0.id == arrivalID }?.isArrival, true)

        let opened = await manager.open(arrivalID)
        XCTAssertTrue(opened)
        let session = try XCTUnwrap(manager.sessions[arrivalID])
        XCTAssertFalse(session.store.state.githubEnabled)
        XCTAssertNil(session.store.state.ghExecutablePath)
        XCTAssertEqual(session.store.state.extensionInstances.count, 1)
        XCTAssertTrue(session.store.state.extensionInstances.allSatisfy { !$0.isEnabled })
        XCTAssertEqual(session.store.state.notes.map(\.markdown), ["Synthetic note from another Mac"])
        let saved = try await StateRepository(url: session.store.stateURL).load()
        XCTAssertFalse(saved.githubEnabled)
        XCTAssertNil(saved.ghExecutablePath)
        XCTAssertTrue(saved.extensionInstances.allSatisfy { !$0.isEnabled })
        let snapshot = try await ProfileCatalog(dataFolder: folder).load()
        XCTAssertTrue(snapshot.index.seenIDs.contains(arrivalID))
        XCTAssertEqual(snapshot.profiles.first { $0.id == arrivalID }?.isArrival, false)
        XCTAssertEqual(manager.profiles.first { $0.id == arrivalID }?.isArrival, false)
        let refreshes = await client.refreshes
        XCTAssertEqual(refreshes, 0)

        // Seen now, so turning GitHub on here survives closing and reopening.
        session.store.setGitHubEnabled(true)
        let closed = await manager.close(arrivalID)
        XCTAssertTrue(closed)
        let reopened = await manager.open(arrivalID)
        XCTAssertTrue(reopened)
        XCTAssertEqual(manager.sessions[arrivalID]?.store.state.githubEnabled, true)
    }

    func testArrivalStaysNewWhenItsSettingsCannotBeSaved() async throws {
        let folder = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        try await seed(folder)
        var copied = AppState()
        copied.githubEnabled = true
        copied.notes = [Note(markdown: "Synthetic note from another Mac")]
        let arrivalID = try await addArrival(in: folder, state: copied)
        let profile = folder.appendingPathComponent("profiles/\(arrivalID.uuidString)")
        let stateURL = profile.appendingPathComponent("state.json")
        let before = try Data(contentsOf: stateURL)
        // The copied folder cannot be written, so GitHub stays off in memory but on in the saved state.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: profile.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: profile.path) }
        let manager = makeManager(folder, githubOverride: { _ in CountingClient() })
        defer { stop(manager) }
        let started = await manager.start()
        XCTAssertTrue(started)

        let opened = await manager.open(arrivalID)
        XCTAssertTrue(opened)
        let session = try XCTUnwrap(manager.sessions[arrivalID])
        XCTAssertFalse(session.store.state.githubEnabled)
        XCTAssertNotNil(session.store.saveError)
        XCTAssertEqual(try Data(contentsOf: stateURL), before)
        let snapshot = try await ProfileCatalog(dataFolder: folder).load()
        XCTAssertFalse(snapshot.index.seenIDs.contains(arrivalID), "Seen before its arrival settings are saved")
        XCTAssertEqual(manager.profiles.first { $0.id == arrivalID }?.isArrival, true)
    }

    func testOpeningAProfileLockedElsewhereSaysSoAndLeavesItClosed() async throws {
        let folder = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        try await seed(folder)
        let workEntry = try await addProfile("Work", in: folder)
        let reports = Recorder()
        let manager = makeManager(folder)
        manager.reportOpenElsewhere = { reports.names.append($0.name) }
        defer { stop(manager) }
        let started = await manager.start()
        XCTAssertTrue(started)
        let main = try XCTUnwrap(manager.activeSession)
        let workState = workEntry.folder.appendingPathComponent("state.json")
        guard case .acquired(let held) = StateLock.acquire(forStateAt: workState) else {
            return XCTFail("The test could not take the profile lock")
        }
        defer { held.release() }

        let opened = await manager.open(workEntry.id)
        XCTAssertFalse(opened)
        XCTAssertNil(manager.sessions[workEntry.id])
        XCTAssertEqual(reports.names, ["Work"])
        await manager.switchTo(workEntry.id)
        XCTAssertNil(manager.sessions[workEntry.id])
        XCTAssertEqual(reports.names, ["Work", "Work"])
        // A switch that cannot open its target leaves the profile it started from as it was.
        XCTAssertFalse(main.isHidden)
        XCTAssertTrue(main.board.isVisible)
    }

    func testSwitchShowsTargetAndHidesSourceByDefault() async throws {
        let folder = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        try await seed(folder, detached: true)
        let workEntry = try await addProfile("Work", in: folder)
        let manager = makeManager(folder)
        defer { stop(manager) }
        let started = await manager.start()
        XCTAssertTrue(started)
        let main = try XCTUnwrap(manager.activeSession)
        XCTAssertTrue(main.store.state.hidesWhenSwitchingAway)
        let mainWindows = windows(of: main)
        let opened = await manager.open(workEntry.id)
        XCTAssertTrue(opened)
        let work = try XCTUnwrap(manager.sessions[workEntry.id])
        // Switching from the work profile back to the first one hides the work profile.
        await manager.switchTo(main.entry.id)
        assertForward(main, in: manager)
        XCTAssertFalse(main.isHidden)
        XCTAssertTrue(mainWindows.allSatisfy(\.isVisible))
        XCTAssertTrue(work.isHidden)
        XCTAssertFalse(work.board.isVisible)
        XCTAssertFalse(work.board.isMiniaturized)

        await manager.switchTo(workEntry.id)
        assertForward(work, in: manager)
        XCTAssertFalse(work.isHidden)
        XCTAssertTrue(main.isHidden)
        for window in mainWindows {
            XCTAssertFalse(window.isVisible, window.title)
            XCTAssertFalse(window.isMiniaturized, window.title)
        }
    }

    func testSwitchKeepsSourceWhenSettingIsOff() async throws {
        let folder = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        try await seed(folder, detached: true) { $0.hidesWhenSwitchingAway = false }
        let workEntry = try await addProfile("Work", in: folder)
        let manager = makeManager(folder)
        defer { stop(manager) }
        let started = await manager.start()
        XCTAssertTrue(started)
        let main = try XCTUnwrap(manager.activeSession)
        XCTAssertFalse(main.store.state.hidesWhenSwitchingAway)
        let mainWindows = windows(of: main)

        await manager.switchTo(workEntry.id)
        let work = try XCTUnwrap(manager.sessions[workEntry.id])
        assertForward(work, in: manager)
        XCTAssertFalse(main.isHidden)
        XCTAssertTrue(mainWindows.allSatisfy(\.isVisible))
    }

    func testSwitchOpensAClosedProfile() async throws {
        let folder = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        try await seed(folder)
        let workEntry = try await addProfile("Work", in: folder)
        let manager = makeManager(folder)
        defer { stop(manager) }
        let started = await manager.start()
        XCTAssertTrue(started)
        let main = try XCTUnwrap(manager.activeSession)
        XCTAssertNil(manager.sessions[workEntry.id])

        await manager.switchTo(workEntry.id)
        let work = try XCTUnwrap(manager.sessions[workEntry.id])
        assertForward(work, in: manager)
        XCTAssertTrue(main.isHidden)
        XCTAssertFalse(main.board.isVisible)
        XCTAssertTrue(isHeld(StateLock.acquire(forStateAt: workEntry.folder.appendingPathComponent("state.json"))))
    }

    func testRelaunchRestoresOpenAndHiddenProfiles() async throws {
        let folder = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let accessory = ExtensionInstanceState(moduleID: "org.stow.sample", slot: .boardAccessory, isEnabled: true)
        let floating = Note(markdown: "Synthetic floating note", isDetached: true, isAlwaysOnTop: true)
        let ordinary = Note(markdown: "Synthetic ordinary note", isDetached: true, isAlwaysOnTop: false)
        try await seed(folder) { state in
            state.notes = [floating, ordinary]
            state.hideKeepsAlwaysOnTopNotes = true
            state.extensionInstances = [accessory]
        }
        let workEntry = try await addProfile("Work", in: folder)
        let homeEntry = try await addProfile("Home", in: folder)
        let first = makeManager(folder)
        defer { stop(first) }
        let started = await first.start()
        XCTAssertTrue(started)
        let stowID = try XCTUnwrap(first.activeSession).entry.id
        // Home opens and closes again, then a switch to Work hides the first profile.
        let openedHome = await first.open(homeEntry.id)
        XCTAssertTrue(openedHome)
        let closedHome = await first.close(homeEntry.id)
        XCTAssertTrue(closedHome)
        await first.switchTo(workEntry.id)
        XCTAssertEqual(first.sessions[stowID]?.isHidden, true)
        XCTAssertEqual(first.lastActiveID, workEntry.id)
        await quit(first)
        let index = try await ProfileCatalog(dataFolder: folder).load().index
        XCTAssertEqual(index.open, [.init(id: stowID, isHidden: true), .init(id: workEntry.id, isHidden: false)])
        XCTAssertEqual(index.lastActiveID, workEntry.id)

        let provider = RecordingAccessoryProvider()
        let manager = makeManager(folder, accessoryProviders: [provider])
        defer { stop(manager) }
        let restarted = await manager.start()
        XCTAssertTrue(restarted)
        XCTAssertEqual(Set(manager.sessions.keys), [stowID, workEntry.id])
        let work = try XCTUnwrap(manager.sessions[workEntry.id])
        XCTAssertFalse(work.isHidden)
        assertForward(work, in: manager)
        let stow = try XCTUnwrap(manager.sessions[stowID])
        let stowWindows = windows(of: stow)
        XCTAssertEqual(stowWindows.count, 3, "The board and both detached notes")
        XCTAssertTrue(stow.isHidden)
        XCTAssertTrue(stow.store.isPaused)
        // As when it hid: the board and the ordinary note are out of sight, and the floating note it keeps stays.
        XCTAssertFalse(stow.board.isVisible)
        XCTAssertEqual(stow.noteWindows[ordinary.id]?.isVisible, false)
        let floatingWindow = try XCTUnwrap(stow.noteWindows[floating.id])
        XCTAssertTrue(floatingWindow.isVisible)
        XCTAssertEqual(floatingWindow.level, .floating)
        XCTAssertFalse(isHeld(StateLock.acquire(forStateAt: homeEntry.folder.appendingPathComponent("state.json"))))
        // Paused from the start, the hidden profile runs no accessory until it shows.
        try await Task.sleep(for: .milliseconds(300))
        let startedWhileHidden = await provider.startedIDs
        XCTAssertEqual(startedWhileHidden, [])

        manager.show(stowID)
        XCTAssertFalse(stow.isHidden)
        XCTAssertFalse(stow.store.isPaused)
        XCTAssertTrue(stowWindows.allSatisfy(\.isVisible))
        let startedOnShow = await waitUntil { await provider.startedIDs == [accessory.id] }
        XCTAssertTrue(startedOnShow)
    }

    func testLaunchWithNothingVisibleShowsLastActive() async throws {
        let folder = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        try await seed(folder)
        let workEntry = try await addProfile("Work", in: folder)
        let first = makeManager(folder)
        defer { stop(first) }
        let started = await first.start()
        XCTAssertTrue(started)
        let stowID = try XCTUnwrap(first.activeSession).entry.id
        let opened = await first.open(workEntry.id)
        XCTAssertTrue(opened)
        // Hiding both leaves nothing on screen, and Work stays the most recently active profile.
        first.hide(stowID)
        first.hide(workEntry.id)
        XCTAssertEqual(first.lastActiveID, workEntry.id)
        await quit(first)

        let manager = makeManager(folder)
        defer { stop(manager) }
        let restarted = await manager.start()
        XCTAssertTrue(restarted)
        let work = try XCTUnwrap(manager.sessions[workEntry.id])
        XCTAssertFalse(work.isHidden)
        XCTAssertFalse(work.store.isPaused)
        assertForward(work, in: manager)
        let stow = try XCTUnwrap(manager.sessions[stowID])
        XCTAssertTrue(stow.isHidden)
        XCTAssertFalse(stow.board.isVisible)
        stop(manager)

        // Without a most recently active profile the first one shows; a closed most recent one opens and shows.
        let scenarios: [(open: [ProfileIndex.OpenProfile], lastActiveID: UUID?, shown: UUID)] = [
            ([.init(id: stowID, isHidden: true), .init(id: workEntry.id, isHidden: true)], nil, stowID),
            ([.init(id: stowID, isHidden: true)], workEntry.id, workEntry.id),
        ]
        for scenario in scenarios {
            try await ProfileCatalog(dataFolder: folder).recordSession(
                open: scenario.open, lastActiveID: scenario.lastActiveID)
            let next = makeManager(folder)
            defer { stop(next) }
            let launched = await next.start()
            XCTAssertTrue(launched)
            XCTAssertEqual(Set(next.sessions.keys), [stowID, workEntry.id])
            let shown = try XCTUnwrap(next.sessions[scenario.shown])
            XCTAssertFalse(shown.isHidden)
            assertForward(shown, in: next)
            for session in next.sessions.values where session !== shown {
                XCTAssertTrue(session.isHidden, session.entry.name)
                XCTAssertFalse(session.board.isVisible, session.entry.name)
            }
        }
    }

    func testFirstLaunchAfterUpgradeOpensOnlyTheFirstProfile() async throws {
        let folder = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        // A data folder saved by a build without profiles: no index and no identity file.
        try await seed(folder)
        let manager = makeManager(folder)
        defer { stop(manager) }
        let started = await manager.start()
        XCTAssertTrue(started)
        let session = try XCTUnwrap(manager.activeSession)
        XCTAssertTrue(session.entry.isDataFolder)
        let note = try XCTUnwrap(session.store.state.notes.first)
        session.store.editNote(note.id, markdown: "Synthetic edit saved at quit")
        // Quitting saves the profile and records nothing, so the folder stays as an older build expects it.
        await quit(manager)
        let saved = try await StateRepository(url: folder.appendingPathComponent("state.json")).load()
        XCTAssertEqual(saved.notes.map(\.markdown), ["Synthetic edit saved at quit"])
        for name in [ProfileIndex.filename, ProfileIdentity.filename] {
            XCTAssertFalse(exists(name, in: folder), "\(name) must not be written")
        }

        // A profile folder copied in beside it, still without an index, stays closed.
        let copiedID = try await addArrival(in: folder, state: AppState())
        let next = makeManager(folder)
        defer { stop(next) }
        let restarted = await next.start()
        XCTAssertTrue(restarted)
        XCTAssertEqual(next.profiles.count, 2)
        XCTAssertEqual(next.sessions.count, 1)
        XCTAssertEqual(next.activeSession?.entry.isDataFolder, true)
        XCTAssertNil(next.sessions[copiedID])
        // With only the data folder profile open there is still nothing to record.
        await quit(next)
        XCTAssertFalse(exists(ProfileIndex.filename, in: folder))
    }

    func testLaunchNeverStartsAFirstProfileWhileProfileDataExists() async throws {
        let folder = try makeDirectory()
        let bin = try makeDirectory()
        let profilesFolder = folder.appendingPathComponent(ProfileCatalog.profilesDirectoryName)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: profilesFolder.path)
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: bin)
        }
        try await seed(folder)
        let workEntry = try await addProfile("Work", in: folder)
        // The first profile went to the Trash, and the other profiles' folder cannot be listed for now.
        let catalog = catalog(folder, trash: bin)
        let listed = try await catalog.load()
        let mainID = try XCTUnwrap(listed.profiles.first(where: \.isDataFolder)).id
        try await catalog.trash(mainID)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: profilesFolder.path)
        let manager = makeManager(folder)
        let reports = Recorder()
        manager.reportNoProfiles = { reports.names.append("no profiles") }
        defer { stop(manager) }

        let started = await manager.start()
        XCTAssertFalse(started)
        XCTAssertEqual(reports.names, ["no profiles"])
        XCTAssertTrue(manager.sessions.isEmpty)
        for name in ["state.json", "notes", ProfileIdentity.filename] {
            XCTAssertFalse(exists(name, in: folder), "\(name) must not be written")
        }
        XCTAssertNil(manager.prepareToQuit(), "Nothing opened, so a quit has nothing to save or record")

        // Once the folder can be read again, the next launch opens the remaining profile.
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: profilesFolder.path)
        let next = makeManager(folder)
        defer { stop(next) }
        let restarted = await next.start()
        XCTAssertTrue(restarted)
        XCTAssertEqual(Set(next.sessions.keys), [workEntry.id])
        XCTAssertFalse(exists("state.json", in: folder))
    }

    func testKeepOpenAfterPartialQuitFailureKeepsEveryProfileWritable() async throws {
        let folder = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        try await seed(folder)
        let workEntry = try await addProfile("Work", in: folder)
        let manager = makeManager(folder)
        defer { stop(manager) }
        let started = await manager.start()
        XCTAssertTrue(started)
        let main = try XCTUnwrap(manager.activeSession)
        let opened = await manager.open(workEntry.id)
        XCTAssertTrue(opened)
        let work = try XCTUnwrap(manager.sessions[workEntry.id])
        let workNote = work.store.addNote("Synthetic work note")
        let workSaved = await work.store.flush()
        XCTAssertTrue(workSaved)
        // Work's notes folder turns read-only, so its final save fails while the first profile's succeeds.
        let workNotes = work.store.notesDirectory
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: workNotes.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: workNotes.path) }
        work.store.editNote(workNote, markdown: "Synthetic work edit kept in memory")
        let mainNote = try XCTUnwrap(main.store.state.notes.first)
        main.store.editNote(mainNote.id, markdown: "Synthetic edit saved at quit")

        let results = await manager.terminationSave().value
        XCTAssertEqual(results, [main.entry.id: true, workEntry.id: false])
        let savedAtQuit = try await StateRepository(url: main.store.stateURL).load()
        XCTAssertEqual(savedAtQuit.notes.first { $0.id == mainNote.id }?.markdown, "Synthetic edit saved at quit")
        manager.cancelTermination()
        XCTAssertFalse(main.store.isTerminating)
        XCTAssertFalse(work.store.isTerminating)

        // The first profile's final save closed its repository, and it still saves afterwards.
        let added = main.store.addNote("Synthetic note written after Keep open")
        let flushed = await main.store.flush()
        XCTAssertTrue(flushed)
        let mainState = try await StateRepository(url: main.store.stateURL).load()
        XCTAssertEqual(mainState.notes.first { $0.id == added }?.markdown, "Synthetic note written after Keep open")
        // Later edits save on their own again, without a flush.
        main.store.editNote(mainNote.id, markdown: "Synthetic edit saved after a pause")
        let mainFile = main.store.notesDirectory.appendingPathComponent("\(mainNote.id.uuidString).md")
        let savedAfterPause = await waitUntil {
            (try? String(contentsOf: mainFile, encoding: .utf8)) == "Synthetic edit saved after a pause"
        }
        XCTAssertTrue(savedAfterPause)

        // Work keeps its edit in memory and saves once its folder is writable again.
        XCTAssertEqual(work.store.note(workNote)?.markdown, "Synthetic work edit kept in memory")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: workNotes.path)
        let workFlushed = await work.store.flush()
        XCTAssertTrue(workFlushed)
        let workState = try await StateRepository(url: work.store.stateURL).load()
        XCTAssertEqual(workState.notes.first { $0.id == workNote }?.markdown, "Synthetic work edit kept in memory")
    }

    func testRelaunchLeavesAProfileOpenElsewhereClosed() async throws {
        let folder = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        try await seed(folder)
        let workEntry = try await addProfile("Work", in: folder)
        let catalog = ProfileCatalog(dataFolder: folder)
        let listed = try await catalog.load().profiles
        let stowID = try XCTUnwrap(listed.first(where: \.isDataFolder)).id
        // Work was the only profile on screen at quit, and another copy of Stow holds it now.
        try await catalog.recordSession(
            open: [.init(id: stowID, isHidden: true), .init(id: workEntry.id, isHidden: false)],
            lastActiveID: workEntry.id)
        let workState = workEntry.folder.appendingPathComponent("state.json")
        guard case .acquired(let held) = StateLock.acquire(forStateAt: workState) else {
            return XCTFail("The test could not take the profile lock")
        }
        defer { held.release() }
        let reports = Recorder()
        let manager = makeManager(folder)
        manager.reportOpenElsewhere = { reports.names.append($0.name) }
        defer { stop(manager) }

        let started = await manager.start()
        XCTAssertTrue(started)
        XCTAssertNil(manager.sessions[workEntry.id])
        XCTAssertEqual(reports.names, ["Work"])
        // Nothing else would show, so the first profile shows although it was hidden.
        let stow = try XCTUnwrap(manager.sessions[stowID])
        XCTAssertFalse(stow.isHidden)
        assertForward(stow, in: manager)
    }

    func testNewNoteGoesToKeyWindowProfile() async throws {
        let folder = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        try await seed(folder)
        let workEntry = try await addProfile("Work", in: folder)
        let app = try await makeApp(folder)
        defer { stop(app) }
        let manager = try XCTUnwrap(app.manager)
        let main = try XCTUnwrap(manager.activeSession)
        let opened = await manager.open(workEntry.id)
        XCTAssertTrue(opened)
        let work = try XCTUnwrap(manager.sessions[workEntry.id])
        let mainNotes = main.store.state.notes.count
        let workNotes = work.store.state.notes.count

        app.newNote()
        XCTAssertEqual(work.store.state.notes.count, workNotes + 1)
        XCTAssertEqual(main.store.state.notes.count, mainNotes)
    }

    func testMenuTitlesNameProfileOnlyWithSeveralProfiles() async throws {
        let folder = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        try await seed(folder)
        let app = try await makeApp(folder)
        defer { stop(app) }
        let manager = try XCTUnwrap(app.manager)
        XCTAssertEqual(newNoteTitle(app), "New note")

        let workEntry = try await addProfile("Work", in: folder)
        try await manager.reloadProfiles()
        let opened = await manager.open(workEntry.id)
        XCTAssertTrue(opened)
        XCTAssertEqual(newNoteTitle(app), "New note in Work")
        XCTAssertEqual(menu("File", in: app).items.first { $0.action == #selector(AppDelegate.refresh) }?.title,
            "Refresh GitHub in Work")
    }

    func testDockMenuListsProfilesWithState() async throws {
        let folder = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        try await seed(folder)
        let single = try await makeApp(folder)
        let onlyNew = try XCTUnwrap(single.applicationDockMenu(NSApp))
        XCTAssertEqual(onlyNew.items.map(\.title), ["New profile…"])
        stop(single)

        let workEntry = try await addProfile("Work", in: folder)
        _ = try await addProfile("Play", in: folder)
        let app = try await makeApp(folder)
        defer { stop(app) }
        let manager = try XCTUnwrap(app.manager)
        let opened = await manager.open(workEntry.id)
        XCTAssertTrue(opened)
        manager.hide(workEntry.id)
        let dock = try XCTUnwrap(app.applicationDockMenu(NSApp))
        XCTAssertEqual(dock.items.map(\.title), ["Stow", "Work", "Play", "", "New profile…"])
        XCTAssertEqual(dock.items.prefix(3).map(\.state), [.on, .mixed, .off])
    }

    func testDockReopenShowsMostRecentProfile() async throws {
        let folder = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        try await seed(folder)
        let workEntry = try await addProfile("Work", in: folder)
        let app = try await makeApp(folder)
        defer { stop(app) }
        let manager = try XCTUnwrap(app.manager)
        let main = try XCTUnwrap(manager.activeSession)
        let opened = await manager.open(workEntry.id)
        XCTAssertTrue(opened)
        let work = try XCTUnwrap(manager.sessions[workEntry.id])
        manager.hide(main.entry.id)
        manager.hide(workEntry.id)
        XCTAssertTrue(work.isHidden)

        XCTAssertTrue(app.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false))
        let shown = await waitUntil { !work.isHidden }
        XCTAssertTrue(shown)
        XCTAssertTrue(main.isHidden)
        XCTAssertTrue(work.board.isVisible)

        // With every profile closed, the most recent one opens again.
        let closed = await manager.close(workEntry.id)
        XCTAssertTrue(closed)
        let closedMain = await manager.close(main.entry.id)
        XCTAssertTrue(closedMain)
        XCTAssertTrue(manager.sessions.isEmpty)
        _ = app.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
        let reopened = await waitUntil { manager.sessions[workEntry.id]?.board?.isVisible == true }
        XCTAssertTrue(reopened)
    }

    func testProfilesMenuShortcutsFollowOrder() async throws {
        let folder = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        try await seed(folder)
        let work = try await addProfile("Work", in: folder)
        _ = try await addProfile("Play", in: folder)
        let app = try await makeApp(folder)
        defer { stop(app) }
        let profiles = menu("Profiles", in: app)
        app.menuNeedsUpdate(profiles)
        let slots = profiles.items.filter { $0.representedObject is UUID }
        XCTAssertEqual(slots.map(\.title), ["Stow", "Work", "Play"])
        XCTAssertEqual(slots.map(\.keyEquivalent), ["1", "2", "3"])
        XCTAssertTrue(slots.allSatisfy { $0.keyEquivalentModifierMask == [.control, .option] })
        XCTAssertEqual(
            profiles.items.filter { $0.keyEquivalent == "]" || $0.keyEquivalent == "[" }.map(\.title),
            ["Next profile", "Previous profile"])

        try await XCTUnwrap(app.manager).move(work.id, by: 1)
        let reordered = menu("Profiles", in: app).items.filter { $0.representedObject is UUID }
        XCTAssertEqual(reordered.map(\.title), ["Stow", "Play", "Work"])
        XCTAssertEqual(reordered.map(\.keyEquivalent), ["1", "2", "3"])
        XCTAssertEqual(reordered[2].representedObject as? UUID, work.id)
    }

    func testProfilesMenuAppearsOnlyOnceNamesShow() async throws {
        let folder = try makeDirectory()
        let bin = try makeDirectory()
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: bin)
        }
        try await seed(folder)
        let app = AppDelegate()
        let prepared = await app.prepare(
            stateURL: folder.appendingPathComponent("state.json"), isDemo: false,
            catalog: catalog(folder, trash: bin))
        XCTAssertTrue(prepared)
        defer { stop(app) }
        let manager = try XCTUnwrap(app.manager)
        failOnReports(from: manager)
        let item = try XCTUnwrap(NSApp.mainMenu?.items.first { $0.title == "Profiles" })
        let profiles = try XCTUnwrap(item.submenu)

        // One profile looks as Stow did before profiles: only File and the Dock offer New profile….
        XCTAssertTrue(item.isHidden)
        XCTAssertFalse(performShortcut("1"), "A hidden menu's shortcuts do nothing")
        let fileItems = menu("File", in: app).items.filter { $0.title.contains("profile") }.map(\.title)
        XCTAssertEqual(fileItems, ["New profile…"])
        XCTAssertEqual(app.applicationDockMenu(NSApp)?.items.map(\.title), ["New profile…"])

        try await manager.setAlwaysShowProfileName(true)
        XCTAssertFalse(item.isHidden)
        app.menuNeedsUpdate(profiles)
        XCTAssertEqual(profiles.items.map(\.title), ["Stow", "", "New profile…"])
        try await manager.setAlwaysShowProfileName(false)
        XCTAssertTrue(item.isHidden)

        // A second profile shows it, and its shortcuts work.
        let work = try await manager.createProfile(name: "Work", color: "#336699")
        XCTAssertFalse(item.isHidden)
        app.menuNeedsUpdate(profiles)
        XCTAssertEqual(profiles.items.filter { $0.representedObject is UUID }.map(\.keyEquivalent), ["1", "2"])
        XCTAssertTrue(performShortcut("2"))
        let switched = await waitUntil { manager.sessions[work.id]?.isHidden == false }
        XCTAssertTrue(switched)

        // Deleting it hides the menu again.
        try await manager.delete(work.id)
        XCTAssertTrue(item.isHidden)
    }

    func testNextAndPreviousProfileWrap() async throws {
        let folder = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        try await seed(folder)
        let work = try await addProfile("Work", in: folder)
        let play = try await addProfile("Play", in: folder)
        let app = try await makeApp(folder)
        defer { stop(app) }
        let manager = try XCTUnwrap(app.manager)
        let first = try XCTUnwrap(manager.activeSession).entry.id
        let profiles = menu("Profiles", in: app)
        app.menuNeedsUpdate(profiles)
        let next = try XCTUnwrap(profiles.items.first { $0.keyEquivalent == "]" })
        let previous = try XCTUnwrap(profiles.items.first { $0.keyEquivalent == "[" })
        XCTAssertEqual(next.keyEquivalentModifierMask, [.control, .option])
        XCTAssertEqual(previous.keyEquivalentModifierMask, [.control, .option])

        // From the first, Previous wraps to the last.
        previous.target.map { _ = NSApp.sendAction(previous.action!, to: $0, from: previous) }
        let atLast = await waitUntil { manager.activeSession?.entry.id == play.id && manager.lastActiveID == play.id }
        XCTAssertTrue(atLast)
        // From the last, Next wraps to the first.
        next.target.map { _ = NSApp.sendAction(next.action!, to: $0, from: next) }
        let atFirst = await waitUntil { manager.lastActiveID == first && manager.activeSession?.entry.id == first }
        XCTAssertTrue(atFirst)
        // Next from the first goes to the second.
        next.target.map { _ = NSApp.sendAction(next.action!, to: $0, from: next) }
        let atSecond = await waitUntil { manager.lastActiveID == work.id }
        XCTAssertTrue(atSecond)
    }

    func testDockMenuSwitches() async throws {
        let folder = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        try await seed(folder)
        let workEntry = try await addProfile("Work", in: folder)
        let app = try await makeApp(folder)
        defer { stop(app) }
        let manager = try XCTUnwrap(app.manager)
        let main = try XCTUnwrap(manager.activeSession)
        let dock = try XCTUnwrap(app.applicationDockMenu(NSApp))
        dock.performActionForItem(at: 1)
        let switched = await waitUntil { manager.sessions[workEntry.id]?.isHidden == false && main.isHidden }
        XCTAssertTrue(switched)
        XCTAssertEqual(manager.lastActiveID, workEntry.id)
        XCTAssertFalse(main.board.isVisible)
    }

    // MARK: managing profiles

    func testNewProfileStartsEmptyWithGitHubOffer() async throws {
        let folder = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        try await seed(folder) { state in
            state.appearance = .paper
            state.extensionInstances = [
                ExtensionInstanceState(moduleID: "org.stow.sample", slot: .boardAccessory, isEnabled: true)
            ]
        }
        let manager = makeManager(folder)
        defer { stop(manager) }
        let started = await manager.start()
        XCTAssertTrue(started)
        let main = try XCTUnwrap(manager.activeSession)

        let entry = try await manager.createProfile(name: "  Work ", color: "#336699")
        XCTAssertEqual(entry.name, "Work")
        XCTAssertEqual(manager.profiles.map(\.name), ["Stow", "Work"])
        XCTAssertTrue(manager.showsProfileNames)
        XCTAssertTrue(main.showsName, "Names show on open profiles once a second profile exists")
        XCTAssertEqual(main.board.title, "Stow")
        let opened = await manager.open(entry.id)
        XCTAssertTrue(opened)
        let work = try XCTUnwrap(manager.sessions[entry.id])
        XCTAssertTrue(work.store.offersGitHubSetup)
        XCTAssertFalse(work.store.state.githubEnabled)
        XCTAssertTrue(work.store.state.notes.isEmpty)
        XCTAssertEqual(work.store.state.appearance, .default)
        XCTAssertTrue(work.store.state.extensionInstances.isEmpty, "Nothing is copied from another profile")
        XCTAssertEqual(work.board.title, "Work")
        XCTAssertEqual(main.store.state.notes.map(\.markdown), ["Synthetic profile note"])
        XCTAssertEqual(main.store.state.appearance, .paper)
    }

    func testNewProfileIsListedWhenTheListCannotBeReadAfterward() async throws {
        let folder = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        try await seed(folder)
        let indexURL = folder.appendingPathComponent(ProfileIndex.filename)
        // Once the create has written the index, the data folder can no longer be read, as if its permissions
        // changed right after.
        let failing = ProfileCatalog(
            dataFolder: folder, currentUserID: getuid(), trash: { _ in }, ownerOf: { _ in getuid() },
            fileExists: { url in
                if FileManager.default.fileExists(atPath: indexURL.path) { throw StateError.unreadable }
                return FileManager.default.fileExists(atPath: url.path)
            })
        let manager = makeManager(folder, catalog: failing)
        defer { stop(manager) }
        let started = await manager.start()
        XCTAssertTrue(started)
        let main = try XCTUnwrap(manager.activeSession)

        // The profile exists, so creating it succeeds and it is listed until the list can be read again.
        let entry = try await manager.createProfile(name: "Work", color: "#336699")
        XCTAssertEqual(entry.name, "Work")
        XCTAssertTrue(exists("profiles/\(entry.id.uuidString)/\(ProfileIdentity.filename)", in: folder))
        XCTAssertEqual(manager.profiles.map(\.name), ["Stow", "Work"])
        XCTAssertTrue(manager.showsProfileNames)
        XCTAssertTrue(main.showsName)
    }

    func testOpeningWhenTheFoldersCannotBeReadSaysSoInsteadOfCallingItMissing() async throws {
        let folder = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        try await seed(folder)
        let indexURL = folder.appendingPathComponent(ProfileIndex.filename)
        // Once the create has written the index, the data folder can no longer be read.
        let failing = ProfileCatalog(
            dataFolder: folder, currentUserID: getuid(), trash: { _ in }, ownerOf: { _ in getuid() },
            fileExists: { url in
                if FileManager.default.fileExists(atPath: indexURL.path) { throw StateError.unreadable }
                return FileManager.default.fileExists(atPath: url.path)
            })
        let manager = makeManager(folder, catalog: failing)
        defer { stop(manager) }
        let started = await manager.start()
        XCTAssertTrue(started)
        let entry = try await manager.createProfile(name: "Work", color: "#336699")
        let reports = Recorder()
        manager.reportUnreadable = { reports.names.append($0.name) }

        let opened = await manager.open(entry.id)

        XCTAssertFalse(opened)
        XCTAssertEqual(reports.names, ["Work"])
        XCTAssertTrue(manager.profiles.contains { $0.id == entry.id }, "A profile Stow can't look for stays listed")
    }

    func testNewProfileColorsStayDistinct() {
        let palette = ProfilePalette.colors
        XCTAssertGreaterThan(palette.count, 3)
        XCTAssertTrue(palette.allSatisfy(ProfileIdentity.isValidColor))
        XCTAssertEqual(ProfilePalette.firstUnused(among: []), palette[0])
        XCTAssertEqual(ProfilePalette.firstUnused(among: ["#8E8E93", palette[0].lowercased()]), palette[1])
        XCTAssertEqual(ProfilePalette.firstUnused(among: [palette[1]]), palette[0])

        // Each new profile's default differs from every color in use, also once the palette is used up.
        var used = ["#8E8E93"]
        for _ in 0..<40 {
            let color = ProfilePalette.firstUnused(among: used)
            XCTAssertTrue(ProfileIdentity.isValidColor(color), color)
            XCTAssertFalse(used.contains { $0.caseInsensitiveCompare(color) == .orderedSame }, color)
            used.append(color)
        }
        XCTAssertEqual(Array(used.dropFirst().prefix(palette.count)), palette)
        let afterPalette = ProfilePalette.firstUnused(among: palette)
        XCTAssertEqual(ProfilePalette.firstUnused(among: palette), afterPalette, "The choice is deterministic")
        XCTAssertNotEqual(ProfilePalette.firstUnused(among: palette + [afterPalette.lowercased()]), afterPalette)
    }

    func testNewProfileRequestShowsTheSheetInSettings() async throws {
        let folder = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        try await seed(folder)
        let app = try await makeApp(folder)
        defer { stop(app) }
        let manager = try XCTUnwrap(app.manager)
        let main = try XCTUnwrap(manager.activeSession)

        menu("File", in: app).items.first { $0.title == "New profile…" }.map { item in
            _ = NSApp.sendAction(item.action!, to: item.target, from: item)
        }
        XCTAssertEqual(manager.newProfileRequest, main.entry.id)
        let settings = try XCTUnwrap(main.settingsWindow)
        XCTAssertTrue(settings.isVisible)
        let presented = await waitUntil { settings.attachedSheet != nil }
        XCTAssertTrue(presented, "The New profile sheet opens on the profile's Settings")
        // The sheet follows the request, which is how Cancel and Create close it.
        manager.newProfileRequest = nil
        let dismissed = await waitUntil { settings.attachedSheet == nil }
        XCTAssertTrue(dismissed)
        manager.requestNewProfile(from: main.entry.id)
        let presentedAgain = await waitUntil { settings.attachedSheet != nil }
        XCTAssertTrue(presentedAgain)

        // Closing the profile drops its request, so the sheet does not come back when it reopens.
        let closed = await manager.close(main.entry.id)
        XCTAssertTrue(closed)
        XCTAssertNil(manager.newProfileRequest)
        // With every profile closed, the most recently active one opens to hold the sheet.
        manager.requestNewProfile()
        let reopened = await waitUntil {
            manager.sessions[main.entry.id]?.settingsWindow?.isVisible == true
                && manager.newProfileRequest == main.entry.id
        }
        XCTAssertTrue(reopened)
    }

    func testRenameRejectsDuplicateName() async throws {
        let folder = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        try await seed(folder, detached: true)
        let workEntry = try await addProfile("Work", in: folder)
        let app = try await makeApp(folder)
        defer { stop(app) }
        let manager = try XCTUnwrap(app.manager)
        let opened = await manager.open(workEntry.id)
        XCTAssertTrue(opened)
        let work = try XCTUnwrap(manager.sessions[workEntry.id])
        work.showSettings()
        let identityURL = workEntry.folder.appendingPathComponent(ProfileIdentity.filename)
        let identity = try Data(contentsOf: identityURL)

        for (name, expected) in [("stow", ProfileError.duplicateName), ("  ", .emptyName), ("\u{200B}", .emptyName)] {
            do {
                try await manager.rename(workEntry.id, to: name)
                XCTFail("Renaming to \(name) should fail")
            } catch {
                XCTAssertEqual(error as? ProfileError, expected, name)
            }
        }
        XCTAssertEqual(manager.profiles.map(\.name), ["Stow", "Work"])
        XCTAssertEqual(work.entry.name, "Work")
        XCTAssertEqual(work.board.title, "Work")
        XCTAssertEqual(try Data(contentsOf: identityURL), identity)

        try await manager.rename(workEntry.id, to: "Office")
        XCTAssertEqual(manager.profiles.map(\.name), ["Stow", "Office"])
        XCTAssertEqual(work.entry.name, "Office")
        XCTAssertEqual(work.board.title, "Office")
        XCTAssertEqual(work.settingsWindow?.title, "Office settings")
        let profiles = menu("Profiles", in: app)
        XCTAssertEqual(profiles.items.filter { $0.representedObject is UUID }.map(\.title), ["Stow", "Office"])
        // Changing only the case of its own name is allowed.
        try await manager.rename(workEntry.id, to: "office")
        XCTAssertEqual(manager.profiles.map(\.name), ["Stow", "office"])
    }

    func testIdentityChangesHoldTheProfileLock() async throws {
        let folder = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        try await seed(folder)
        let workEntry = try await addProfile("Work", in: folder)
        let manager = makeManager(folder)
        defer { stop(manager) }
        let started = await manager.start()
        XCTAssertTrue(started)
        let main = try XCTUnwrap(manager.activeSession)
        let identityURL = workEntry.folder.appendingPathComponent(ProfileIdentity.filename)
        let identity = try Data(contentsOf: identityURL)
        let workState = workEntry.folder.appendingPathComponent("state.json")

        // A closed profile whose lock another process holds is left alone.
        guard case .acquired(let held) = StateLock.acquire(forStateAt: workState) else {
            return XCTFail("The test could not take the profile lock")
        }
        let changes: [(String, @MainActor () async throws -> Void)] = [
            ("rename", { try await manager.rename(workEntry.id, to: "Office") }),
            ("color", { try await manager.setColor(workEntry.id, to: "#AABBCC") }),
            ("icon", { try await manager.setIcon(workEntry.id, to: .symbol("star")) }),
        ]
        for (label, change) in changes {
            do {
                try await change()
                XCTFail("\(label) should be refused while another process holds the profile")
            } catch {
                XCTAssertEqual(error as? ProfileError, .inUse, label)
            }
        }
        XCTAssertEqual(try Data(contentsOf: identityURL), identity)
        held.release()

        // Once the lock is free, the change takes the lock only while it writes.
        try await manager.rename(workEntry.id, to: "Office")
        XCTAssertEqual(manager.profiles.map(\.name), ["Stow", "Office"])
        XCTAssertFalse(isHeld(StateLock.acquire(forStateAt: workState)))
        // An open profile already holds its own lock.
        try await manager.setColor(main.entry.id, to: "#AABBCC")
        try await manager.setIcon(main.entry.id, to: .emoji("😀"))
        XCTAssertEqual(manager.profiles.first?.color, "#AABBCC")
        XCTAssertEqual(manager.profiles.first?.icon, .emoji("😀"))
        XCTAssertTrue(isHeld(StateLock.acquire(forStateAt: folder.appendingPathComponent("state.json"))))
        XCTAssertFalse(main.isStopped)
    }

    func testIdentityChangesNeverRecreateAMissingProfileFolder() async throws {
        let folder = try makeDirectory()
        let bin = try makeDirectory()
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: bin)
        }
        try await seed(folder)
        let workEntry = try await addProfile("Work", in: folder)
        let homeEntry = try await addProfile("Home", in: folder)
        let manager = makeManager(folder, catalog: catalog(folder, trash: bin))
        defer { stop(manager) }
        let started = await manager.start()
        XCTAssertTrue(started)

        // A color change queued behind a deletion, as a settling color well can be, finds the profile gone.
        let deletion = Task { try await manager.delete(workEntry.id) }
        let recolor = Task { try await manager.setColor(workEntry.id, to: "#AABBCC") }
        try await deletion.value
        do {
            try await recolor.value
            XCTFail("A change to a deleted profile must fail")
        } catch {
            XCTAssertEqual(error as? ProfileError, .notFound)
        }
        // An empty folder left in its place would make Finder's Put Back ask to replace it.
        XCTAssertFalse(exists("profiles/\(workEntry.id.uuidString)", in: folder))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: bin.path), [workEntry.id.uuidString])

        // A folder removed outside Stow is not recreated either, and the list drops the profile.
        try FileManager.default.removeItem(at: homeEntry.folder)
        XCTAssertTrue(manager.profiles.contains { $0.id == homeEntry.id }, "The list has not been read since")
        let changes: [(String, @MainActor () async throws -> Void)] = [
            ("rename", { try await manager.rename(homeEntry.id, to: "Away") }),
            ("color", { try await manager.setColor(homeEntry.id, to: "#AABBCC") }),
            ("icon", { try await manager.setIcon(homeEntry.id, to: .symbol("house")) }),
        ]
        for (label, change) in changes {
            do {
                try await change()
                XCTFail("\(label) of a missing profile must fail")
            } catch {
                XCTAssertEqual(error as? ProfileError, .notFound, label)
            }
            XCTAssertFalse(exists("profiles/\(homeEntry.id.uuidString)", in: folder), label)
            XCTAssertFalse(manager.profiles.contains { $0.id == homeEntry.id }, label)
        }
        XCTAssertEqual(manager.profiles.map(\.name), ["Stow"])
    }

    func testChoosingAProfileWhoseFolderWasRemovedNeverRecreatesIt() async throws {
        let folder = try makeDirectory()
        let bin = try makeDirectory()
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: bin)
        }
        try await seed(folder)
        let work = try await addProfile("Work", in: folder)
        let home = try await addProfile("Home", in: folder)
        let play = try await addProfile("Play", in: folder)
        let app = try await makeApp(folder)
        defer { stop(app) }
        let manager = try XCTUnwrap(app.manager)
        let main = try XCTUnwrap(manager.activeSession)
        let reports = Recorder()
        manager.reportNotFound = { reports.names.append($0.name) }
        // The menus are read while every folder is still there.
        let profiles = menu("Profiles", in: app)
        app.menuNeedsUpdate(profiles)
        let dock = try XCTUnwrap(app.applicationDockMenu(NSApp))
        var removed: [UUID: [String: Data?]] = [:]
        /// Moves a profile's folder out of the data folder, as Finder's Move to Trash does.
        func remove(_ entry: ProfileEntry) throws {
            removed[entry.id] = try tree(entry.folder)
            try FileManager.default.moveItem(at: entry.folder, to: bin.appendingPathComponent(entry.id.uuidString))
        }

        // From the Profiles menu, as its shortcut ⌃⌥2 does.
        try remove(work)
        let workItem = try XCTUnwrap(profiles.items.first { $0.title == "Work" })
        _ = NSApp.sendAction(try XCTUnwrap(workItem.action), to: workItem.target, from: workItem)
        let reportedWork = await waitUntil { reports.names == ["Work"] }
        XCTAssertTrue(reportedWork)
        // From the Dock menu.
        try remove(home)
        dock.performActionForItem(at: try XCTUnwrap(dock.items.firstIndex { $0.title == "Home" }))
        let reportedHome = await waitUntil { reports.names == ["Work", "Home"] }
        XCTAssertTrue(reportedHome)
        // The profile a switch started from stays as it was.
        XCTAssertFalse(main.isHidden)
        XCTAssertTrue(main.board.isVisible)
        // From the Dock icon, which opens the most recently active profile once every profile is closed.
        let openedPlay = await manager.open(play.id)
        XCTAssertTrue(openedPlay)
        for id in [main.entry.id, play.id] {
            let closed = await manager.close(id)
            XCTAssertTrue(closed)
        }
        XCTAssertEqual(manager.lastActiveID, play.id)
        try remove(play)
        _ = app.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
        let reportedPlay = await waitUntil { reports.names == ["Work", "Home", "Play"] }
        XCTAssertTrue(reportedPlay)

        // An empty folder in their places would make Finder's Put Back ask to replace it.
        for entry in [work, home, play] {
            XCTAssertFalse(exists("profiles/\(entry.id.uuidString)", in: folder), entry.name)
            XCTAssertNil(manager.sessions[entry.id], entry.name)
            XCTAssertEqual(try tree(bin.appendingPathComponent(entry.id.uuidString)), removed[entry.id], entry.name)
        }
        XCTAssertEqual(manager.profiles.map(\.name), ["Stow"])

        // Put Back returns a folder, and Stow lists it again when it comes forward.
        try FileManager.default.moveItem(at: bin.appendingPathComponent(work.id.uuidString), to: work.folder)
        app.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))
        let relisted = await waitUntil { manager.profiles.contains { $0.id == work.id } }
        XCTAssertTrue(relisted)
        let reopened = await manager.open(work.id)
        XCTAssertTrue(reopened)
    }

    func testOpenQueuedBehindADeleteFindsTheProfileGone() async throws {
        let folder = try makeDirectory()
        let bin = try makeDirectory()
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: bin)
        }
        try await seed(folder)
        let workEntry = try await addProfile("Work", in: folder)
        _ = try await addProfile("Home", in: folder)
        let manager = makeManager(folder, catalog: catalog(folder, trash: bin))
        defer { stop(manager) }
        let reports = Recorder()
        manager.reportNotFound = { reports.names.append($0.name) }
        let started = await manager.start()
        XCTAssertTrue(started)
        let main = try XCTUnwrap(manager.activeSession)

        // An open chosen while the deletion runs waits its turn, then finds the profile gone.
        let deletion = Task { try await manager.delete(workEntry.id) }
        let opening = Task { await manager.open(workEntry.id) }
        try await deletion.value
        let opened = await opening.value
        XCTAssertFalse(opened)
        XCTAssertNil(manager.sessions[workEntry.id])
        XCTAssertFalse(exists("profiles/\(workEntry.id.uuidString)", in: folder))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: bin.path), [workEntry.id.uuidString])
        // Said, if at all, as a profile that cannot be found, never as one open elsewhere.
        XCTAssertTrue(reports.names.allSatisfy { $0 == "Work" })

        // The same for the first profile: no new, empty "Stow" starts in the data folder under its old ID.
        let mainID = main.entry.id
        let mainDeletion = Task { try await manager.delete(mainID) }
        let mainOpening = Task { await manager.open(mainID) }
        try await mainDeletion.value
        let mainOpened = await mainOpening.value
        XCTAssertFalse(mainOpened)
        XCTAssertNil(manager.sessions[mainID])
        for name in ["state.json", "notes", ProfileIdentity.filename] {
            XCTAssertFalse(exists(name, in: folder), "\(name) must not be written")
        }
        XCTAssertEqual(
            Set(try FileManager.default.contentsOfDirectory(atPath: bin.path)),
            [workEntry.id.uuidString, mainID.uuidString])
        XCTAssertEqual(manager.profiles.map(\.name), ["Home"])
        XCTAssertTrue(reports.names.allSatisfy { $0 == "Work" || $0 == "Stow" })
    }

    func testDeleteClosesAndMovesProfileToTrash() async throws {
        let folder = try makeDirectory()
        let bin = try makeDirectory()
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: bin)
        }
        try await seed(folder)
        let workEntry = try await addProfile("Work", in: folder)
        let manager = makeManager(folder, catalog: catalog(folder, trash: bin))
        defer { stop(manager) }
        let started = await manager.start()
        XCTAssertTrue(started)
        let main = try XCTUnwrap(manager.activeSession)
        let opened = await manager.open(workEntry.id)
        XCTAssertTrue(opened)
        let work = try XCTUnwrap(manager.sessions[workEntry.id])
        let note = work.store.addNote("Synthetic note saved before the move")
        work.store.detachNote(note)
        work.showSettings()
        let workWindows = windows(of: work)
        XCTAssertEqual(workWindows.count, 3)

        try await manager.delete(workEntry.id)
        XCTAssertNil(manager.sessions[workEntry.id])
        XCTAssertTrue(work.isStopped)
        XCTAssertTrue(workWindows.allSatisfy { !$0.isVisible })
        XCTAssertFalse(exists("profiles/\(workEntry.id.uuidString)", in: folder))
        let trashed = bin.appendingPathComponent(workEntry.id.uuidString)
        let saved = try await StateRepository(url: trashed.appendingPathComponent("state.json")).load()
        XCTAssertEqual(saved.notes.map(\.markdown), ["Synthetic note saved before the move"])
        XCTAssertEqual(manager.profiles.map(\.name), ["Stow"])
        let index = try await ProfileCatalog(dataFolder: folder).load().index
        XCTAssertFalse(index.order.contains(workEntry.id))
        XCTAssertFalse(manager.showsProfileNames)
        XCTAssertFalse(main.showsName)
        XCTAssertFalse(main.isHidden)

        // The last profile cannot be deleted, and stays open.
        do {
            try await manager.delete(main.entry.id)
            XCTFail("The last profile must not be deleted")
        } catch {
            XCTAssertEqual(error as? ProfileError, .lastProfile)
        }
        XCTAssertTrue(manager.sessions[main.entry.id] === main)
        XCTAssertFalse(main.isStopped)
        XCTAssertTrue(main.board.isVisible)
        XCTAssertTrue(exists("state.json", in: folder))
    }

    func testDeleteRefusesAProfileOpenElsewhere() async throws {
        let folder = try makeDirectory()
        let bin = try makeDirectory()
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: bin)
        }
        try await seed(folder)
        let workEntry = try await addProfile("Work", in: folder)
        let manager = makeManager(folder, catalog: catalog(folder, trash: bin))
        defer { stop(manager) }
        let started = await manager.start()
        XCTAssertTrue(started)
        let workState = workEntry.folder.appendingPathComponent("state.json")
        guard case .acquired(let held) = StateLock.acquire(forStateAt: workState) else {
            return XCTFail("The test could not take the profile lock")
        }
        defer { held.release() }
        do {
            try await manager.delete(workEntry.id)
            XCTFail("A profile another process holds must not be deleted")
        } catch {
            XCTAssertEqual(error as? ProfileError, .inUse)
        }
        XCTAssertTrue(exists("profiles/\(workEntry.id.uuidString)/identity.json", in: folder))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: bin.path), [])
        XCTAssertEqual(manager.profiles.map(\.name), ["Stow", "Work"])
    }

    func testFailedDeletionIsReportedWhenTheSettingsThatAskedHaveClosed() async throws {
        let folder = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        try await seed(folder)
        let workEntry = try await addProfile("Work", in: folder)
        // The Trash refuses, so the move fails after Work has closed, and Work opens again.
        let refusing = ProfileCatalog(dataFolder: folder) { _ in throw CocoaError(.fileWriteNoPermission) }
        let manager = makeManager(folder, catalog: refusing)
        defer { stop(manager) }
        let reports = Recorder()
        manager.reportDeletionFailure = { entry, error in
            reports.names.append(entry.name)
            XCTAssertEqual(error as? ProfileError, .unwritable)
        }
        let started = await manager.start()
        XCTAssertTrue(started)
        let main = try XCTUnwrap(manager.activeSession)
        let opened = await manager.open(workEntry.id)
        XCTAssertTrue(opened)
        let work = try XCTUnwrap(manager.sessions[workEntry.id])
        work.showSettings()
        XCTAssertEqual(work.settingsWindow?.isVisible, true)

        do {
            try await manager.delete(workEntry.id, askedFrom: workEntry.id)
            XCTFail("The Trash refused the move")
        } catch {
            XCTAssertEqual(error as? ProfileError, .unwritable)
        }
        XCTAssertEqual(reports.names, ["Work"], "Work's Settings closed with it, so an alert says why")
        XCTAssertTrue(work.isStopped)
        let reopened = try XCTUnwrap(manager.sessions[workEntry.id])
        XCTAssertFalse(reopened.isStopped)
        XCTAssertTrue(exists("profiles/\(workEntry.id.uuidString)/identity.json", in: folder))

        // Settings that stay open show the reason themselves.
        main.showSettings()
        XCTAssertEqual(main.settingsWindow?.isVisible, true)
        do {
            try await manager.delete(workEntry.id, askedFrom: main.entry.id)
            XCTFail("The Trash refused the move")
        } catch {
            XCTAssertEqual(error as? ProfileError, .unwritable)
        }
        XCTAssertEqual(reports.names, ["Work"])
        XCTAssertNotNil(manager.sessions[workEntry.id])
    }

    func testNamesAppearOnlyWithTwoProfilesOrSetting() async throws {
        let folder = try makeDirectory()
        let bin = try makeDirectory()
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: bin)
        }
        try await seed(folder, detached: true)
        let manager = makeManager(folder, catalog: catalog(folder, trash: bin))
        defer { stop(manager) }
        let started = await manager.start()
        XCTAssertTrue(started)
        let main = try XCTUnwrap(manager.activeSession)
        let note = try XCTUnwrap(main.noteWindows.values.first)
        try await manager.rename(main.entry.id, to: "Home")
        try await manager.setColor(main.entry.id, to: "#FF375F")

        // One profile: the board's title is its name, but windows and colors read as before.
        XCTAssertFalse(manager.showsProfileNames)
        XCTAssertEqual(header(of: main).title, "Home")
        XCTAssertNil(header(of: main).tint)
        XCTAssertEqual(main.board.title, "Stow")
        XCTAssertEqual(note.title, "Synthetic profile note")

        try await manager.setAlwaysShowProfileName(true)
        XCTAssertTrue(manager.alwaysShowsProfileName)
        XCTAssertTrue(manager.showsProfileNames)
        XCTAssertEqual(main.board.title, "Home")
        XCTAssertEqual(note.title, "Synthetic profile note — Home")
        XCTAssertEqual(header(of: main).tint, "#FF375F")

        try await manager.setAlwaysShowProfileName(false)
        XCTAssertFalse(manager.showsProfileNames)
        XCTAssertEqual(main.board.title, "Stow")
        XCTAssertNil(header(of: main).tint)

        // A second profile shows names without the setting, and deleting it hides them again.
        let work = try await manager.createProfile(name: "Work", color: "#336699")
        XCTAssertTrue(manager.showsProfileNames)
        XCTAssertEqual(main.board.title, "Home")
        XCTAssertEqual(header(of: main).tint, "#FF375F")
        try await manager.delete(work.id)
        XCTAssertFalse(manager.showsProfileNames)
        XCTAssertEqual(main.board.title, "Stow")
    }

    func testRestoreReplacesOnlyItsProfile() async throws {
        let folder = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        try await seed(folder, detached: true)
        let workEntry = try await addProfile("Work", in: folder)
        let manager = makeManager(folder)
        defer { stop(manager) }
        let started = await manager.start()
        XCTAssertTrue(started)
        let main = try XCTUnwrap(manager.activeSession)
        let opened = await manager.open(workEntry.id)
        XCTAssertTrue(opened)
        let work = try XCTUnwrap(manager.sessions[workEntry.id])
        work.store.addNote("Synthetic note replaced by the restore")
        let mainSaved = await main.store.flush()
        let workSaved = await work.store.flush()
        XCTAssertTrue(mainSaved)
        XCTAssertTrue(workSaved)
        let workPath = "/profiles/\(workEntry.id.uuidString)"
        let outsideWork = { (tree: [String: Data?]) in tree.filter { !$0.key.hasPrefix(workPath) } }
        let before = try outsideWork(tree(folder))
        XCTAssertNotNil(before["/state.json"] ?? nil)
        XCTAssertNotNil(before["/\(ProfileIndex.filename)"] ?? nil)
        XCTAssertNotNil(before["/\(ProfileIdentity.filename)"] ?? nil)
        let workIdentityURL = workEntry.folder.appendingPathComponent(ProfileIdentity.filename)
        let workIdentity = try Data(contentsOf: workIdentityURL)
        let listed = try await ProfileCatalog(dataFolder: folder).load()

        var backup = AppState()
        backup.githubEnabled = false
        backup.notes = [Note(markdown: "Synthetic restored note")]
        let restored = await work.store.restoreBackup(backup)
        XCTAssertTrue(restored)
        XCTAssertEqual(work.store.state.notes.map(\.markdown), ["Synthetic restored note"])
        // Every file outside the restored profile, the first profile's and the index included, is unchanged.
        XCTAssertEqual(try outsideWork(tree(folder)), before)
        XCTAssertEqual(main.store.state.notes.map(\.markdown), ["Synthetic profile note"])
        // The restored profile keeps its own identity, and the list read afresh is as it was.
        XCTAssertEqual(try Data(contentsOf: workIdentityURL), workIdentity)
        let relisted = try await ProfileCatalog(dataFolder: folder).load()
        XCTAssertEqual(relisted.profiles, listed.profiles)
        XCTAssertEqual(relisted.index, listed.index)
        XCTAssertEqual(relisted.profiles.map(\.name), ["Stow", "Work"])
    }

    func testBoardHeaderShowsIconWhenSet() async throws {
        let folder = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        try await seed(folder)
        let manager = makeManager(folder)
        defer { stop(manager) }
        let started = await manager.start()
        XCTAssertTrue(started)
        let main = try XCTUnwrap(manager.activeSession)
        let button = try await switcher(in: main)
        XCTAssertEqual(button.accessibilityLabel(), "Stow")
        XCTAssertEqual(button.accessibilityIdentifier(), "board.profileMenu")
        XCTAssertNil(header(of: main).icon, "Without an icon the header keeps the tray")

        let icons: [(set: ProfileIcon?, shown: ProfileIcon?)] = [
            (.symbol("star.fill"), .symbol("star.fill")), (.emoji("😀"), .emoji("😀")),
            // A symbol this Mac does not have shows as no icon, so the tray stays.
            (.symbol("stow.synthetic.missing"), nil), (nil, nil),
        ]
        for (icon, shown) in icons {
            try await manager.setIcon(main.entry.id, to: icon)
            XCTAssertEqual(manager.profiles.first?.icon, icon)
            XCTAssertEqual(header(of: main).icon, shown, "\(String(describing: icon))")
            // The menu button stays over the icon and keeps the profile's name.
            let current = try await switcher(in: main)
            XCTAssertEqual(current.accessibilityLabel(), "Stow")
        }
    }

    func testHeaderTitleIsProfileName() async throws {
        let folder = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        try await seed(folder)
        let manager = makeManager(folder)
        defer { stop(manager) }
        let started = await manager.start()
        XCTAssertTrue(started)
        let main = try XCTUnwrap(manager.activeSession)
        let button = try await switcher(in: main)
        XCTAssertEqual(header(of: main).title, "Stow")
        XCTAssertEqual(header(of: main).name, "Stow")

        try await manager.rename(main.entry.id, to: "Home")
        XCTAssertEqual(header(of: main).title, "Home")
        let relabeled = await waitUntil {
            main.board.contentView?.layoutSubtreeIfNeeded()
            return button.accessibilityLabel() == "Home"
        }
        XCTAssertTrue(relabeled)
    }

    func testHidingTitleKeepsIconSwitcher() async throws {
        let folder = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        try await seed(folder)
        let manager = makeManager(folder)
        defer { stop(manager) }
        let started = await manager.start()
        XCTAssertTrue(started)
        let main = try XCTUnwrap(manager.activeSession)
        main.store.setShowsBoardTitle(false)
        XCTAssertNil(header(of: main).title)
        XCTAssertEqual(header(of: main).name, "Stow")
        let button = try await switcher(in: main)
        XCTAssertEqual(button.accessibilityLabel(), "Stow")
        XCTAssertEqual(menuTitles(button), ["New profile…", "Profile settings…"])

        _ = try await manager.createProfile(name: "Work", color: "#336699")
        XCTAssertNil(header(of: main).title)
        XCTAssertEqual(
            menuTitles(button), ["Work", "", "Hide profile", "Close profile", "", "New profile…", "Profile settings…"])
        perform("Profile settings…", in: button)
        XCTAssertEqual(main.settingsWindow?.isVisible, true)
    }

    func testHeaderMenuSwitchesHidesAndCloses() async throws {
        let folder = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        try await seed(folder)
        let workEntry = try await addProfile("Work", in: folder)
        let playEntry = try await addProfile("Play", in: folder)
        let manager = makeManager(folder)
        defer { stop(manager) }
        let started = await manager.start()
        XCTAssertTrue(started)
        let main = try XCTUnwrap(manager.activeSession)
        let mainButton = try await switcher(in: main)
        XCTAssertEqual(menuTitles(mainButton).prefix(2), ["Work", "Play"])
        XCTAssertEqual(mainButton.menu?.items.dropFirst().prefix(2).map(\.state), [.off, .off])

        perform("Work", in: mainButton)
        let switched = await waitUntil { manager.sessions[workEntry.id]?.isHidden == false && main.isHidden }
        XCTAssertTrue(switched)
        let work = try XCTUnwrap(manager.sessions[workEntry.id])
        let workButton = try await switcher(in: work)
        XCTAssertEqual(menuTitles(workButton).prefix(2), ["Stow", "Play"])
        XCTAssertEqual(workButton.menu?.items.dropFirst().prefix(2).map(\.state), [.mixed, .off])

        perform("Hide profile", in: workButton)
        XCTAssertTrue(work.isHidden)
        XCTAssertFalse(work.board.isVisible)
        perform("Close profile", in: workButton)
        let closed = await waitUntil { manager.sessions[workEntry.id] == nil }
        XCTAssertTrue(closed)
        XCTAssertTrue(work.isStopped)
        XCTAssertNil(manager.sessions[playEntry.id])
    }

    func testResetProfileListIsOfferedOnlyWhileNeeded() async throws {
        let folder = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        try await seed(folder)
        let workEntry = try await addProfile("Work", in: folder)
        let corrupt = Data("not json".utf8)
        try corrupt.write(to: folder.appendingPathComponent(ProfileIndex.filename))
        let manager = makeManager(folder)
        defer { stop(manager) }
        let started = await manager.start()
        XCTAssertTrue(started)
        XCTAssertTrue(manager.indexNeedsReset)
        do {
            try await manager.rename(workEntry.id, to: "Office")
            XCTFail("Changes wait for the reset")
        } catch {
            XCTAssertEqual(error as? ProfileError, .indexNeedsReset)
        }

        let backup = try await manager.resetIndex()
        XCTAssertFalse(manager.indexNeedsReset)
        XCTAssertEqual(try Data(contentsOf: backup), corrupt)
        try await manager.rename(workEntry.id, to: "Office")
        XCTAssertEqual(manager.profiles.map(\.name), ["Stow", "Office"])
    }

    func testQuitRecordsProfilesClosedSinceLastRecord() async throws {
        let folder = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        try await seed(folder)
        let workEntry = try await addProfile("Work", in: folder)
        let manager = makeManager(folder)
        defer { stop(manager) }
        let started = await manager.start()
        XCTAssertTrue(started)
        let main = try XCTUnwrap(manager.activeSession)
        let opened = await manager.open(workEntry.id)
        XCTAssertTrue(opened)
        await manager.recordSession().value
        let recorded = try await ProfileCatalog(dataFolder: folder).load().index.open
        XCTAssertEqual(recorded.count, 2)

        // Closing every profile leaves nothing to save, but the quit still records that nothing is open.
        // Work closes last: on an active test host, closing Work first would make Stow's board key and last active.
        for id in [main.entry.id, workEntry.id] {
            let closed = await manager.close(id)
            XCTAssertTrue(closed)
        }
        let quitting = try XCTUnwrap(manager.prepareToQuit())
        let results = await quitting.value
        XCTAssertTrue(results.isEmpty)
        let index = try await ProfileCatalog(dataFolder: folder).load().index
        XCTAssertEqual(index.open, [])
        XCTAssertEqual(index.lastActiveID, workEntry.id)

        // The next launch shows only the most recently active profile.
        let next = makeManager(folder)
        defer { stop(next) }
        let restarted = await next.start()
        XCTAssertTrue(restarted)
        XCTAssertEqual(Set(next.sessions.keys), [workEntry.id])

        // A launch that opened nothing records nothing at quit.
        stop(next)
        guard case .acquired(let held) = StateLock.acquire(forStateAt: folder.appendingPathComponent("state.json"))
        else { return XCTFail("The test could not take the profile lock") }
        defer { held.release() }
        let blocked = makeManager(folder)
        blocked.reportOpenElsewhere = { _ in }
        try await ProfileCatalog(dataFolder: folder).recordSession(open: [], lastActiveID: main.entry.id)
        let blockedStart = await blocked.start()
        XCTAssertFalse(blockedStart)
        XCTAssertNil(blocked.prepareToQuit())
    }

    // MARK: helpers

    private func makeApp(_ folder: URL) async throws -> AppDelegate {
        let app = AppDelegate()
        let started = await app.prepare(stateURL: folder.appendingPathComponent("state.json"), isDemo: false)
        XCTAssertTrue(started)
        let manager = try XCTUnwrap(app.manager)
        manager.confirmClosingWithoutSaving = { _ in false }
        failOnReports(from: manager)
        return app
    }

    /// Fails the test on any report the test does not expect, instead of opening a modal alert.
    private func failOnReports(from manager: ProfileManager) {
        manager.reportOpenElsewhere = { entry in XCTFail("Unexpected report that \(entry.name) is open elsewhere") }
        manager.reportNotFound = { entry in XCTFail("Unexpected report that \(entry.name) cannot be found") }
        manager.reportUnreadable = { entry in XCTFail("Unexpected report that \(entry.name)'s folder can't be read") }
        manager.reportNoProfiles = { XCTFail("Unexpected report that no profile can be found") }
        manager.reportDeletionFailure = { entry, error in
            XCTFail("Unexpected report that \(entry.name) could not be deleted: \(error)")
        }
    }

    private func stop(_ app: AppDelegate) {
        if let manager = app.manager { stop(manager) }
    }

    private func menu(_ title: String, in app: AppDelegate) -> NSMenu {
        let menu = NSApp.mainMenu?.items.first { $0.title == title }?.submenu
        return menu ?? NSMenu()
    }

    /// Presses ⌃⌥ and `key` in the menu bar, as the keyboard does while Stow is active, and says whether a menu
    /// item took it.
    private func performShortcut(_ key: String) -> Bool {
        let keyCodes: [String: UInt16] = ["1": 18, "2": 19]
        guard
            let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.control, .option], timestamp: 0, windowNumber: 0,
                context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false,
                keyCode: keyCodes[key] ?? 0)
        else { return false }
        return NSApp.mainMenu?.performKeyEquivalent(with: event) ?? false
    }

    private func newNoteTitle(_ app: AppDelegate) -> String? {
        let file = menu("File", in: app)
        app.menuNeedsUpdate(file)
        return file.items.first { $0.action == #selector(AppDelegate.newNote) }?.title
    }

    /// A manager whose questions fail the test instead of opening a modal alert.
    private func makeManager(
        _ folder: URL, catalog: ProfileCatalog? = nil,
        githubOverride: @escaping @MainActor (ProfileEntry) -> (any GitHubClient)? = { _ in nil },
        accessoryProviders: [any AccessoryProvider] = [SyntheticAccessoryProvider()]
    ) -> ProfileManager {
        let manager = ProfileManager(
            dataFolder: folder, isDemo: false, catalog: catalog, githubOverride: githubOverride,
            accessoryProviders: accessoryProviders)
        manager.confirmClosingWithoutSaving = { entry in
            XCTFail("Unexpected question about closing \(entry.name) without saving")
            return false
        }
        failOnReports(from: manager)
        return manager
    }

    /// The profile's board is visible and key, and menus act on the profile. AppKit gives an app no key window
    /// while it is inactive, and macOS does not activate a test host while another app is frontmost, so key status
    /// is checked whenever the host is active.
    private func assertForward(
        _ session: ProfileSession, in manager: ProfileManager, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertTrue(session.board.isVisible, file: file, line: line)
        XCTAssertEqual(manager.lastActiveID, session.entry.id, file: file, line: line)
        XCTAssertTrue(manager.activeSession === session, file: file, line: line)
        if NSApp.isActive { XCTAssertTrue(session.board.isKeyWindow, file: file, line: line) }
    }

    /// Closes each session's windows and releases its lock.
    private func stop(_ manager: ProfileManager) {
        for session in manager.sessions.values { session.stop() }
    }

    /// Quits as the app does: records the open profiles, saves each one for the last time, then releases the locks.
    private func quit(_ manager: ProfileManager, file: StaticString = #filePath, line: UInt = #line) async {
        await manager.recordSession().value
        let results = await manager.terminationSave().value
        XCTAssertEqual(Set(results.keys), Set(manager.sessions.keys), file: file, line: line)
        XCTAssertTrue(results.values.allSatisfy { $0 }, "Every profile saves at quit", file: file, line: line)
        stop(manager)
    }

    /// The board, then detached notes in a stable order, then Settings when it exists.
    private func windows(of session: ProfileSession) -> [NSWindow] {
        var windows: [NSWindow] = [session.board]
        windows += session.noteWindows.sorted { $0.key.uuidString < $1.key.uuidString }.map { $0.value as NSWindow }
        if let settings = session.settingsWindow { windows.append(settings) }
        return windows
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "StowProfileTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func seed(
        _ folder: URL, detached: Bool = false, _ configure: (inout AppState) -> Void = { _ in }
    ) async throws {
        var state = AppState()
        state.githubEnabled = false
        state.notes = [Note(markdown: "Synthetic profile note", isDetached: detached)]
        configure(&state)
        try await StateRepository(url: folder.appendingPathComponent("state.json")).save(state)
    }

    private func addProfile(_ name: String, in folder: URL) async throws -> ProfileEntry {
        try await ProfileCatalog(dataFolder: folder).createProfile(name: name, color: "#336699")
    }

    /// A catalog whose Trash is `bin`, so tests never touch the user's Trash.
    private func catalog(_ folder: URL, trash bin: URL) -> ProfileCatalog {
        ProfileCatalog(dataFolder: folder) { url in
            try FileManager.default.moveItem(at: url, to: bin.appendingPathComponent(url.lastPathComponent))
        }
    }

    /// What the profile's board header shows, from the same state the board renders.
    private func header(of session: ProfileSession) -> BoardHeader {
        BoardHeader(profile: session.profile, layout: session.store.state.boardLayout)
    }

    /// The board header's profile menu button, once SwiftUI has laid out the board.
    private func switcher(
        in session: ProfileSession, file: StaticString = #filePath, line: UInt = #line
    ) async throws -> ProfileSwitcherButton {
        var found: ProfileSwitcherButton?
        _ = await waitUntil {
            session.board.contentView?.layoutSubtreeIfNeeded()
            found = self.subviews(of: ProfileSwitcherButton.self, in: session.board.contentView).first
            return found != nil
        }
        return try XCTUnwrap(found, "The board header has no profile menu button", file: file, line: line)
    }

    private func subviews<View: NSView>(of type: View.Type, in root: NSView?) -> [View] {
        guard let root else { return [] }
        return ((root as? View).map { [$0] } ?? []) + root.subviews.flatMap { subviews(of: type, in: $0) }
    }

    /// The profile menu's items as it opens, after the button's own face item; separators read "".
    private func menuTitles(_ button: NSPopUpButton) -> [String] {
        guard let menu = button.menu else { return [] }
        menu.delegate?.menuNeedsUpdate?(menu)
        return menu.items.dropFirst().map(\.title)
    }

    private func perform(
        _ title: String, in button: NSPopUpButton, file: StaticString = #filePath, line: UInt = #line
    ) {
        guard let menu = button.menu else { return XCTFail("The button has no menu", file: file, line: line) }
        menu.delegate?.menuNeedsUpdate?(menu)
        guard let index = menu.items.firstIndex(where: { $0.title == title }) else {
            return XCTFail("The menu has no item \(title)", file: file, line: line)
        }
        menu.performActionForItem(at: index)
    }

    /// Writes a profile folder with its identity and state but no index entry, as if copied from another Mac.
    private func addArrival(in folder: URL, state: AppState) async throws -> UUID {
        let id = UUID()
        let profile = folder.appendingPathComponent("profiles/\(id.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        try JSONEncoder().encode(ProfileIdentity(id: id, name: "Arrival", color: "#336699"))
            .write(to: profile.appendingPathComponent(ProfileIdentity.filename))
        try await StateRepository(url: profile.appendingPathComponent("state.json")).save(state)
        return id
    }

    /// Every file under `folder` by relative path, with its bytes; folders map to no bytes.
    private func tree(_ folder: URL) throws -> [String: Data?] {
        var result: [String: Data?] = [:]
        let root = folder.standardizedFileURL.path
        let items = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isDirectoryKey])
        while let item = items?.nextObject() as? URL {
            let path = String(item.standardizedFileURL.path.dropFirst(root.count))
            let isDirectory = try item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
            result[path] = isDirectory ? .some(nil) : try Data(contentsOf: item)
        }
        return result
    }

    private func exists(_ name: String, in folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path)
    }

    /// A second lock on the same file is refused even within one process, so a lock held here reads as held.
    private func isHeld(_ outcome: StateLock.Outcome) -> Bool {
        switch outcome {
        case .heldByAnotherProcess: return true
        case .acquired(let lock):
            lock.release()
            return false
        case .unavailable: return false
        }
    }

    private func waitUntil(_ predicate: @MainActor () async -> Bool) async -> Bool {
        for _ in 0..<100 {
            if await predicate() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await predicate()
    }
}

/// Records which profiles the manager asked or told about, and answers from a script.
@MainActor
private final class Recorder {
    var names: [String] = []
    private var answers: [Bool]

    init(answers: [Bool] = []) { self.answers = answers }

    func answer(_ entry: ProfileEntry) -> Bool {
        names.append(entry.name)
        return answers.isEmpty ? false : answers.removeFirst()
    }
}

/// Records which accessories start. The one it holds waits until released or cancelled.
private actor RecordingAccessoryProvider: AccessoryProvider {
    nonisolated let descriptor = AccessoryDescriptor(
        id: "org.stow.sample", name: "Synthetic recording provider", supportedSlots: [.boardAccessory, .noteAccessory])
    private(set) var startedIDs: [UUID] = []
    private let holdingID: UUID?
    private var isReleased = false

    init(holding id: UUID? = nil) { holdingID = id }

    func release() { isReleased = true }

    func snapshot(for request: AccessoryRequest) async throws -> AccessorySnapshot {
        startedIDs.append(request.instanceID)
        if request.instanceID == holdingID {
            while !isReleased { try await Task.sleep(for: .milliseconds(10)) }
        }
        return .init(primaryText: "Synthetic accessory result")
    }
}

/// Counts refreshes and answers at once with no pull requests.
private actor CountingClient: GitHubClient {
    private(set) var refreshes = 0

    func refresh(pins: [PullRequestReference], previous: [PullRequestSnapshot], expectedViewerLogin: String?)
        async throws -> GitHubRefreshResult
    {
        refreshes += 1
        return .init(viewerLogin: "synthetic-viewer", snapshots: [])
    }

    func details(for reference: PullRequestReference) async throws -> PullRequestDetails {
        throw GitHubError.requestFailed
    }
}

/// Holds its refresh until released, ignoring cancellation, like a `gh` process that answers after its profile closed.
private actor DelayedClient: GitHubClient {
    private(set) var hasStarted = false
    private var isReleased = false
    private var waiter: CheckedContinuation<Void, Never>?

    func release() {
        isReleased = true
        waiter?.resume()
        waiter = nil
    }

    func refresh(pins: [PullRequestReference], previous: [PullRequestSnapshot], expectedViewerLogin: String?)
        async throws -> GitHubRefreshResult
    {
        hasStarted = true
        if !isReleased { await withCheckedContinuation { waiter = $0 } }
        let reference = PullRequestReference(owner: "example", repository: "synthetic", number: 7)
        return .init(
            viewerLogin: "synthetic-late-viewer",
            snapshots: [.init(reference: reference, title: "Synthetic card that arrived too late")])
    }

    func details(for reference: PullRequestReference) async throws -> PullRequestDetails {
        throw GitHubError.requestFailed
    }
}

/// Answers as a settable login. Like `GHClient`, it throws on a login other than the expected one unless told not to.
private actor MismatchClient: GitHubClient {
    private var login = "old-account"
    private var throwsOnMismatch = true
    private let reference: PullRequestReference
    private(set) var refreshes = 0
    private(set) var detailRequests = 0

    init(reference: PullRequestReference) { self.reference = reference }

    func set(login: String, throwing: Bool = true) {
        self.login = login
        throwsOnMismatch = throwing
    }

    func refresh(pins: [PullRequestReference], previous: [PullRequestSnapshot], expectedViewerLogin: String?)
        async throws -> GitHubRefreshResult
    {
        refreshes += 1
        if throwsOnMismatch, let expectedViewerLogin, expectedViewerLogin.caseInsensitiveCompare(login) != .orderedSame {
            throw GitHubError.accountMismatch(actualLogin: login)
        }
        let title = login.lowercased() == "old-account" ? "Synthetic card of the old account" : "Synthetic card of the other account"
        return .init(viewerLogin: login, snapshots: [.init(reference: reference, title: title)])
    }

    func details(for reference: PullRequestReference) async throws -> PullRequestDetails {
        detailRequests += 1
        return .init(latestComment: "Synthetic comment")
    }
}

/// Answers as "other-account". Told to, it holds the next refresh that expects another login until released, then
/// throws the mismatch, like a `gh` that answers slowly.
private actor SlowMismatchClient: GitHubClient {
    private let reference: PullRequestReference
    private var holdsNext = false
    private var waiter: CheckedContinuation<Void, Never>?
    private(set) var refreshes = 0
    private(set) var isHolding = false

    init(reference: PullRequestReference) { self.reference = reference }

    func holdNextMismatch() { holdsNext = true }

    func release() {
        waiter?.resume()
        waiter = nil
    }

    func refresh(pins: [PullRequestReference], previous: [PullRequestSnapshot], expectedViewerLogin: String?)
        async throws -> GitHubRefreshResult
    {
        refreshes += 1
        let login = "other-account"
        if let expectedViewerLogin, expectedViewerLogin.caseInsensitiveCompare(login) != .orderedSame {
            if holdsNext {
                holdsNext = false
                isHolding = true
                await withCheckedContinuation { waiter = $0 }
                isHolding = false
            }
            throw GitHubError.accountMismatch(actualLogin: login)
        }
        return .init(
            viewerLogin: login, snapshots: [.init(reference: reference, title: "Synthetic card of the other account")])
    }

    func details(for reference: PullRequestReference) async throws -> PullRequestDetails {
        throw GitHubError.requestFailed
    }
}

/// Answers every request with HTTP 429, and counts them.
private final class RateLimitedTransport: GraphQLTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var calls: Int { lock.withLock { count } }

    func execute(query: String, variables: [String: GraphQLValue]) async throws -> GraphQLResponse {
        lock.withLock { count += 1 }
        return GraphQLResponse(body: Data("{}".utf8), statusCode: 429, headers: ["retry-after": "300"])
    }
}
