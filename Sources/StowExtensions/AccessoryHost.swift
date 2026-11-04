import Foundation
import StowExtensionSDK

public enum AccessoryFailure: String, Codable, Equatable, Sendable {
    case disabled, unavailable, unsupportedVersion, unsupportedSlot, invalidDescriptor
    case invalidSnapshot, providerFailed, timedOut, cancelled

    public var message: String {
        switch self {
        case .disabled: "Accessory is disabled."
        case .unavailable: "Accessory is not installed."
        case .unsupportedVersion: "Accessory requires a different API version."
        case .unsupportedSlot: "Accessory does not support this location."
        case .invalidDescriptor: "Accessory registration is invalid."
        case .invalidSnapshot: "Accessory returned an invalid display value."
        case .providerFailed: "Accessory could not refresh."
        case .timedOut: "Accessory took too long to respond."
        case .cancelled: "Accessory refresh was cancelled."
        }
    }
}

public struct AccessoryResult: Equatable, Sendable {
    public var snapshot: AccessorySnapshot?
    public var error: AccessoryFailure?
    public var isCached: Bool

    public init(snapshot: AccessorySnapshot? = nil, error: AccessoryFailure? = nil, isCached: Bool = false) {
        self.snapshot = snapshot
        self.error = error
        self.isCached = isCached
    }
}

/// Statically linked modules are trusted code. This registry is not a sandbox.
public struct AccessoryRegistry: Sendable {
    public let descriptors: [String: AccessoryDescriptor]
    public let failures: [String: AccessoryFailure]
    let providers: [String: any AccessoryProvider]

    public init(providers: [any AccessoryProvider]) {
        var registered: [String: any AccessoryProvider] = [:]
        var descriptors: [String: AccessoryDescriptor] = [:]
        var failures: [String: AccessoryFailure] = [:]
        var seen = Set<String>()
        for provider in providers {
            let descriptor = provider.descriptor
            let id = descriptor.id
            let failure: AccessoryFailure?
            if !seen.insert(id).inserted {
                failure = .invalidDescriptor
            } else if descriptor.apiVersion != 1 {
                failure = .unsupportedVersion
            } else if id.isEmpty || id.utf8.count > 255 || descriptor.name.isEmpty || descriptor.name.utf8.count > 256
                || descriptor.supportedSlots.isEmpty
            {
                failure = .invalidDescriptor
            } else {
                failure = nil
            }
            if let failure {
                failures[id] = failure
                registered[id] = nil
                descriptors[id] = nil
            } else {
                registered[id] = provider
                descriptors[id] = descriptor
            }
        }
        self.providers = registered
        self.descriptors = descriptors
        self.failures = failures
    }
}

/// Cancels cooperative provider work on disable, replacement, timeout, or caller cancellation.
/// A trusted in-process provider must honor cancellation; an uncooperative task cannot be killed.
public actor AccessoryHost {
    public nonisolated let registry: AccessoryRegistry
    private let timeout: Duration
    private struct Key: Hashable {
        var moduleID: String
        var instanceID: UUID
    }
    private struct Running {
        var token: UUID
        var work: Task<Void, Never>
        var timer: Task<Void, Never>
        var continuation: CheckedContinuation<AccessoryResult, Never>
    }
    private var running: [Key: Running] = [:]
    private var cache: [Key: AccessorySnapshot] = [:]

    public init(providers: [any AccessoryProvider], timeout: Duration = .seconds(10)) {
        self.registry = AccessoryRegistry(providers: providers)
        self.timeout = timeout
    }

    public func descriptors() -> [String: AccessoryDescriptor] { registry.descriptors }

    public func run(_ request: AccessoryRequest, moduleID: String, enabled: Bool) async -> AccessoryResult {
        let key = Key(moduleID: moduleID, instanceID: request.instanceID)
        if !enabled {
            stop(key, failure: .disabled)
            return AccessoryResult(error: .disabled)
        }
        if let failure = registry.failures[moduleID] { return failureResult(key, failure) }
        guard let provider = registry.providers[moduleID] else { return failureResult(key, .unavailable) }
        guard registry.descriptors[moduleID]?.supportedSlots.contains(request.slot) == true else {
            return failureResult(key, .unsupportedSlot)
        }
        stop(key, failure: .cancelled)
        if Task.isCancelled { return AccessoryResult(error: .cancelled) }
        let token = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let work = Task { [weak self] in
                    do {
                        let snapshot = try await provider.snapshot(for: request)
                        guard !Task.isCancelled else { return }
                        await self?.finish(key, token: token, snapshot: snapshot, failure: nil)
                    } catch is CancellationError {
                        await self?.finish(key, token: token, snapshot: nil, failure: .cancelled)
                    } catch {
                        await self?.finish(key, token: token, snapshot: nil, failure: .providerFailed)
                    }
                }
                let timer = Task { [weak self, timeout] in
                    do {
                        try await Task.sleep(for: timeout)
                        await self?.finish(key, token: token, snapshot: nil, failure: .timedOut)
                    } catch {
                        // Cancellation ends the timer.
                    }
                }
                running[key] = Running(token: token, work: work, timer: timer, continuation: continuation)
            }
        } onCancel: {
            Task { await self.cancel(key, token: token) }
        }
    }

    public func cancel(instanceID: UUID, moduleID: String) {
        stop(Key(moduleID: moduleID, instanceID: instanceID), failure: .cancelled)
    }

    public func cachedSnapshot(instanceID: UUID, moduleID: String) -> AccessorySnapshot? {
        cache[Key(moduleID: moduleID, instanceID: instanceID)]
    }

    private func cancel(_ key: Key, token: UUID) {
        guard running[key]?.token == token else { return }
        stop(key, failure: .cancelled)
    }

    private func stop(_ key: Key, failure: AccessoryFailure) {
        guard let active = running.removeValue(forKey: key) else { return }
        active.work.cancel()
        active.timer.cancel()
        // Disabled/cancelled work must not show an old or late value.
        active.continuation.resume(returning: AccessoryResult(error: failure))
    }

    private func finish(_ key: Key, token: UUID, snapshot: AccessorySnapshot?, failure: AccessoryFailure?) {
        guard let active = running[key], active.token == token else { return }
        running[key] = nil
        active.work.cancel()
        active.timer.cancel()
        if let snapshot {
            guard Self.valid(snapshot) else {
                active.continuation.resume(returning: failureResult(key, .invalidSnapshot))
                return
            }
            cache[key] = snapshot
            active.continuation.resume(returning: AccessoryResult(snapshot: snapshot))
        } else {
            active.continuation.resume(returning: failureResult(key, failure ?? .providerFailed))
        }
    }

    private func failureResult(_ key: Key, _ failure: AccessoryFailure) -> AccessoryResult {
        let snapshot = cache[key]
        return AccessoryResult(snapshot: snapshot, error: failure, isCached: snapshot != nil)
    }

    private static func valid(_ snapshot: AccessorySnapshot) -> Bool {
        !snapshot.primaryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && snapshot.primaryText.utf8.count <= 512 && (snapshot.secondaryText?.utf8.count ?? 0) <= 2_048
            && (snapshot.systemImage?.utf8.count ?? 0) <= 128
    }
}
