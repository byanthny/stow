import Foundation

public enum ProfileError: Error, Equatable, Sendable {
    case invalidIdentity, invalidIndex, newerIndex(Int), indexNeedsReset
    case emptyName, duplicateName, invalidColor, invalidIcon, inUse, lastProfile, notFound, unwritable
}

/// A profile's optional icon: an SF Symbol name or a single emoji, stored as `{"symbol": …}` or `{"emoji": …}`.
public enum ProfileIcon: Codable, Equatable, Sendable {
    case symbol(String)
    case emoji(String)

    public static let maximumSymbolNameLength = 64
    public static let maximumEmojiBytes = 32

    /// The icon when it is well formed, else nil. A symbol name is 1 to 64 ASCII letters, digits, and dots. An emoji
    /// is exactly one character of at most 32 UTF-8 bytes, with at least one emoji scalar. Whether macOS has a
    /// symbol of that name is for the app to check.
    public static func validated(_ icon: ProfileIcon) -> ProfileIcon? {
        switch icon {
        case .symbol(let name):
            let bytes = Array(name.utf8)
            guard (1...maximumSymbolNameLength).contains(bytes.count),
                bytes.allSatisfy({ isASCIIAlphanumeric($0) || $0 == UInt8(ascii: ".") })
            else { return nil }
        case .emoji(let text):
            guard text.count == 1, text.utf8.count <= maximumEmojiBytes,
                text.unicodeScalars.contains(where: \.properties.isEmoji)
            else { return nil }
        }
        return icon
    }

    private static func isASCIIAlphanumeric(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
    }

    private enum CodingKeys: String, CodingKey {
        case symbol, emoji
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let symbol = try container.decodeIfPresent(String.self, forKey: .symbol)
        let emoji = try container.decodeIfPresent(String.self, forKey: .emoji)
        switch (symbol, emoji) {
        case (let name?, nil): self = .symbol(name)
        case (nil, let text?): self = .emoji(text)
        default:
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "An icon is one symbol or one emoji."))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .symbol(let name): try container.encode(name, forKey: .symbol)
        case .emoji(let text): try container.encode(text, forKey: .emoji)
        }
    }
}

/// A profile's name, color, and optional icon, stored in the profile folder as `identity.json`.
/// Folders can be copied in from elsewhere, so decoding treats the bytes as untrusted.
public struct ProfileIdentity: Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var color: String
    /// An icon that is malformed reads as none, without rejecting the identity.
    public var icon: ProfileIcon?

    public static let filename = "identity.json"
    public static let maximumBytes = 16 * 1024
    public static let maximumNameLength = 80

    public init(id: UUID, name: String, color: String, icon: ProfileIcon? = nil) {
        self.id = id
        self.name = name
        self.color = color
        self.icon = icon
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, color, icon
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        color = try container.decode(String.self, forKey: .color)
        icon = (try? container.decodeIfPresent(ProfileIcon.self, forKey: .icon)).flatMap(ProfileIcon.validated)
    }

    /// Removes control, bidirectional formatting, and invisible characters, trims, and limits the length.
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
        case 0x00AD, 0x180E, 0x200B, 0x2060, 0xFEFF, 0x2028, 0x2029, 0x061C, 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069:
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
