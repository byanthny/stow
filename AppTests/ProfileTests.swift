import AppKit
import Foundation
import StowCore
import StowExtensionSDK
import StowGitHub
import XCTest

@testable import Stow

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
        XCTAssertEqual(noteWindow.title, "Stow note")

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
        XCTAssertEqual(work.noteWindows[workNote]?.title, "Work note")
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
        let opened = await manager.open(workEntry.id)
        XCTAssertTrue(opened)
        let workNote = try XCTUnwrap(manager.sessions[workEntry.id]).store.addNote("Synthetic work note")
        manager.sessions[workEntry.id]?.store.detachNote(workNote)

        enum Operation { case open, hide, show, close }
        let script: [(Operation, UUID)] = [
            (.hide, mainID), (.close, workEntry.id), (.open, workEntry.id), (.show, mainID),
            (.close, mainID), (.hide, workEntry.id), (.open, mainID), (.close, workEntry.id),
            (.show, workEntry.id), (.hide, mainID), (.close, mainID), (.open, workEntry.id),
            (.open, mainID), (.hide, workEntry.id), (.close, workEntry.id), (.show, mainID),
            (.open, workEntry.id), (.close, mainID), (.hide, workEntry.id), (.open, mainID),
        ]
        XCTAssertEqual(script.count, 20)
        var pending: [Task<Void, Never>] = []
        for (operation, id) in script {
            switch operation {
            case .open: pending.append(Task { await manager.open(id) })
            case .close: pending.append(Task { _ = await manager.close(id) })
            case .hide: manager.hide(id)
            case .show: manager.show(id)
            }
        }
        for task in pending { await task.value }

        for id in [mainID, workEntry.id] {
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
        // Requests for one profile apply in the order they were made, and each profile's last request was an open.
        for id in [mainID, workEntry.id] {
            XCTAssertNotNil(manager.sessions[id])
            XCTAssertEqual(manager.sessions[id]?.isHidden, false)
        }

        // The manager still opens and closes normally afterwards, and no note was lost.
        let reopened = await manager.open(mainID)
        XCTAssertTrue(reopened)
        let closed = await manager.close(workEntry.id)
        XCTAssertTrue(closed)
        let main = try XCTUnwrap(manager.sessions[mainID])
        XCTAssertTrue(main.board.isVisible)
        XCTAssertFalse(main.isHidden)
        XCTAssertNil(manager.sessions[workEntry.id])
        let workState = try await StateRepository(url: workEntry.folder.appendingPathComponent("state.json")).load()
        XCTAssertEqual(workState.notes.first { $0.id == workNote }?.markdown, "Synthetic work note")
        XCTAssertEqual(main.store.state.notes.count, 1)
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

    // MARK: helpers

    /// A manager whose questions fail the test instead of opening a modal alert.
    private func makeManager(
        _ folder: URL, githubOverride: @escaping @MainActor (ProfileEntry) -> (any GitHubClient)? = { _ in nil }
    ) -> ProfileManager {
        let manager = ProfileManager(dataFolder: folder, isDemo: false, githubOverride: githubOverride)
        manager.confirmClosingWithoutSaving = { entry in
            XCTFail("Unexpected question about closing \(entry.name) without saving")
            return false
        }
        manager.reportOpenElsewhere = { entry in XCTFail("Unexpected report that \(entry.name) is open elsewhere") }
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
