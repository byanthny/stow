import StowCore
import SwiftUI

struct NoteView: View {
    @Bindable var store: AppStore
    let noteID: UUID
    var detached = false
    @State private var isPreview = false

    var body: some View {
        if let note = store.note(noteID) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Label(detached ? "Note" : "Markdown", systemImage: "note.text")
                        .font(.stow(size: 10, weight: .medium)).foregroundStyle(Color.stowMuted)
                    Spacer(minLength: 0)
                    Button(isPreview ? "Edit" : "Preview") { isPreview.toggle() }
                        .buttonStyle(.plain).font(.stow(size: 10, weight: .medium)).foregroundStyle(Color.stowMuted)
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
                    Menu {
                        Button(
                            store.sampleEnabled(noteID: noteID) ? "Disable sample accessory" : "Enable sample accessory"
                        ) { store.toggleSample(noteID: noteID) }
                        Divider()
                        Button("Delete note", role: .destructive) { store.deleteNote(noteID) }
                    } label: {
                        Image(systemName: "ellipsis").frame(width: 18, height: 20)
                    }
                    .menuStyle(.borderlessButton).fixedSize().help("Note actions")
                    .accessibilityIdentifier("note.actions")
                }
                .padding(.horizontal, 10).padding(.top, 6)

                if let reference = note.pullRequest {
                    Button {
                        AppStore.openLink(reference.url)
                    } label: {
                        Label(reference.displayName, systemImage: "link").font(.stow(size: 10)).lineLimit(1)
                    }.buttonStyle(.plain).foregroundStyle(Color.stowMuted)
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
                        focusRequestID: store.focusRequestID
                    )
                    .frame(minHeight: detached ? 120 : 104, maxHeight: detached ? .infinity : 176)
                    .padding(.horizontal, 8)
                }
                AccessoryViews(store: store, noteID: noteID)
            }
            .background(Color.stowNote, in: RoundedRectangle(cornerRadius: detached ? 0 : 9))
            .overlay { if !detached { RoundedRectangle(cornerRadius: 9).strokeBorder(.white.opacity(0.035)) } }
            .preferredColorScheme(ThemeController.shared.colorScheme)
        }
    }
}

struct DetachedNoteLauncher: View {
    let note: Note
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.up.right.square").foregroundStyle(Color.stowMuted)
                Text(note.markdown.split(separator: "\n").first.map(String.init) ?? "Untitled note")
                    .font(.stow(size: 12)).lineLimit(1)
                Spacer()
                Text("Open").font(.stow(size: 10)).foregroundStyle(Color.stowMuted)
            }.padding(12).background(Color.stowSurface, in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain).accessibilityLabel("Open detached note")
    }
}
