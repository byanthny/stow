import AppKit
import StowCore
import SwiftUI

struct NoteView: View {
    @Bindable var store: AppStore
    let noteID: UUID
    @Environment(\.stowTheme) private var theme
    @Environment(\.windowChrome) private var chrome
    var detached = false
    /// A detached note's profile. Its color shows as a thin accent and its name in the title area once profile
    /// names show.
    var profile: ProfileHandle?
    /// How tall a board note's editor may grow while it is edited.
    var editorHeightLimit: CGFloat = 176
    /// Board notes can fold back into a one-line row.
    var onCollapse: (() -> Void)?
    /// A board note shows a few lines, and its whole text only while it is being edited.
    @State private var isEditing = false
    /// Only a detached note's header shares its window's title bar row.
    private var headerChrome: WindowChrome { detached ? chrome : WindowChrome() }

    var body: some View {
        if let note = store.note(noteID) {
            let identity = detached ? profile.flatMap { $0.showsIdentity ? $0.entry : nil } : nil
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    if let onCollapse {
                        Button(action: onCollapse) {
                            Image(systemName: "chevron.down").font(theme.font(size: 8, weight: .semibold))
                                .frame(width: 18, height: 22).contentShape(Rectangle())
                        }.buttonStyle(.plain).foregroundStyle(.stowMuted)
                            .accessibilityLabel("Collapse note").help("Collapse note")
                    }
                    if let identity {
                        Label(identity.name, systemImage: "doc.text")
                            .font(theme.font(size: 10, weight: .medium)).foregroundStyle(.stowMuted).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    headerButton("folder", "Show Markdown file", "note.showFile") {
                        DataTransferActions.showNoteFile(note, store: store)
                    }
                    headerButton("square.and.arrow.up", "Export Markdown…", "note.export") {
                        DataTransferActions.exportNote(note, store: store)
                    }
                    headerButton("trash", "Delete note…", "note.delete") { confirmDelete() }
                    if detached {
                        headerButton(
                            note.isAlwaysOnTop ? "pin.fill" : "pin", "Always on top", "note.alwaysOnTop", scale: .small
                        ) {
                            store.toggleAlwaysOnTop(noteID)
                        }
                    } else {
                        headerButton("arrow.up.right.square", "Detach note", "note.detach") { store.detachNote(noteID) }
                    }
                    let menu = actions(for: note)
                    if !menu.isEmpty {
                        PullDownMenu(
                            symbol: "ellipsis", sections: menu, label: "Note actions",
                            identifier: "note.actions", tint: theme.color(.muted), symbolSize: detached ? 13 : 9,
                            symbolWeight: detached ? .regular : .medium
                        ).fixedSize()
                    }
                }
                .windowHeaderRow(headerChrome, horizontal: 10, vertical: 0)
                .padding(.top, headerChrome.isInline ? 0 : 6)
                // On the board, a click anywhere else in the header folds the note too.
                .background {
                    if let onCollapse { Color.clear.contentShape(Rectangle()).onTapGesture(perform: onCollapse) }
                }

                if let reference = note.pullRequest {
                    Button {
                        AppStore.openLink(reference.url)
                    } label: {
                        Label(reference.displayName, systemImage: "link").font(theme.font(size: 10)).lineLimit(1)
                    }.buttonStyle(.plain).foregroundStyle(.stowMuted)
                        .padding(.horizontal, 12).padding(.top, 3)
                        .contextMenu {
                            Button("Open pull request") { AppStore.openLink(reference.url) }
                            Button("Remove pull request link") { store.unlinkPullRequest(noteID) }
                        }
                        .accessibilityAction(named: "Remove pull request link") { store.unlinkPullRequest(noteID) }
                }

                // Board notes grow to their whole text while edited; detached notes fill their window.
                NativeEditor(
                    text: Binding(
                        get: { store.note(noteID)?.markdown ?? "" },
                        set: { store.editNote(noteID, markdown: $0) }), shouldFocus: store.focusNoteID == noteID,
                    focusRequestID: store.focusRequestID, appearance: theme.settings,
                    fitsText: detached ? nil : 104...(isEditing ? max(176, editorHeightLimit) : 176),
                    onEditingChange: { isEditing = $0 }
                )
                .frame(minHeight: detached ? 120 : nil, maxHeight: detached ? .infinity : nil)
                .padding(.horizontal, 8)
                AccessoryViews(store: store, noteID: noteID)
            }
            // Detached notes take the board's background.
            .background(
                detached ? StowColor.stowBackground : .stowNote, in: RoundedRectangle(cornerRadius: detached ? 0 : 9)
            )
            .overlay { if !detached { RoundedRectangle(cornerRadius: 9).strokeBorder(.white.opacity(0.035)) } }
            .overlay(alignment: .top) {
                if let identity {
                    Rectangle().fill(Color(stowHex: identity.color)).frame(height: 3).accessibilityHidden(true)
                }
            }
            .preferredColorScheme(theme.colorScheme)
            .disabled(store.isRestoringBackup)
            .background {
                if detached { WindowTitle(title: note.windowTitle(profileName: identity?.name)) }
            }
        }
    }

    /// Board notes use the card icon size; a detached note's header matches the board's window header.
    @ViewBuilder private func headerButton(
        _ symbol: String, _ label: String, _ identifier: String, scale: Image.Scale = .medium,
        action: @escaping () -> Void
    ) -> some View {
        if detached {
            QuietIconButton(symbol: symbol, label: label, scale: scale, action: action)
        } else {
            CardIconButton(symbol: symbol, label: label, identifier: identifier, scale: scale, action: action)
        }
    }

    /// The ⋯ menu offers the sample accessory only once it is on in Settings, or already on for this note.
    private func actions(for note: Note) -> [[PullDownMenu.Item]] {
        var sections: [[PullDownMenu.Item]] = []
        if note.pullRequest != nil {
            sections.append([.init(title: "Remove pull request link") { store.unlinkPullRequest(noteID) }])
        }
        let sampleOnHere = store.sampleEnabled(noteID: noteID)
        if sampleOnHere || store.sampleEnabled() {
            let title = sampleOnHere ? "Disable sample accessory" : "Enable sample accessory"
            sections.append([.init(title: title) { store.toggleSample(noteID: noteID) }])
        }
        return sections
    }

    /// Deleting a note also deletes its Markdown file, so a note with text asks first.
    private func confirmDelete() {
        guard let note = store.note(noteID) else { return }
        if !note.markdown.allSatisfy(\.isWhitespace) {
            let alert = NSAlert()
            alert.messageText = "Delete “\(note.boardTitle)”?"
            alert.informativeText = "Its Markdown file is deleted too. This can’t be undone."
            alert.addButton(withTitle: "Delete").hasDestructiveAction = true
            alert.addButton(withTitle: "Cancel")
            alert.window.appearance = theme.appKitAppearance
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        store.deleteNote(noteID)
    }
}

struct DetachedNoteLauncher: View {
    let note: Note
    @Environment(\.stowTheme) private var theme
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.up.right.square").font(theme.font(size: 9, weight: .medium))
                    .foregroundStyle(.stowMuted)
                Text(verbatim: note.boardTitle)
                    .font(theme.font(size: 12)).lineLimit(1)
                Spacer()
                Text("Open").font(theme.font(size: 10)).foregroundStyle(.stowMuted)
            }.padding(12).background(.stowSurface, in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain).accessibilityLabel("Open detached note")
    }
}

/// A board note folded into one line: open it inline, or pop it out into its own window.
/// The Notes area's typing spot: clicking it starts a note with the cursor ready.
struct NoteComposerRow: View {
    /// With no notes yet, the row also explains what the area is for.
    let isEmpty: Bool
    var start: () -> Void
    @Environment(\.stowTheme) private var theme

    var body: some View {
        Button(action: start) {
            VStack(alignment: .leading, spacing: 4) {
                if isEmpty {
                    Text("A little room to think.").font(theme.font(size: 13, weight: .medium))
                        .foregroundStyle(.stowText)
                }
                Text(isEmpty ? "Click here and start typing, or paste a pull request link." : "Start typing a note…")
                    .font(theme.font(size: isEmpty ? 11 : 12)).foregroundStyle(.stowMuted)
            }
            .padding(isEmpty ? 14 : 12).frame(maxWidth: .infinity, alignment: .leading)
            .background(.stowSurface, in: RoundedRectangle(cornerRadius: isEmpty ? 9 : 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Start a note")
        .accessibilityHint("Starts a note you can type into right away")
        .accessibilityIdentifier("notes.composer")
    }
}

struct CollapsedNoteRow: View {
    @Bindable var store: AppStore
    let note: Note
    @Environment(\.stowTheme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            Button {
                store.toggleNoteExpanded(note.id)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right").font(theme.font(size: 8, weight: .semibold)).frame(width: 9)
                        .foregroundStyle(.stowMuted)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: note.boardTitle).font(theme.font(size: 12, weight: .medium)).lineLimit(1)
                        HStack(spacing: 6) {
                            if let reference = note.pullRequest { Text(verbatim: reference.displayName) }
                            TimelineView(.periodic(from: .now, by: 60)) { context in
                                Text("Edited \(note.updatedAt.shortAge(relativeTo: context.date))")
                            }
                        }.font(theme.font(size: 10)).foregroundStyle(.stowMuted).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(note.boardTitle).accessibilityHint("Opens the note")
            CardIconButton(symbol: "arrow.up.right.square", label: "Detach note", identifier: "note.detach") {
                store.detachNote(note.id)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(.stowNote, in: RoundedRectangle(cornerRadius: 9))
        .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(.white.opacity(0.035)) }
    }
}

/// Names the hosting window, for the Window menu, Mission Control, and VoiceOver.
private struct WindowTitle: NSViewRepresentable {
    let title: String
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        let title = title
        // The view joins its window after its first update.
        DispatchQueue.main.async {
            if let window = view.window, window.title != title { window.title = title }
        }
    }
}

extension Note {
    /// A detached note's window title: its title line, with the profile's name once names show.
    func windowTitle(profileName: String?) -> String {
        profileName.map { "\(boardTitle) — \($0)" } ?? boardTitle
    }

    /// The note's title for one-line rows.
    var boardTitle: String { title ?? "Untitled note" }
}
