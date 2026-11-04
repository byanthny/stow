import StowCore
import SwiftUI

struct NoteView: View {
    @Bindable var store: AppStore
    let noteID: UUID
    @Environment(\.stowTheme) private var theme
    var detached = false
    /// A detached note's profile. Its color shows as a thin accent and its name in the title area once profile
    /// names show.
    var profile: ProfileHandle?
    /// Board notes can fold back into a one-line row.
    var onCollapse: (() -> Void)?
    @State private var isPreview = false

    var body: some View {
        if let note = store.note(noteID) {
            let identity = detached ? profile.flatMap { $0.showsIdentity ? $0.entry : nil } : nil
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    if let onCollapse {
                        Button(action: onCollapse) {
                            Image(systemName: "chevron.down").font(theme.font(size: 8, weight: .semibold))
                                .frame(width: 9)
                        }.buttonStyle(.plain).foregroundStyle(.stowMuted)
                            .accessibilityLabel("Collapse note").help("Collapse note")
                    }
                    Label(identity?.name ?? (detached ? "Note" : "Markdown"), systemImage: "note.text")
                        .font(theme.font(size: 10, weight: .medium)).foregroundStyle(.stowMuted).lineLimit(1)
                    Spacer(minLength: 0)
                    Button(isPreview ? "Edit" : "Preview") { isPreview.toggle() }
                        .buttonStyle(.plain).font(theme.font(size: 10, weight: .medium)).foregroundStyle(.stowMuted)
                        .accessibilityIdentifier("note.previewToggle")
                    if detached {
                        QuietIconButton(symbol: note.isAlwaysOnTop ? "pin.fill" : "pin", label: "Always on top") {
                            store.toggleAlwaysOnTop(noteID)
                        }
                    } else {
                        QuietIconButton(symbol: "arrow.up.right.square", label: "Detach note") {
                            store.detachNote(noteID)
                        }
                    }
                    PullDownMenu(
                        symbol: "ellipsis", sections: actions(for: note), label: "Note actions",
                        identifier: "note.actions", tint: theme.color(.muted)
                    ).fixedSize()
                }
                .padding(.horizontal, 10).padding(.top, 6)

                if let reference = note.pullRequest {
                    Button {
                        AppStore.openLink(reference.url)
                    } label: {
                        Label(reference.displayName, systemImage: "link").font(theme.font(size: 10)).lineLimit(1)
                    }.buttonStyle(.plain).foregroundStyle(.stowMuted)
                        .padding(.horizontal, 12).padding(.top, 3)
                }

                if isPreview {
                    ScrollView {
                        MarkdownPreview(source: note.markdown.isEmpty ? "*Nothing here yet.*" : note.markdown)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    }
                    .frame(minHeight: detached ? 120 : 100, maxHeight: detached ? .infinity : 240)
                } else {
                    NativeEditor(
                        text: Binding(
                            get: { store.note(noteID)?.markdown ?? "" },
                            set: { store.editNote(noteID, markdown: $0) }), shouldFocus: store.focusNoteID == noteID,
                        focusRequestID: store.focusRequestID, appearance: theme.settings
                    )
                    .frame(minHeight: detached ? 120 : 104, maxHeight: detached ? .infinity : 176)
                    .padding(.horizontal, 8)
                }
                AccessoryViews(store: store, noteID: noteID)
            }
            .background(.stowNote, in: RoundedRectangle(cornerRadius: detached ? 0 : 9))
            .overlay { if !detached { RoundedRectangle(cornerRadius: 9).strokeBorder(.white.opacity(0.035)) } }
            .overlay(alignment: .top) {
                if let identity {
                    Rectangle().fill(Color(stowHex: identity.color)).frame(height: 3).accessibilityHidden(true)
                }
            }
            .preferredColorScheme(theme.colorScheme)
            .disabled(store.isRestoringBackup)
        }
    }

    private func actions(for note: Note) -> [[PullDownMenu.Item]] {
        let sample = store.sampleEnabled(noteID: noteID) ? "Disable sample accessory" : "Enable sample accessory"
        return [
            [.init(title: sample) { store.toggleSample(noteID: noteID) }],
            [
                .init(title: "Show Markdown file") { DataTransferActions.showNoteFile(note, store: store) },
                .init(title: "Export Markdown…") { DataTransferActions.exportNote(note, store: store) },
            ],
            [.init(title: "Delete note") { store.deleteNote(noteID) }],
        ]
    }
}

struct DetachedNoteLauncher: View {
    let note: Note
    @Environment(\.stowTheme) private var theme
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.up.right.square").foregroundStyle(.stowMuted)
                Text(note.markdown.split(separator: "\n").first.map(String.init) ?? "Untitled note")
                    .font(theme.font(size: 12)).lineLimit(1)
                Spacer()
                Text("Open").font(theme.font(size: 10)).foregroundStyle(.stowMuted)
            }.padding(12).background(.stowSurface, in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain).accessibilityLabel("Open detached note")
    }
}

/// A board note folded into one line: open it inline, or pop it out into its own window.
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
                            Text("Edited \(note.updatedAt, style: .relative) ago")
                        }.font(theme.font(size: 10)).foregroundStyle(.stowMuted).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(note.boardTitle).accessibilityHint("Opens the note")
            QuietIconButton(symbol: "arrow.up.right.square", label: "Detach note") { store.detachNote(note.id) }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(.stowNote, in: RoundedRectangle(cornerRadius: 9))
        .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(.white.opacity(0.035)) }
    }
}

extension Note {
    /// The first non-empty line without Markdown heading marks, for one-line rows.
    var boardTitle: String {
        let line = markdown.split(whereSeparator: \.isNewline)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.trimmingCharacters(in: .whitespaces).drop { $0 == "#" }.trimmingCharacters(in: .whitespaces) }
        return line.flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled note"
    }
}
