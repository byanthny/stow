import Foundation

public enum ProfileError: Error, Equatable, Sendable {
    case invalidIdentity, invalidIndex, newerIndex(Int), indexNeedsReset
    case emptyName, duplicateName, invalidColor, inUse, lastProfile, notFound, unwritable
}

/// A profile's name and color, stored in the profile folder as `identity.json`.
/// Folders can be copied in from elsewhere, so decoding treats the bytes as untrusted.
public struct ProfileIdentity: Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var color: String

    public static let filename = "identity.json"
    public static let maximumBytes = 16 * 1024
    public static let maximumNameLength = 80

    public init(id: UUID, name: String, color: String) {
        self.id = id
        self.name = name
        self.color = color
    }

    /// Removes control and bidirectional formatting characters, trims, and limits the length.
    /// Zero-width joiners stay so emoji sequences and some scripts render correctly.
    public static func sanitizedName(_ raw: String) -> String? {
        let kept = String.UnicodeScalarView(raw.unicodeScalars.filter { !isRemoved($0) })
        let trimmed = String(kept).trimmingCharacters(in: .whitespacesAndNewlines)
        let limited = String(trimmed.prefix(maximumNameLength))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return limited.isEmpty ? nil : limited
    }

    public static func isValidColor(_ hex: String) -> Bool {
        let bytes = Array(hex.utf8)
        guard bytes.count == 7, bytes[0] == UInt8(ascii: "#") else { return false }
        return bytes.dropFirst().allSatisfy {
            ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x46) || ($0 >= 0x61 && $0 <= 0x66)
        }
    }

    /// Decodes untrusted bytes. A non-nil `folderID` must match the identity's id.
    public static func decode(_ data: Data, folderID: UUID?) throws -> ProfileIdentity {
        guard data.count <= maximumBytes,
            var identity = try? JSONDecoder().decode(ProfileIdentity.self, from: data),
            folderID == nil || identity.id == folderID,
            let name = sanitizedName(identity.name),
            isValidColor(identity.color)
        else { throw ProfileError.invalidIdentity }
        identity.name = name
        return identity
    }

    private static func isRemoved(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x2028, 0x2029, 0x061C, 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069:
            return true
        default:
            return scalar.properties.generalCategory == .control
        }
    }
}

/// Which profiles exist and are open, stored beside the profile folders as `profiles.json`.
public struct ProfileIndex: Codable, Equatable, Sendable {
    public struct OpenProfile: Codable, Equatable, Sendable {
        public var id: UUID
        public var isHidden: Bool

        public init(id: UUID, isHidden: Bool) {
            self.id = id
            self.isHidden = isHidden
        }
    }

    public static let filename = "profiles.json"
    public static let currentVersion = 1
    public static let maximumBytes = 256 * 1024

    public var schemaVersion = currentVersion
    public var order: [UUID] = []
    public var open: [OpenProfile] = []
    public var lastActiveID: UUID?
    public var seenIDs: [UUID] = []
    public var alwaysShowProfileName = false

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, order, open, lastActiveID, seenIDs, alwaysShowProfileName
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        order = try container.decodeIfPresent([UUID].self, forKey: .order) ?? []
        open = try container.decodeIfPresent([OpenProfile].self, forKey: .open) ?? []
        lastActiveID = try container.decodeIfPresent(UUID.self, forKey: .lastActiveID)
        seenIDs = try container.decodeIfPresent([UUID].self, forKey: .seenIDs) ?? []
        alwaysShowProfileName =
            try container.decodeIfPresent(Bool.self, forKey: .alwaysShowProfileName) ?? false
    }

    /// Decodes untrusted bytes. A newer version is reported before its fields are read,
    /// so a future shape never counts as corrupt.
    public static func decode(_ data: Data) throws -> ProfileIndex {
        struct VersionProbe: Decodable { var schemaVersion: Int }
        guard data.count <= maximumBytes,
            let probe = try? JSONDecoder().decode(VersionProbe.self, from: data),
            probe.schemaVersion >= 1
        else { throw ProfileError.invalidIndex }
        guard probe.schemaVersion <= currentVersion else {
            throw ProfileError.newerIndex(probe.schemaVersion)
        }
        guard let index = try? JSONDecoder().decode(ProfileIndex.self, from: data) else {
            throw ProfileError.invalidIndex
        }
        return index
    }
}
