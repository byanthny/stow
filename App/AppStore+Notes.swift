import Foundation
import StowCore

extension AppStore {
    @discardableResult func addNote(_ markdown: String = "", reference: PullRequestReference? = nil) -> UUID {
        discardEmptyDraft()
        let note = Note(markdown: markdown, pullRequest: reference)
        state.notes.insert(note, at: 0)
        requestFocus(note.id)
        changed()
        return note.id
    }

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
        expandedNoteIDs.insert(id)
    }

    /// Ends a focus request once its note's editor has focus.
    func focusTaken(by id: UUID) {
        if focusNoteID == id { focusNoteID = nil }
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

    /// The note becomes a standalone note. Its text and Markdown file stay as they are.
    func unlinkPullRequest(_ id: UUID) {
        guard let index = state.notes.firstIndex(where: { $0.id == id }), state.notes[index].pullRequest != nil else {
            return
        }
        state.notes[index].pullRequest = nil
        changed()
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

    func importMarkdown(_ sources: [String]) {
        guard !isRestoringBackup, !sources.isEmpty else { return }
        let imported = sources.map { Note(markdown: $0) }
        state.notes.insert(contentsOf: imported, at: 0)
        if let first = imported.first { requestFocus(first.id) }
        changed()
    }
}
