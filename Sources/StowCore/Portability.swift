import Foundation

public enum PortabilityError: Error, LocalizedError, Equatable, Sendable {
    case backupTooLarge
    case noteTooLarge
    case unsupportedBackupVersion(Int)
    case unsupportedStateVersion(Int)
    case invalidBackup
    case invalidUTF8

    public var errorDescription: String? {
        switch self {
        case .backupTooLarge: return "The backup exceeds the 64 MiB size limit."
        case .noteTooLarge: return "The Markdown file exceeds the 8 MiB size limit."
        case .unsupportedBackupVersion(let version): return "Backup format version \(version) is not supported."
        case .unsupportedStateVersion(let version): return "Saved state version \(version) is not supported."
        case .invalidBackup: return "The backup is incomplete or invalid. No saved data has been changed."
        case .invalidUTF8: return "The Markdown file must contain valid UTF-8 text."
        }
    }
}

extension AppState {
    /// Settings that describe this Mac rather than the portable setup, taken from `local`.
    ///
    /// Backups are written with `AppState()` defaults in these fields, and a restore keeps the values
    /// this Mac already uses. A received backup therefore cannot choose which program Stow launches
    /// or turn GitHub access or accessories on, and backups never carry a machine-specific path.
    public func keepingMachineLocalSettings(from local: AppState) -> AppState {
        var result = self
        // Only the person at this Mac turns things on; a backup never does.
        result.ghExecutablePath = local.ghExecutablePath
        result.githubEnabled = local.githubEnabled
        // Accessory configuration travels, but each one comes back off until it is enabled here.
        for index in result.extensionInstances.indices { result.extensionInstances[index].isEnabled = false }
        return result
    }
}

/// An in-memory snapshot codec. Reading, writing, and explicit restore decisions belong to the host.
public enum StowBackup {
    public static let formatVersion = 1
    public static let maximumByteCount = 64 * 1024 * 1024

    private struct Envelope: Codable {
        var formatVersion: Int
        var createdAt: Date
        var state: AppState
    }

    public static func encode(_ snapshot: AppState, createdAt: Date = .now) throws -> Data {
        guard snapshot.schemaVersion == AppState.currentVersion else {
            throw PortabilityError.unsupportedStateVersion(snapshot.schemaVersion)
        }
        let state = snapshot.keepingMachineLocalSettings(from: AppState())
        try validateNotes(state)
        guard createdAt.timeIntervalSinceReferenceDate.isFinite else { throw PortabilityError.invalidBackup }
        let data: Data
        do {
            try state.appearance.validated()
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            data = try encoder.encode(Envelope(formatVersion: formatVersion, createdAt: createdAt, state: state))
        } catch { throw PortabilityError.invalidBackup }
        guard data.count <= maximumByteCount else { throw PortabilityError.backupTooLarge }
        _ = try decode(data)
        return data
    }

    private static func validateNotes(_ state: AppState) throws {
        guard Set(state.notes.map(\.id)).count == state.notes.count else { throw PortabilityError.invalidBackup }
        let references = state.pins + state.notes.compactMap(\.pullRequest) + state.pullRequests.map(\.reference)
        guard references.allSatisfy(validReference) else { throw PortabilityError.invalidBackup }
        guard state.notes.allSatisfy({ $0.markdown.utf8.count <= MarkdownTransfer.maximumNoteByteCount }) else {
            throw PortabilityError.noteTooLarge
        }
    }

    private static func validReference(_ reference: PullRequestReference) -> Bool {
        func alphanumeric(_ scalar: Unicode.Scalar) -> Bool {
            (48...57).contains(scalar.value) || (65...90).contains(scalar.value) || (97...122).contains(scalar.value)
        }
        guard reference.host.lowercased() == "github.com", reference.number > 0,
            let first = reference.owner.unicodeScalars.first, alphanumeric(first),
            reference.owner.unicodeScalars.allSatisfy({ alphanumeric($0) || $0 == "-" }),
            !reference.repository.isEmpty, reference.repository != ".", reference.repository != "..",
            reference.repository.unicodeScalars.allSatisfy({ alphanumeric($0) || $0 == "-" || $0 == "_" || $0 == "." })
        else {
            return false
        }
        return true
    }

    public static func decode(_ data: Data) throws -> AppState {
        guard data.count <= maximumByteCount else { throw PortabilityError.backupTooLarge }
        do {
            // Inspect versions before decoding today's state shape so newer schemas are reported accurately.
            struct FormatHeader: Decodable { var formatVersion: Int }
            struct StateHeader: Decodable {
                struct Version: Decodable { var schemaVersion: Int }
                var state: Version
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let format = try decoder.decode(FormatHeader.self, from: data).formatVersion
            guard format == formatVersion else { throw PortabilityError.unsupportedBackupVersion(format) }
            let schema = try decoder.decode(StateHeader.self, from: data).state.schemaVersion
            guard schema == AppState.currentVersion else { throw PortabilityError.unsupportedStateVersion(schema) }
            let state = try decoder.decode(Envelope.self, from: data).state
            try validateNotes(state)
            return state
        } catch let error as PortabilityError { throw error } catch { throw PortabilityError.invalidBackup }
    }
}

public struct MarkdownFile: Equatable, Sendable {
    public var filename: String
    public var source: String

    public init(filename: String, source: String) {
        self.filename = filename
        self.source = source
    }
}

public enum MarkdownTransfer {
    public static let maximumNoteByteCount = 8 * 1024 * 1024

    /// Exports source only. No metadata, frontmatter, normalization, or newline conversion is inserted.
    public static func files(for notes: [Note]) -> [MarkdownFile] {
        var usedNames = Set<String>()
        return notes.map { note in
            let title = safeTitle(note.markdown)
            let identifier = note.id.uuidString.lowercased()
            var filename = "\(title)-\(identifier).md"
            var duplicate = 2
            while !usedNames.insert(filename).inserted {
                filename = "\(title)-\(duplicate)-\(identifier).md"
                duplicate += 1
            }
            return MarkdownFile(filename: filename, source: note.markdown)
        }
    }

    /// Strict decoding preserves UTF-8 source bytes, including a leading BOM and original newline style.
    public static func decodeNote(_ data: Data) throws -> String {
        guard data.count <= maximumNoteByteCount else { throw PortabilityError.noteTooLarge }
        let source = String(decoding: data, as: UTF8.self)
        guard Data(source.utf8) == data else { throw PortabilityError.invalidUTF8 }
        return source
    }

    private static func safeTitle(_ source: String) -> String {
        let firstLine =
            source.split(whereSeparator: \.isNewline)
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? ""
        var title = ""
        for scalar in firstLine.unicodeScalars {
            if (48...57).contains(scalar.value) || (65...90).contains(scalar.value) || (97...122).contains(scalar.value)
            {
                title += String(scalar).lowercased()
            } else if !title.isEmpty && title.last != "-" {
                title += "-"
            }
            if title.count >= 48 { break }
        }
        title = title.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return title.isEmpty ? "note" : title
    }
}
