import AppKit
import Darwin
import Foundation
import StowCore
import SwiftUI
import UniformTypeIdentifiers

struct DataTransferView: View {
    @Bindable var store: AppStore
    @Environment(\.stowTheme) private var theme
    @State private var error: String?
    @State private var status: String?
    @State private var isRestoring = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Notes and backups").font(theme.font(size: 14, weight: .semibold))
            Text("Notes are live Markdown files. Open the notes folder to edit them in another app.")
                .font(theme.font(size: 11)).foregroundStyle(.stowMuted)
            Button("Open notes folder") { DataTransferActions.showNotesFolder(store: store) }
                .accessibilityIdentifier("data.notesFolder")
            HStack {
                Button("Import Markdown…") { importMarkdown() }.accessibilityIdentifier("data.importMarkdown")
                Button("Export all notes…") { exportMarkdown() }.accessibilityIdentifier("data.exportMarkdown")
                    .disabled(store.state.notes.isEmpty)
            }
            Text("Import adds notes. Export creates Markdown copies in a new folder, leaving your live files in place.")
                .font(theme.font(size: 10)).foregroundStyle(.stowMuted)
            HStack {
                Button("Save backup…") { saveBackup() }.accessibilityIdentifier("data.saveBackup")
                Button("Restore backup…") { restoreBackup() }.accessibilityIdentifier("data.restoreBackup")
                if isRestoring { ProgressView().controlSize(.small) }
            }
            Text(
                "Backups include note text, settings, and cached pull requests. Keep them private. GitHub credentials are not included."
            )
            .font(theme.font(size: 10)).foregroundStyle(.stowMuted)
            if let status {
                Text(status).font(theme.font(size: 11)).foregroundStyle(.stowMuted)
                    .accessibilityIdentifier("data.status")
            }
            if let error {
                Text(error).font(theme.font(size: 11)).foregroundStyle(.stowRed)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("data.error")
            }
        }
        .font(theme.font(size: 11))
        .disabled(isRestoring)
    }

    private func importMarkdown() {
        clearFeedback()
        let panel = NSOpenPanel()
        panel.title = "Import Markdown notes"
        panel.allowedContentTypes = [DataTransferActions.markdownType, .plainText]
        panel.allowsOtherFileTypes = true
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        do {
            let urls = panel.urls
            guard urls.allSatisfy({ ["md", "markdown"].contains($0.pathExtension.lowercased()) }) else {
                error = "Choose .md or .markdown files. No notes were imported."
                return
            }
            let sources = try urls.map { url in
                try MarkdownTransfer.decodeNote(
                    DataTransferFiles.read(url, maximumBytes: MarkdownTransfer.maximumNoteByteCount))
            }
            guard !sources.isEmpty else { return }
            store.importMarkdown(sources)
            status = "Imported \(sources.count) \(sources.count == 1 ? "note" : "notes")."
        } catch {
            self.error = "No notes were imported. Each file must be readable UTF-8 Markdown, up to 8 MiB."
        }
    }

    private func exportMarkdown() {
        clearFeedback()
        let panel = NSOpenPanel()
        panel.title = "Choose a folder for exported notes"
        panel.prompt = "Export notes"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        Task { @MainActor in
            do {
                let snapshot = try await store.portableSnapshot()
                let folder = try DataTransferFiles.exportMarkdown(
                    MarkdownTransfer.files(for: snapshot.notes), into: parent)
                status = "Exported \(snapshot.notes.count) notes to \(folder.lastPathComponent)."
                NSWorkspace.shared.activateFileViewerSelecting([folder])
            } catch DataTransferFileError.cannotSynchronize {
                error =
                    "Live note files could not be synchronized. Your in-memory notes have been kept. Resolve the save error and try again."
            } catch {
                self.error = "The notes could not be exported. Check the selected folder and available disk space."
            }
        }
    }

    private func saveBackup() {
        clearFeedback()
        let panel = NSSavePanel()
        panel.title = "Save private Stow backup"
        panel.allowedContentTypes = [DataTransferActions.backupType]
        panel.allowsOtherFileTypes = true
        panel.nameFieldStringValue = "Stow-\(DataTransferFiles.dateStamp()).stowbackup"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { @MainActor in
            do {
                let snapshot = try await store.portableSnapshot()
                let data = try StowBackup.encode(snapshot, createdAt: .now)
                try DataTransferFiles.writePrivateAtomically(data, to: url)
                status = "Saved backup to \(url.lastPathComponent)."
            } catch DataTransferFileError.cannotSynchronize {
                error =
                    "Live note files could not be synchronized. Your in-memory notes have been kept. Resolve the save error and try again."
            } catch {
                self.error = "The backup could not be saved. Check the selected folder and available disk space."
            }
        }
    }

    private func restoreBackup() {
        clearFeedback()
        let panel = NSOpenPanel()
        panel.title = "Choose a Stow backup to restore"
        panel.allowedContentTypes = [DataTransferActions.backupType, .json]
        panel.allowsOtherFileTypes = true
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let restored: AppState
        do {
            restored = try StowBackup.decode(DataTransferFiles.read(url, maximumBytes: StowBackup.maximumByteCount))
        } catch {
            self.error =
                "The backup could not be opened. Choose a valid Stow backup up to 64 MiB. Your current data has been kept."
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Replace current notes and settings?"
        alert.informativeText =
            "“\(url.lastPathComponent)” contains \(restored.notes.count) notes and \(restored.pullRequests.count) cached pull requests. Restoring replaces current notes and settings. This Mac's GitHub settings stay as they are, and accessories come back turned off. Your current data and old notes folder are kept as backups. Reopen the new notes folder in external editors afterward; the old folder will no longer be watched."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Replace and restore")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        isRestoring = true
        Task { @MainActor in
            let success = await store.restoreBackup(restored)
            isRestoring = false
            if success {
                status = "Restored \(restored.notes.count) notes from \(url.lastPathComponent)."
            } else {
                error = "The backup could not be restored. Check the storage folder and try again."
            }
        }
    }

    private func clearFeedback() {
        error = nil
        status = nil
    }
}

@MainActor
enum DataTransferActions {
    static var markdownType: UTType { UTType(filenameExtension: "md", conformingTo: .plainText) ?? .plainText }
    static var backupType: UTType { UTType(filenameExtension: "stowbackup", conformingTo: .json) ?? .json }

    static func exportNote(_ note: Note, store: AppStore) {
        guard let file = MarkdownTransfer.files(for: [note]).first else { return }
        let panel = NSSavePanel()
        panel.title = "Export Markdown note"
        panel.allowedContentTypes = [markdownType]
        panel.allowsOtherFileTypes = true
        panel.nameFieldStringValue = file.filename
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { @MainActor in
            do {
                let snapshot = try await store.portableSnapshot()
                guard let current = snapshot.notes.first(where: { $0.id == note.id }) else {
                    showError("The note was removed before export. No file was written.")
                    return
                }
                try DataTransferFiles.writePrivateAtomically(Data(current.markdown.utf8), to: url)
            } catch DataTransferFileError.cannotSynchronize {
                showError(
                    "Live note files could not be synchronized. Your in-memory notes have been kept. Resolve the save error and try again."
                )
            } catch {
                showError("The note could not be exported. Check the selected folder and available disk space.")
            }
        }
    }

    static func showNotesFolder(store: AppStore) {
        if !NSWorkspace.shared.open(store.notesDirectory) {
            showError("The notes folder could not be opened. Check the storage folder and try again.")
        }
    }

    static func showNoteFile(_ note: Note, store: AppStore) {
        Task { @MainActor in
            guard await store.flush() else {
                showError("The note could not be saved before opening its file. Keep Stow open and try again.")
                return
            }
            let url = store.notesDirectory.appendingPathComponent("\(note.id.uuidString).md")
            guard FileManager.default.fileExists(atPath: url.path) else {
                showError("The note file could not be found. Open the notes folder to inspect its files.")
                return
            }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    private static func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Stow could not complete the transfer"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

enum DataTransferFileError: Error, Equatable {
    case tooLarge, invalidFilename, cannotCreateFolder, cannotWrite, cannotSynchronize
}

/// Private-on-creation output and bounded reads shared by user-initiated transfer actions.
enum DataTransferFiles {
    static func dateStamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        return formatter.string(from: .now)
    }

    static func read(_ url: URL, maximumBytes: Int) throws -> Data {
        guard maximumBytes >= 0, maximumBytes < Int.max else { throw DataTransferFileError.tooLarge }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        while data.count <= maximumBytes {
            let next = try handle.read(upToCount: min(65_536, maximumBytes + 1 - data.count)) ?? Data()
            if next.isEmpty { return data }
            data.append(next)
        }
        throw DataTransferFileError.tooLarge
    }

    static func exportMarkdown(_ files: [MarkdownFile], into parent: URL) throws -> URL {
        let directory = try newExportDirectory(in: parent)
        var completed = false
        defer { if !completed { try? FileManager.default.removeItem(at: directory) } }
        for file in files {
            guard !file.filename.isEmpty, ![".", ".."].contains(file.filename),
                !file.filename.contains("/"), !file.filename.contains("\0")
            else {
                throw DataTransferFileError.invalidFilename
            }
            try writeNewPrivateFile(Data(file.source.utf8), to: directory.appendingPathComponent(file.filename))
        }
        completed = true
        return directory
    }

    static func writePrivateAtomically(_ data: Data, to destination: URL) throws {
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(
            ".stow-transfer-\(UUID().uuidString).tmp")
        try writeNewPrivateFile(data, to: temporary)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let result = temporary.path.withCString { source in
            destination.path.withCString { target in Darwin.rename(source, target) }
        }
        guard result == 0 else { throw DataTransferFileError.cannotWrite }
    }

    private static func newExportDirectory(in parent: URL) throws -> URL {
        for _ in 0..<5 {
            let directory = parent.appendingPathComponent(
                "Stow-notes-\(dateStamp())-\(UUID().uuidString)", isDirectory: true)
            let result = directory.path.withCString { Darwin.mkdir($0, mode_t(0o700)) }
            if result == 0 {
                guard directory.path.withCString({ Darwin.chmod($0, mode_t(0o700)) }) == 0 else {
                    try? FileManager.default.removeItem(at: directory)
                    throw DataTransferFileError.cannotCreateFolder
                }
                return directory
            }
            if errno != EEXIST { throw DataTransferFileError.cannotCreateFolder }
        }
        throw DataTransferFileError.cannotCreateFolder
    }

    private static func writeNewPrivateFile(_ data: Data, to url: URL) throws {
        let descriptor = url.path.withCString {
            Darwin.open($0, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, mode_t(0o600))
        }
        guard descriptor >= 0 else { throw DataTransferFileError.cannotWrite }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var completed = false
        defer {
            try? handle.close()
            if !completed { try? FileManager.default.removeItem(at: url) }
        }
        guard Darwin.fchmod(descriptor, mode_t(0o600)) == 0 else { throw DataTransferFileError.cannotWrite }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
        completed = true
    }
}
