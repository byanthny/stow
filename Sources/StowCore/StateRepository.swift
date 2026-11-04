import Foundation

public enum StateError: Error, LocalizedError, Equatable, Sendable {
    case unreadable
    case corrupt
    case unsupportedVersion(Int)
    case recoveryRequired
    case unwritable
    case recoveryFailed

    public var errorDescription: String? {
        switch self {
        case .unreadable:
            return "Stow could not read its saved state or Markdown files. The originals have been preserved."
        case .corrupt: return "Stow found invalid saved state or Markdown text. The originals have been preserved."
        case .unsupportedVersion(let version):
            return "This saved state uses unsupported version \(version). The original file has been preserved."
        case .recoveryRequired: return "Saved state must be repaired or explicitly backed up before it can be replaced."
        case .unwritable: return "Stow could not save state. Check access to the storage folder."
        case .recoveryFailed: return "Stow could not back up the saved state. The originals have been preserved."
        }
    }
}

/// The JSON index holds metadata; UUID.md files are the canonical, unmodified Markdown sources.
public actor StateRepository {
    public static var defaultURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent("Stow", isDirectory: true).appendingPathComponent("state.json")
    }
    private struct SourceAdoption {
        var caller: Data
        var note: Note
    }
    private struct DiskState: Codable {
        var schemaVersion = 2
        var metadata: AppState
        var notesDirectoryName: String?
    }
    private let url: URL
    public private(set) var notesDirectory: URL
    /// Whether the last load found a saved index. False for a new installation.
    public private(set) var foundSavedIndex = false
    private var hasLoaded = false
    private var expectsNotesDirectory = false
    private var requiresRecovery = false
    private var isClosed = false
    private var baselines: [UUID: Data] = [:]
    private var baselineNotes: [UUID: Note] = [:]
    private var locations: [UUID: URL] = [:]
    private var retainedNotes: [UUID: Note] = [:]
    private var unacknowledgedAdoptions: [UUID: SourceAdoption] = [:]
    private var deletionBaselines: [UUID: Data] = [:]
    private var migrationSource: Data?
    private var migrationIDs = Set<UUID>()
    private var migrationBackup: URL?
    private var lastState: AppState?

    public init(url: URL) {
        self.url = url
        self.notesDirectory = url.deletingLastPathComponent().appendingPathComponent("notes", isDirectory: true)
    }

    public func noteFileURL(id: UUID) -> URL {
        locations[id] ?? notesDirectory.appendingPathComponent("\(id.uuidString).md")
    }

    public func load() async throws -> AppState { try loadState() }

    private func loadState() throws -> AppState {
        guard !requiresRecovery else { throw StateError.recoveryRequired }
        do {
            let data = try LiveNoteIO.read(url, maximumBytes: LiveNoteIO.maximumIndexBytes)
            foundSavedIndex = data != nil
            var state = AppState()
            var legacy = false
            if let data {
                struct Version: Decodable { var schemaVersion: Int }
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                switch try decoder.decode(Version.self, from: data).schemaVersion {
                case 1:
                    state = try decoder.decode(AppState.self, from: data)
                    legacy = true
                    migrationSource = data
                    migrationIDs = Set(state.notes.map(\.id))
                case 2:
                    let diskState = try decoder.decode(DiskState.self, from: data)
                    let directoryName = diskState.notesDirectoryName ?? "notes"
                    guard Self.validDirectoryName(directoryName) else { throw StateError.corrupt }
                    notesDirectory = url.deletingLastPathComponent().appendingPathComponent(
                        directoryName, isDirectory: true)
                    state = diskState.metadata
                    guard state.schemaVersion == AppState.currentVersion else {
                        throw StateError.unsupportedVersion(state.schemaVersion)
                    }
                    guard state.notes.allSatisfy({ $0.markdown.isEmpty }) else { throw StateError.corrupt }
                case let version: throw StateError.unsupportedVersion(version)
                }
            }
            let directoryExists = try LiveNoteIO.exists(notesDirectory)
            if data != nil && !legacy && !directoryExists { throw StateError.unreadable }
            let files = try LiveNoteIO.files(in: notesDirectory)
            var loaded: [Note] = []
            var seen = Set<UUID>()
            var newBaselines: [UUID: Data] = [:]
            for var note in state.notes {
                guard seen.insert(note.id).inserted else { throw StateError.corrupt }
                let sourceURL = files[note.id] ?? notesDirectory.appendingPathComponent("\(note.id.uuidString).md")
                if let bytes = try LiveNoteIO.read(sourceURL, maximumBytes: MarkdownTransfer.maximumNoteByteCount) {
                    let externalSource = try LiveNoteIO.source(bytes)
                    if legacy, Data(note.markdown.utf8) != bytes {
                        // An interrupted migration or pre-existing UUID file contains another body.
                        // Keep v1's source on the original identity and recover the file as a copy.
                        var copy = note
                        copy.id = UUID()
                        copy.markdown = externalSource
                        copy.isDetached = false
                        copy.frame = nil
                        loaded.append(copy)
                        newBaselines[copy.id] = bytes
                        migrationIDs.insert(copy.id)
                    } else {
                        note.markdown = externalSource
                    }
                    newBaselines[note.id] = bytes
                } else if legacy {
                    let bytes = Data(note.markdown.utf8)
                    guard bytes.count <= MarkdownTransfer.maximumNoteByteCount else { throw StateError.corrupt }
                    newBaselines[note.id] = bytes
                } else {
                    continue
                }
                loaded.append(note)
            }
            for id in files.keys.sorted(by: { $0.uuidString < $1.uuidString }) where !seen.contains(id) {
                guard let bytes = try LiveNoteIO.read(files[id]!, maximumBytes: MarkdownTransfer.maximumNoteByteCount)
                else { continue }
                let note = Note(id: id, markdown: try LiveNoteIO.source(bytes))
                loaded.append(note)
                newBaselines[id] = bytes
            }
            state.notes = loaded
            baselines = newBaselines
            baselineNotes = Dictionary(uniqueKeysWithValues: loaded.map { ($0.id, $0) })
            locations = files
            lastState = state
            expectsNotesDirectory = try LiveNoteIO.exists(notesDirectory)
            hasLoaded = true
            return state
        } catch let error as StateError {
            requiresRecovery = true
            throw error
        } catch {
            requiresRecovery = true
            throw StateError.corrupt
        }
    }

    public func save(_ state: AppState) async throws {
        guard !isClosed else { return }
        _ = try saveState(state, deletedNoteIDs: [])
    }

    public func saveMerging(_ state: AppState, deletedNoteIDs: Set<UUID> = []) async throws -> LiveSaveResult {
        guard !isClosed else { return LiveSaveResult(state: lastState ?? state) }
        return try saveState(state, deletedNoteIDs: deletedNoteIDs)
    }

    /// No suspension occurs between the final merged write and closing the writer.
    public func saveAndClose(_ state: AppState, deletedNoteIDs: Set<UUID> = []) async throws {
        guard !isClosed else { return }
        _ = try saveState(state, deletedNoteIDs: deletedNoteIDs)
        isClosed = true
    }

    /// Makes the writer usable again after `saveAndClose`, for a profile that is opened again.
    public func reopen() { isClosed = false }

    private func saveState(_ incoming: AppState, deletedNoteIDs: Set<UUID>) throws -> LiveSaveResult {
        guard !requiresRecovery else { throw StateError.recoveryRequired }
        if !hasLoaded { _ = try loadState() }
        guard incoming.schemaVersion == AppState.currentVersion else {
            throw StateError.unsupportedVersion(incoming.schemaVersion)
        }
        var result = incoming
        var conflictIDs: [UUID] = []
        var externallyDeletedIDs: [UUID] = []
        var pendingRetained = retainedNotes
        var pendingAdoptions = unacknowledgedAdoptions
        var pendingDeletions = deletionBaselines
        let incomingIDs = Set(incoming.notes.map(\.id))
        guard incomingIDs.count == incoming.notes.count else { throw StateError.corrupt }
        for id in incomingIDs { pendingRetained.removeValue(forKey: id) }
        for id in deletedNoteIDs { pendingRetained.removeValue(forKey: id) }
        let removedIDs = Set(baselineNotes.keys).subtracting(incomingIDs).subtracting(pendingRetained.keys)
            .union(deletedNoteIDs)
        for id in removedIDs { pendingAdoptions.removeValue(forKey: id) }
        var candidates = incoming.notes.filter { !deletedNoteIDs.contains($0.id) }
        candidates.append(contentsOf: pendingRetained.values.sorted { $0.id.uuidString < $1.id.uuidString })
        let currentFiles: [UUID: URL]
        var diskData: [UUID: Data] = [:]
        do {
            let directoryExists = try LiveNoteIO.exists(notesDirectory)
            if expectsNotesDirectory && !directoryExists { throw StateError.unreadable }
            currentFiles = try LiveNoteIO.files(in: notesDirectory)
            // Validate every managed file before writing any metadata or source.
            for (id, file) in currentFiles {
                if let data = try LiveNoteIO.read(file, maximumBytes: MarkdownTransfer.maximumNoteByteCount) {
                    _ = try LiveNoteIO.source(data)
                    diskData[id] = data
                }
            }
        } catch {
            requiresRecovery = true
            throw (error as? StateError) ?? StateError.unreadable
        }
        let candidateIDs = Set(candidates.map(\.id))
        for id in currentFiles.keys.sorted(by: { $0.uuidString < $1.uuidString })
        where !candidateIDs.contains(id) && !removedIDs.contains(id) {
            guard let data = diskData[id] else { continue }
            let note = Note(id: id, markdown: try LiveNoteIO.source(data))
            candidates.append(note)
            pendingRetained[id] = note
        }
        var merged: [Note] = []
        let now = Date.now
        for var note in candidates {
            let originalLocal = Data(note.markdown.utf8)
            var local = originalLocal
            let priorAdoption = pendingAdoptions[note.id]
            if let adoption = priorAdoption {
                if local == Data(adoption.note.markdown.utf8) {
                    pendingAdoptions.removeValue(forKey: note.id)
                } else if local == adoption.caller {
                    // This caller still holds the pre-adoption snapshot (including a quit capture).
                    note.markdown = adoption.note.markdown
                    local = Data(note.markdown.utf8)
                } else {
                    // A genuinely new local edit raced the UI's adoption acknowledgement.
                    var copy = adoption.note
                    copy.id = UUID()
                    copy.createdAt = now
                    copy.updatedAt = now
                    copy.isDetached = false
                    copy.frame = nil
                    merged.append(copy)
                    pendingRetained[copy.id] = copy
                    conflictIDs.append(copy.id)
                    pendingAdoptions.removeValue(forKey: note.id)
                }
            }
            guard local.count <= MarkdownTransfer.maximumNoteByteCount else { throw StateError.unwritable }
            let baseline = baselines[note.id] ?? pendingDeletions[note.id]
            var disk = diskData[note.id]
            if disk == nil, migrationSource != nil, migrationIDs.contains(note.id) { disk = baseline }
            if let baseline {
                if disk == nil {
                    if local == baseline {
                        externallyDeletedIDs.append(note.id)
                        pendingDeletions[note.id] = baseline
                        pendingRetained.removeValue(forKey: note.id)
                        pendingAdoptions.removeValue(forKey: note.id)
                        continue
                    }
                    // The external file was deleted while this note had unsaved edits. Keep those edits.
                    conflictIDs.append(note.id)
                } else if disk != baseline, let disk {
                    if local == baseline {
                        note.markdown = try LiveNoteIO.source(disk)
                        note.updatedAt = now
                        let caller = priorAdoption?.caller == originalLocal ? priorAdoption!.caller : originalLocal
                        pendingAdoptions[note.id] = SourceAdoption(caller: caller, note: note)
                    } else if local != disk {
                        var copy = note
                        copy.id = UUID()
                        copy.markdown = try LiveNoteIO.source(disk)
                        copy.createdAt = now
                        copy.updatedAt = now
                        copy.isDetached = false
                        copy.frame = nil
                        merged.append(copy)
                        pendingRetained[copy.id] = copy
                        conflictIDs.append(copy.id)
                    }
                }
            } else if let disk, disk != local {
                var copy = note
                copy.id = UUID()
                copy.markdown = try LiveNoteIO.source(disk)
                copy.createdAt = now
                copy.updatedAt = now
                copy.isDetached = false
                copy.frame = nil
                merged.append(copy)
                pendingRetained[copy.id] = copy
                conflictIDs.append(copy.id)
            }
            pendingDeletions.removeValue(forKey: note.id)
            merged.append(note)
        }
        for id in pendingDeletions.keys where !incomingIDs.contains(id) { pendingDeletions.removeValue(forKey: id) }
        result.notes = merged
        var metadata = result
        for index in metadata.notes.indices { metadata.notes[index].markdown = "" }
        let indexData: Data
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            indexData = try encoder.encode(
                DiskState(metadata: metadata, notesDirectoryName: notesDirectory.lastPathComponent))
            guard indexData.count <= LiveNoteIO.maximumIndexBytes else { throw StateError.unwritable }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            _ = try decoder.decode(DiskState.self, from: indexData)
        } catch { throw StateError.unwritable }
        do {
            try LiveNoteIO.ensureDirectory(url.deletingLastPathComponent())
            try LiveNoteIO.ensureDirectory(notesDirectory)
            if let migrationSource, migrationBackup == nil {
                let backup = url.appendingPathExtension("v1-\(UUID().uuidString).backup")
                try LiveNoteIO.write(migrationSource, to: backup, replace: false)
                migrationBackup = backup
            }
            for note in merged {
                let data = Data(note.markdown.utf8)
                // Skip unchanged files, preserving external editor replacement/mtime information.
                let target = currentFiles[note.id] ?? noteFileURL(id: note.id)
                if diskData[note.id] != data {
                    try LiveNoteIO.write(data, to: target, expectedData: diskData[note.id], checkExpected: true)
                }
            }
            try LiveNoteIO.write(indexData, to: url)
            // Deletions are last: a failed metadata write never destroys note source.
            for id in removedIDs {
                if let file = currentFiles[id] { try LiveNoteIO.remove(file) }
            }
        } catch { throw StateError.unwritable }
        baselines = Dictionary(uniqueKeysWithValues: merged.map { ($0.id, Data($0.markdown.utf8)) })
        baselineNotes = Dictionary(uniqueKeysWithValues: merged.map { ($0.id, $0) })
        locations = currentFiles
        retainedNotes = pendingRetained
        unacknowledgedAdoptions = pendingAdoptions
        deletionBaselines = pendingDeletions
        migrationSource = nil
        migrationIDs = []
        lastState = result
        expectsNotesDirectory = true
        return LiveSaveResult(state: result, conflictNoteIDs: conflictIDs, externallyDeletedIDs: externallyDeletedIDs)
    }

    private static func validDirectoryName(_ name: String) -> Bool {
        if name == "notes" { return true }
        guard name.hasPrefix("notes-") else { return false }
        let identifier = String(name.dropFirst(6))
        return identifier.count == 36 && UUID(uuidString: identifier) != nil
    }

    /// Publishes a fully written replacement folder through one atomic index rename.
    /// The previous index and source folder remain available as pre-restore backups.
    public func restore(_ state: AppState) async throws -> LiveSaveResult {
        guard state.schemaVersion == AppState.currentVersion else {
            throw StateError.unsupportedVersion(state.schemaVersion)
        }
        guard Set(state.notes.map(\.id)).count == state.notes.count,
            state.notes.allSatisfy({ $0.markdown.utf8.count <= MarkdownTransfer.maximumNoteByteCount })
        else {
            throw StateError.corrupt
        }
        var metadata = state
        for index in metadata.notes.indices { metadata.notes[index].markdown = "" }
        let newDirectory = url.deletingLastPathComponent()
            .appendingPathComponent("notes-\(UUID().uuidString)", isDirectory: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data: Data
        do {
            try state.appearance.validated()
            data = try encoder.encode(DiskState(metadata: metadata, notesDirectoryName: newDirectory.lastPathComponent))
            guard data.count <= LiveNoteIO.maximumIndexBytes else { throw StateError.unwritable }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            _ = try decoder.decode(DiskState.self, from: data)
        } catch { throw StateError.unwritable }
        var committed = false
        defer { if !committed { try? FileManager.default.removeItem(at: newDirectory) } }
        do {
            try LiveNoteIO.ensureDirectory(url.deletingLastPathComponent())
            try LiveNoteIO.ensureDirectory(newDirectory)
            for note in state.notes {
                try LiveNoteIO.write(
                    Data(note.markdown.utf8),
                    to: newDirectory.appendingPathComponent("\(note.id.uuidString).md"), replace: false)
            }
            if let oldIndex = try LiveNoteIO.read(url, maximumBytes: LiveNoteIO.maximumIndexBytes) {
                let backup = url.appendingPathExtension("before-restore-\(UUID().uuidString)")
                try LiveNoteIO.write(oldIndex, to: backup, replace: false)
            }
            try LiveNoteIO.write(data, to: url)
            committed = true
        } catch { throw (error as? StateError) ?? StateError.unwritable }
        notesDirectory = newDirectory
        expectsNotesDirectory = true
        baselines = Dictionary(uniqueKeysWithValues: state.notes.map { ($0.id, Data($0.markdown.utf8)) })
        baselineNotes = Dictionary(uniqueKeysWithValues: state.notes.map { ($0.id, $0) })
        locations = Dictionary(
            uniqueKeysWithValues: state.notes.map {
                ($0.id, newDirectory.appendingPathComponent("\($0.id.uuidString).md"))
            })
        retainedNotes = [:]
        unacknowledgedAdoptions = [:]
        deletionBaselines = [:]
        migrationSource = nil
        migrationIDs = []
        migrationBackup = nil
        requiresRecovery = false
        hasLoaded = true
        isClosed = false
        lastState = state
        return LiveSaveResult(state: state)
    }

    /// Explicit recovery preserves both the index and managed Markdown directory before starting fresh.
    @discardableResult public func recoverByBackingUp() async throws -> URL? {
        let suffix = "backup-\(UUID().uuidString)"
        var backup: URL?
        var movedIndex = false
        do {
            if try LiveNoteIO.exists(url) {
                let target = url.appendingPathExtension(suffix)
                try FileManager.default.moveItem(at: url, to: target)
                backup = target
                movedIndex = true
            }
            if try LiveNoteIO.exists(notesDirectory) {
                try FileManager.default.moveItem(at: notesDirectory, to: notesDirectory.appendingPathExtension(suffix))
            }
        } catch {
            if movedIndex, let backup { try? FileManager.default.moveItem(at: backup, to: url) }
            throw StateError.recoveryFailed
        }
        requiresRecovery = false
        hasLoaded = true
        baselines = [:]
        baselineNotes = [:]
        locations = [:]
        retainedNotes = [:]
        unacknowledgedAdoptions = [:]
        deletionBaselines = [:]
        migrationSource = nil
        migrationIDs = []
        migrationBackup = nil
        lastState = AppState()
        expectsNotesDirectory = false
        return backup
    }
}
