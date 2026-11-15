import AppKit
import Foundation
import Observation
import StowCore
import StowGitHub
import SwiftUI
import XCTest

@testable import Stow

/// Which views a change to one note, a window frame, or GitHub data invalidates, and the saved value of a script.
@MainActor
final class NoteModelTests: XCTestCase {
    func testTypingNotifiesOnlyTheViewsOfThatNote() throws {
        let store = AppStore(stateURL: try makeDirectory().appendingPathComponent("state.json"))
        let reference = PullRequestReference(owner: "example", repository: "synthetic", number: 3)
        let linked = try model(store, store.addNote("# Linked\n\nUntouched.", reference: reference))
        let folded = try model(store, store.addNote("# Folded"))
        let launcher = try model(store, store.addNote("# Detached"))
        store.detachNote(launcher.id)
        let typed = try model(store, store.addNote("# Typed\n\nFirst text."))
        let card = PullRequestSnapshot(reference: reference, title: "Synthetic card")
        store.base.pullRequests = [card]
        let board = BoardView(store: store, profile: ProfileHandle(id: UUID()), showSettings: {})

        func typingNotifies(_ reads: () -> Void) -> Bool {
            let flag = Flag()
            withObservationTracking(reads) { flag.raise() }
            store.editNote(typed.id, markdown: typed.markdown + " More")
            return flag.isRaised
        }
        // Calling `body` records only the body's own reads, not child views' or lazily called closures'.
        XCTAssertTrue(typingNotifies { _ = NoteView(store: store, note: typed).body })
        XCTAssertTrue(typingNotifies { _ = CollapsedNoteRow(store: store, note: typed).body })
        XCTAssertFalse(typingNotifies { _ = NoteView(store: store, note: linked).body }, "Another note's view")
        XCTAssertFalse(typingNotifies { _ = CollapsedNoteRow(store: store, note: folded).body }, "A folded note")
        XCTAssertFalse(typingNotifies { _ = DetachedNoteLauncher(note: launcher) {}.body }, "A detached note's row")
        let linkedCard = PRCard(
            store: store, pr: card, isPinned: false, isExpanded: true, isLoading: false, notes: [linked])
        XCTAssertFalse(typingNotifies { _ = linkedCard.body }, "A card listing another note")
        XCTAssertFalse(typingNotifies { _ = board.body }, "The board")
        XCTAssertFalse(typingNotifies { _ = board.notesSection }, "The board's note list")
        XCTAssertFalse(typingNotifies { _ = NotesHeading(store: store) }, "The Notes header")
        store.toggleSection(BoardLayout.Section.notes.rawValue)
        XCTAssertFalse(typingNotifies { _ = board.notesSection }, "The collapsed Notes section")
    }

    func testMovingANoteWindowOrTheBoardNotifiesNothing() async throws {
        let directory = try makeDirectory()
        let url = directory.appendingPathComponent("state.json")
        var initial = AppState()
        initial.githubEnabled = false
        initial.notes = [Note(markdown: "# Detached"), Note(markdown: "# On the board")]
        try await StateRepository(url: url).save(initial)
        let app = AppDelegate()
        await app.prepare(stateURL: url, isDemo: true)
        defer { for session in app.manager?.sessions.values.map({ $0 }) ?? [] { session.stop() } }
        let store = try XCTUnwrap(app.store)
        let moved = try XCTUnwrap(store.notes.first)
        store.detachNote(moved.id)
        let still = try XCTUnwrap(store.notes.last)
        let panel = try XCTUnwrap(app.noteWindows[moved.id])
        let board = BoardView(store: store, profile: ProfileHandle(id: UUID()), showSettings: {})
        _ = await store.flush()

        let flag = Flag()
        withObservationTracking {
            _ = store.snapshot()
            _ = NoteView(store: store, note: moved, detached: true).body
            _ = NoteView(store: store, note: still).body
            _ = board.body
            _ = board.notesSection
        } onChange: {
            flag.raise()
        }
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let noteFrame = NSRect(x: screen.minX + 30, y: screen.minY + 40, width: 300, height: 320)
        let boardFrame = NSRect(x: screen.minX + 60, y: screen.minY + 50, width: 380, height: 600)
        panel.setFrame(noteFrame, display: true)
        app.board.setFrame(boardFrame, display: true)
        app.windowDidMove(Notification(name: NSWindow.didMoveNotification, object: panel))
        app.windowDidMove(Notification(name: NSWindow.didMoveNotification, object: app.board))
        let saved = await store.flush()
        XCTAssertTrue(saved)
        XCTAssertFalse(flag.isRaised, "Moving windows and saving their frames redrew a view")
        let savedNoteFrame = try XCTUnwrap(store.snapshot().notes.first { $0.id == moved.id }?.frame)
        XCTAssertEqual(savedNoteFrame.x, Double(panel.frame.minX))
        XCTAssertEqual(savedNoteFrame.width, Double(panel.frame.width))
        XCTAssertEqual(store.snapshot().boardFrame?.y, Double(app.board.frame.minY))
    }

    func testAGitHubRefreshNotifiesNoNoteView() async throws {
        let url = try makeDirectory().appendingPathComponent("state.json")
        let reference = PullRequestReference(owner: "example", repository: "synthetic", number: 5)
        var initial = AppState()
        initial.githubEnabled = true
        initial.notes = [
            Note(markdown: "# Linked", pullRequest: reference),
            Note(markdown: "# Standalone"),
            Note(markdown: "# Detached", isDetached: true),
        ]
        try await StateRepository(url: url).save(initial)
        let other = PullRequestReference(owner: "example", repository: "synthetic", number: 6)
        let client = CardsClient(cards: [
            PullRequestSnapshot(reference: reference, title: "Synthetic refreshed card"),
            PullRequestSnapshot(reference: other, title: "Another card"),
        ])
        let store = AppStore(stateURL: url, githubClient: client, accessoryProviders: [])
        await store.start()
        defer { store.stop() }
        let notes = store.notes
        XCTAssertEqual(notes.count, 3)

        let noteViews = Flag()
        withObservationTracking {
            for note in notes {
                _ = note.value
                _ = NoteView(store: store, note: note).body
                _ = NoteView(store: store, note: note, detached: true).body
                _ = CollapsedNoteRow(store: store, note: note).body
                _ = DetachedNoteLauncher(note: note) {}.body
            }
        } onChange: {
            noteViews.raise()
        }
        let cards = Flag()
        withObservationTracking {
            _ = store.base.pullRequests
        } onChange: {
            cards.raise()
        }
        await store.refresh()
        XCTAssertTrue(cards.isRaised, "The refresh changed no cards")
        XCTAssertEqual(store.base.pullRequests.count, 2)
        XCTAssertFalse(noteViews.isRaised, "A GitHub refresh redrew a note")
    }

    func testTheBoardFollowsNotesBeingDetachedFoldedAddedAndDeleted() async throws {
        let url = try makeDirectory().appendingPathComponent("state.json")
        var initial = AppState()
        initial.githubEnabled = false
        initial.boardLayout.notesStartCollapsed = false
        initial.notes = [Note(markdown: "# First"), Note(markdown: "# Second"), Note(markdown: "# Third")]
        try await StateRepository(url: url).save(initial)
        let app = AppDelegate()
        await app.prepare(stateURL: url, isDemo: true)
        defer { for session in app.manager?.sessions.values.map({ $0 }) ?? [] { session.stop() } }
        let store = try XCTUnwrap(app.store)
        let board = try XCTUnwrap(app.board.contentView)
        func editors() async -> Int {
            await settle(board)
            return textViews(in: board).count
        }
        let notes = store.notes
        var count = await editors()
        XCTAssertEqual(count, 3)
        store.detachNote(notes[0].id)
        count = await editors()
        XCTAssertEqual(count, 2, "A detached note leaves the board for its window")
        store.toggleNoteExpanded(notes[1].id)
        count = await editors()
        XCTAssertEqual(count, 1, "A folded note shows as a row")
        let added = store.addNote("# Added")
        count = await editors()
        XCTAssertEqual(count, 2, "A new note opens on the board")
        store.deleteNote(added)
        count = await editors()
        XCTAssertEqual(count, 1, "A deleted note leaves the board")
    }

    func testANewNoteScrollsIntoViewOnTheBoard() async throws {
        let url = try makeDirectory().appendingPathComponent("state.json")
        var initial = AppState()
        initial.githubEnabled = false
        initial.boardLayout.notesStartCollapsed = false
        let lines = (1...6).map { "Line \($0)" }.joined(separator: "\n")
        initial.notes = (1...8).map { Note(markdown: "# Note \($0)\n\n\(lines)") }
        try await StateRepository(url: url).save(initial)
        let app = AppDelegate()
        await app.prepare(stateURL: url, isDemo: true)
        defer { for session in app.manager?.sessions.values.map({ $0 }) ?? [] { session.stop() } }
        let store = try XCTUnwrap(app.store)
        let board = try XCTUnwrap(app.board.contentView)
        await settle(board)
        let boardScroll = try XCTUnwrap(textViews(in: board).first?.enclosingScrollView?.enclosingScrollView)
        let clip = boardScroll.contentView
        let bottom = (boardScroll.documentView?.frame.height ?? 0) - clip.bounds.height
        XCTAssertGreaterThan(bottom, 200, "The notes overflow the board")
        clip.scroll(to: NSPoint(x: 0, y: bottom))
        boardScroll.reflectScrolledClipView(clip)
        await settle(board)
        XCTAssertGreaterThan(clip.bounds.minY, 200)

        // The board's + button adds a note this way, and the focus request scrolls the board to it.
        let text = "# Added from the plus button"
        store.addNote(text)
        let shown = await waitUntil {
            board.layoutSubtreeIfNeeded()
            guard let editor = self.textViews(in: board).first(where: { $0.string == text }) else { return false }
            return clip.bounds.intersects(editor.convert(editor.bounds, to: clip))
        }
        XCTAssertTrue(shown, "The new note's editor is in view")
    }

    func testAnExternalEditReachesTheEditorOfAnOpenBoardNote() async throws {
        let url = try makeDirectory().appendingPathComponent("state.json")
        var initial = AppState()
        initial.githubEnabled = false
        initial.notes = [Note(markdown: "# Open on the board\n\nOriginal text.")]
        try await StateRepository(url: url).save(initial)
        let store = AppStore(stateURL: url, accessoryProviders: [])
        await store.start()
        defer { store.stop() }
        let note = try XCTUnwrap(store.notes.first)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 400), styleMask: [.titled], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(
            rootView: NoteView(store: store, note: note, editorHeightLimit: 300) {}.themed(by: store.theme))
        window.contentView = host
        window.orderFront(nil)
        await settle(host)
        let editor = try XCTUnwrap(textViews(in: host).first)
        XCTAssertEqual(editor.string, note.markdown)

        let external = "# Open on the board\n\nEdited in another app.\n"
        try Data(external.utf8).write(
            to: store.notesDirectory.appendingPathComponent("\(note.id.uuidString).md"), options: .atomic)
        let saved = await store.flush()
        XCTAssertTrue(saved)
        await settle(host)
        XCTAssertEqual(note.markdown, external)
        XCTAssertEqual(editor.string, external)
    }

    func testScriptedEditsGiveTheSameSnapshotAndSavedState() async throws {
        let directory = try makeDirectory()
        let stateURL = directory.appendingPathComponent("state.json")
        let seedID = try XCTUnwrap(UUID(uuidString: "00000000-0000-4000-8000-000000000001"))
        let windowID = try XCTUnwrap(UUID(uuidString: "00000000-0000-4000-8000-000000000002"))
        let created = Date(timeIntervalSinceReferenceDate: 800_000_000)
        var initial = AppState()
        initial.githubEnabled = false
        initial.boardFrame = WindowFrame(x: 10, y: 20, width: 380, height: 700)
        initial.notes = [
            Note(
                id: seedID, markdown: "# Seed note\n\nOriginal source.",
                pullRequest: .init(owner: "example", repository: "synthetic", number: 1), createdAt: created,
                updatedAt: created),
            Note(
                id: windowID, markdown: "# Window note\n\nDetached at launch.", isDetached: true,
                isAlwaysOnTop: false, frame: WindowFrame(x: 100, y: 120, width: 340, height: 380),
                createdAt: created, updatedAt: created),
        ]
        try await StateRepository(url: stateURL).save(initial)
        let store = AppStore(stateURL: stateURL, accessoryProviders: [])
        await store.start()
        defer { store.stop() }
        let steps = StepClock()
        // Each step starts once earlier saves are done, so its dates come after its mark.
        func step() async throws {
            try await Task.sleep(for: .milliseconds(30))
            _ = await store.flush()
            steps.mark()
        }
        func file(_ id: UUID) -> URL { store.notesDirectory.appendingPathComponent("\(id.uuidString).md") }

        try await step()
        let typed = store.addNote()
        for text in ["#", "# T", "# Typed", "# Typed note", "# Typed note\n\nHello", "# Typed note\n\nHello there."] {
            store.editNote(typed, markdown: text)
        }
        try await step()
        _ = store.startNote()
        let second = store.addNote("Second note")
        try await step()
        store.pasteOutsideEditor("https://github.com/example/synthetic/pull/7\nPasted linked note")
        let pasted = try XCTUnwrap(store.snapshot().notes.first { $0.markdown == "Pasted linked note" }?.id)
        store.unlinkPullRequest(seedID)
        let linked = store.addNote(
            "Note for the card", reference: PullRequestReference(owner: "example", repository: "synthetic", number: 7))
        try await step()
        store.detachNote(typed)
        store.toggleAlwaysOnTop(typed)
        store.toggleSample(noteID: typed)
        try await step()
        store.saveFrame(WindowFrame(x: 40, y: 60, width: 300, height: 320), noteID: typed)
        store.saveFrame(WindowFrame(x: 44, y: 66, width: 310, height: 330), noteID: windowID)
        store.saveFrame(WindowFrame(x: 500, y: 80, width: 390, height: 710))
        store.closeDetachedNote(windowID)
        try await step()
        try Data("# Seed note\n\nEdited outside Stow.\n".utf8).write(to: file(seedID), options: .atomic)
        _ = await store.flush()
        try await step()
        store.editNote(second, markdown: "Second note, edited here")
        try Data("Second note, edited elsewhere\n".utf8).write(to: file(second), options: .atomic)
        _ = await store.flush()
        try await step()
        try FileManager.default.removeItem(at: file(windowID))
        _ = await store.flush()
        try await step()
        store.deleteNote(pasted)
        _ = await store.flush()
        try await step()
        store.editNote(linked, markdown: "Note for the card, last edit before quit")
        let savedAtQuit = await store.terminationSave().value
        XCTAssertTrue(savedAtQuit)

        let actual = try normalized(store.snapshot(), stateURL: stateURL, notes: store.notesDirectory, steps: steps)
        // Recorded from the same script before notes had their own models.
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "NoteScript", withExtension: "json"))
        let expected = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as? [String: Any])
        let text = String(
            decoding: try JSONSerialization.data(
                withJSONObject: actual, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
            as: UTF8.self)
        XCTAssertTrue(NSDictionary(dictionary: actual).isEqual(to: expected), "The script now gives:\n\(text)")
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "StowNoteModelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func model(_ store: AppStore, _ id: UUID) throws -> NoteModel { try XCTUnwrap(store.note(id)) }

    private func settle(_ host: NSView) async {
        for _ in 0..<8 {
            host.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private func waitUntil(_ predicate: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<50 {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return predicate()
    }

    private func textViews(in root: NSView) -> [NSTextView] {
        (root as? NSTextView).map { [$0] } ?? root.subviews.flatMap { textViews(in: $0) }
    }

    /// The snapshot with dates as script steps, the saved index without dates, and the note files, IDs numbered.
    private func normalized(_ snapshot: AppState, stateURL: URL, notes: URL, steps: StepClock) throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let marks = steps.marks
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode("step \(marks.filter { $0 <= date }.count)")
        }
        var names: [String: String] = [:]
        func numbered(_ text: String) -> String {
            text.replacing(/[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}/) { match in
                let id = String(match.output)
                if names[id] == nil { names[id] = "id \(names.count + 1)" }
                return names[id]!
            }
        }
        let memory = numbered(String(decoding: try encoder.encode(snapshot), as: UTF8.self))
        let saved = numbered(
            try String(contentsOf: stateURL, encoding: .utf8)
                .replacing(/"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z"/, with: "\"date\""))
        var files: [String: String] = [:]
        let urls = try FileManager.default.contentsOfDirectory(at: notes, includingPropertiesForKeys: nil)
        for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where url.pathExtension == "md" {
            files[numbered(url.lastPathComponent)] = try String(contentsOf: url, encoding: .utf8)
        }
        return [
            "snapshot": try JSONSerialization.jsonObject(with: Data(memory.utf8)),
            "state.json": try JSONSerialization.jsonObject(with: Data(saved.utf8)), "notes": files,
        ]
    }
}

/// Raised by an observation's change handler.
private final class Flag: @unchecked Sendable {
    private(set) var isRaised = false
    func raise() { isRaised = true }
}

/// When each step of a script began, so dates can be compared by the step that made them.
@MainActor
private final class StepClock {
    private(set) var marks: [Date] = []
    func mark() { marks.append(.now) }
}

/// Answers each refresh with the cards it holds, as one synthetic login.
private actor CardsClient: GitHubClient {
    private let cards: [PullRequestSnapshot]

    init(cards: [PullRequestSnapshot]) { self.cards = cards }

    func refresh(pins: [PullRequestReference], previous: [PullRequestSnapshot], expectedViewerLogin: String?)
        async throws -> GitHubRefreshResult
    {
        .init(viewerLogin: "synthetic-viewer", snapshots: cards)
    }

    func details(for reference: PullRequestReference) async throws -> PullRequestDetails {
        throw GitHubError.requestFailed
    }
}
