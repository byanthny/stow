import Foundation
import StowCore

extension AppStore {
    @discardableResult func addNote(_ markdown: String = "", reference: PullRequestReference? = nil) -> UUID {
        discardEmptyDraft()
        let note = NoteModel(Note(markdown: markdown, pullRequest: reference))
        notes.insert(note, at: 0)
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
        if base.collapsedSections.contains("notes") {
            base.collapsedSections.removeAll { $0 == "notes" }
            changed()
        }
        focusNoteID = id
        focusRequestID = UUID()
    }

    func note(_ id: UUID) -> NoteModel? { notes.first { $0.id == id } }

    func editNote(_ id: UUID, markdown: String) {
        guard let note = note(id), note.markdown != markdown else { return }
        note.markdown = markdown
        note.updatedAt = .now
        // Typing into a started note keeps it.
        if id == draftNoteID, !markdown.isEmpty { draftNoteID = nil }
        changed()
    }

    func detachNote(_ id: UUID) {
        guard let note = note(id) else { return }
        if id == draftNoteID { draftNoteID = nil }
        note.isDetached = true
        changed()
        onDetach?(id)
    }

    /// The note becomes a standalone note. Its text and Markdown file stay as they are.
    func unlinkPullRequest(_ id: UUID) {
        guard let note = note(id), note.pullRequest != nil else { return }
        note.pullRequest = nil
        changed()
    }

    func closeDetachedNote(_ id: UUID) {
        guard !isTerminating, let note = note(id) else { return }
        note.isDetached = false
        changed()
    }

    func deleteNote(_ id: UUID) {
        deletedNoteIDs.insert(id)
        expandedNoteIDs.remove(id)
        notes.removeAll { $0.id == id }
        let removed = base.extensionInstances.filter { $0.noteID == id }
        base.extensionInstances.removeAll { $0.noteID == id }
        for instance in removed {
            accessoryRuns.removeValue(forKey: instance.id)?.cancel()
            accessoryTokens[instance.id] = nil
            Task { await accessoryHost.cancel(instanceID: instance.id, moduleID: instance.moduleID) }
        }
        onDelete?(id)
        changed()
    }

    func toggleAlwaysOnTop(_ id: UUID) {
        guard let note = note(id) else { return }
        note.isAlwaysOnTop.toggle()
        changed()
        onDetach?(id)
    }

    func saveFrame(_ frame: WindowFrame, noteID: UUID? = nil) {
        if let noteID, let note = note(noteID) {
            note.frame = frame
        } else if noteID == nil {
            boardFrame = frame
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
        notes.insert(contentsOf: imported.map(NoteModel.init), at: 0)
        if let first = imported.first { requestFocus(first.id) }
        changed()
    }
}
