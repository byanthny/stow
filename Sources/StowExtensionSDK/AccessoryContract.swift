import Foundation

/// JSON data shared with an accessory. This contract has no dependency on the host UI or state.
public enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            self = .array(try container.decode([JSONValue].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

public enum AccessorySlot: String, Codable, Sendable, CaseIterable {
    case boardAccessory
    case noteAccessory
}

public struct AccessoryDescriptor: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var apiVersion: Int
    public var supportedSlots: [AccessorySlot]

    public init(id: String, name: String, apiVersion: Int = 1, supportedSlots: [AccessorySlot]) {
        self.id = id
        self.name = name
        self.apiVersion = apiVersion
        self.supportedSlots = supportedSlots
    }
}

public struct AccessoryRequest: Codable, Equatable, Sendable {
    public var instanceID: UUID
    public var slot: AccessorySlot
    public var requestedAt: Date
    public var configurationVersion: Int
    public var configuration: JSONValue

    public init(
        instanceID: UUID, slot: AccessorySlot, requestedAt: Date = .now,
        configurationVersion: Int = 1, configuration: JSONValue = .object([:])
    ) {
        self.instanceID = instanceID
        self.slot = slot
        self.requestedAt = requestedAt
        self.configurationVersion = configurationVersion
        self.configuration = configuration
    }
}

public enum AccessoryTone: String, Codable, Equatable, Sendable, CaseIterable {
    case neutral, success, warning, error
}

public struct AccessorySnapshot: Codable, Equatable, Sendable {
    public var primaryText: String
    public var secondaryText: String?
    public var systemImage: String?
    public var tone: AccessoryTone

    public init(
        primaryText: String, secondaryText: String? = nil,
        systemImage: String? = nil, tone: AccessoryTone = .neutral
    ) {
        self.primaryText = primaryText
        self.secondaryText = secondaryText
        self.systemImage = systemImage
        self.tone = tone
    }
}

/// A trusted provider supplies values; the host alone decides how to render them.
public protocol AccessoryProvider: Sendable {
    var descriptor: AccessoryDescriptor { get }
    func snapshot(for request: AccessoryRequest) async throws -> AccessorySnapshot
}
