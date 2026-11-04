import Foundation
import StowExtensionSDK

public struct InProcessAdapter: AccessoryProvider {
    private let provider: any AccessoryProvider
    public var descriptor: AccessoryDescriptor { provider.descriptor }
    public init(_ provider: any AccessoryProvider) { self.provider = provider }
    public func snapshot(for request: AccessoryRequest) async throws -> AccessorySnapshot {
        try await provider.snapshot(for: request)
    }
}

/// Exercises the complete serialized boundary without pretending to launch or sandbox a process.
/// A future process transport can send these same request and response JSON values.
public struct JSONRoundTripAdapter: AccessoryProvider {
    private let provider: any AccessoryProvider
    public var descriptor: AccessoryDescriptor { provider.descriptor }
    public init(_ provider: any AccessoryProvider) { self.provider = provider }
    public func snapshot(for request: AccessoryRequest) async throws -> AccessorySnapshot {
        let decodedRequest = try JSONDecoder().decode(AccessoryRequest.self, from: JSONEncoder().encode(request))
        let snapshot = try await provider.snapshot(for: decodedRequest)
        return try JSONDecoder().decode(AccessorySnapshot.self, from: JSONEncoder().encode(snapshot))
    }
}
