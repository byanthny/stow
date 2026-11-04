import Foundation
import StowExtensionSDK
import StowExtensions
import StowSampleExtension
import Testing

private actor SpyProvider: AccessoryProvider {
    enum Mode: Sendable { case success, failure, oversized, waiting }
    struct PrivateFailure: Error {}
    nonisolated let descriptor: AccessoryDescriptor
    var mode: Mode = .success
    private(set) var calls = 0
    private(set) var cancellations = 0
    private var callWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []

    init(id: String = "test.spy", version: Int = 1, slots: [AccessorySlot] = [.boardAccessory]) {
        descriptor = AccessoryDescriptor(id: id, name: "Spy", apiVersion: version, supportedSlots: slots)
    }
    func setMode(_ mode: Mode) { self.mode = mode }
    func waitForCalls(_ target: Int) async {
        if calls >= target { return }
        await withCheckedContinuation { callWaiters.append((target, $0)) }
    }
    func waitForCancellation() async {
        if cancellations > 0 { return }
        await withCheckedContinuation { cancellationWaiters.append($0) }
    }
    func snapshot(for request: AccessoryRequest) async throws -> AccessorySnapshot {
        calls += 1
        let ready = callWaiters.filter { $0.0 <= calls }
        callWaiters.removeAll { $0.0 <= calls }
        for (_, waiter) in ready { waiter.resume() }
        switch mode {
        case .success: return AccessorySnapshot(primaryText: "Ready", secondaryText: "Safe value", tone: .success)
        case .failure: throw PrivateFailure()
        case .oversized: return AccessorySnapshot(primaryText: String(repeating: "x", count: 513))
        case .waiting:
            do { try await Task.sleep(for: .seconds(60)) } catch {
                cancellations += 1
                let waiters = cancellationWaiters
                cancellationWaiters = []
                for waiter in waiters { waiter.resume() }
                throw error
            }
            return AccessorySnapshot(primaryText: "Late")
        }
    }
}

private func request(instanceID: UUID = UUID(), slot: AccessorySlot = .boardAccessory) -> AccessoryRequest {
    AccessoryRequest(
        instanceID: instanceID, slot: slot, requestedAt: Date(timeIntervalSince1970: 123_456),
        configurationVersion: 7,
        configuration: .object([
            "future": .array([.bool(true), .number(42.5), .null, .string("portable")]),
            "nested": .object(["value": .number(-2)]),
        ]))
}

private actor CapturingProvider: AccessoryProvider {
    nonisolated let descriptor = AccessoryDescriptor(
        id: "test.capture", name: "Capture", supportedSlots: [.boardAccessory])
    private(set) var requests: [AccessoryRequest] = []
    func snapshot(for request: AccessoryRequest) async throws -> AccessorySnapshot {
        requests.append(request)
        return AccessorySnapshot(primaryText: "Configuration \(request.configurationVersion)")
    }
}

@Test func contractRoundTripsPlainJSON() throws {
    let original = request()
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(AccessoryRequest.self, from: data)
    #expect(decoded == original)
    let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let configuration = try #require(json["configuration"] as? [String: Any])
    #expect(configuration["future"] is [Any])
    #expect(json["noteID"] == nil)
    for tone in AccessoryTone.allCases {
        let snapshot = AccessorySnapshot(
            primaryText: "Hello", secondaryText: "World", systemImage: "shippingbox", tone: tone)
        #expect(try JSONDecoder().decode(AccessorySnapshot.self, from: JSONEncoder().encode(snapshot)) == snapshot)
    }
}

@Test func sampleAndAdaptersUseTheSamePortableContract() async throws {
    let provider = SyntheticAccessoryProvider()
    let direct = InProcessAdapter(provider)
    let serialized = JSONRoundTripAdapter(provider)
    #expect(direct.descriptor == serialized.descriptor)
    for slot in AccessorySlot.allCases {
        let value = request(slot: slot)
        let first = try await direct.snapshot(for: value)
        let second = try await serialized.snapshot(for: value)
        #expect(first == second)
        #expect(first.primaryText == "Sample accessory")
        #expect(first.secondaryText == "native, optional, portable")
        #expect(first.tone == .neutral)
    }
    let capture = CapturingProvider()
    let original = request()
    let capturedDirect = try await InProcessAdapter(capture).snapshot(for: original)
    let capturedSerialized = try await JSONRoundTripAdapter(capture).snapshot(for: original)
    #expect(capturedDirect == capturedSerialized)
    #expect(await capture.requests == [original, original])
}

@Test func disabledAndUnsupportedRequestsNeverInvokeProvider() async {
    let spy = SpyProvider()
    let host = AccessoryHost(providers: [spy])
    let disabled = await host.run(request(), moduleID: "test.spy", enabled: false)
    #expect(disabled.error == .disabled)
    #expect(disabled.snapshot == nil)
    let slot = await host.run(request(slot: .noteAccessory), moduleID: "test.spy", enabled: true)
    #expect(slot.error == .unsupportedSlot)
    let missing = await host.run(request(), moduleID: "test.missing", enabled: true)
    #expect(missing.error == .unavailable)
    #expect(await spy.calls == 0)
    let future = SpyProvider(id: "test.future", version: 2)
    let futureHost = AccessoryHost(providers: [future])
    let unsupported = await futureHost.run(request(), moduleID: "test.future", enabled: true)
    #expect(unsupported.error == .unsupportedVersion)
    #expect(await future.calls == 0)
    #expect(futureHost.registry.descriptors.isEmpty)
    let duplicateHost = AccessoryHost(providers: [spy, spy])
    #expect(duplicateHost.registry.failures["test.spy"] == .invalidDescriptor)
}

@Test func failuresKeepOnlyMatchingCachedSnapshotAndUseSafeMessages() async {
    let spy = SpyProvider()
    let other = SpyProvider(id: "test.other")
    await other.setMode(.failure)
    let host = AccessoryHost(providers: [spy, other])
    let value = request()
    let first = await host.run(value, moduleID: "test.spy", enabled: true)
    #expect(first.snapshot?.primaryText == "Ready")
    #expect(first.error == nil)
    #expect(!first.isCached)
    await spy.setMode(.failure)
    let failed = await host.run(value, moduleID: "test.spy", enabled: true)
    #expect(failed.snapshot == first.snapshot)
    #expect(failed.isCached)
    #expect(failed.error == .providerFailed)
    #expect(failed.error?.message == "Accessory could not refresh.")
    let unrelated = await host.run(request(), moduleID: "test.spy", enabled: true)
    #expect(unrelated.snapshot == nil)
    #expect(!unrelated.isCached)
    let otherModule = await host.run(value, moduleID: "test.other", enabled: true)
    #expect(otherModule.snapshot == nil)
    #expect(!otherModule.isCached)
    await spy.setMode(.oversized)
    let invalid = await host.run(value, moduleID: "test.spy", enabled: true)
    #expect(invalid.error == .invalidSnapshot)
    #expect(invalid.snapshot == first.snapshot)
    #expect(await host.cachedSnapshot(instanceID: value.instanceID, moduleID: "test.spy") == first.snapshot)
    let disabled = await host.run(value, moduleID: "test.spy", enabled: false)
    #expect(disabled.snapshot == nil)
}

@Test func timeoutCancelsProviderAndKeepsCachedSnapshot() async {
    let spy = SpyProvider()
    let host = AccessoryHost(providers: [spy], timeout: .milliseconds(30))
    let value = request()
    let first = await host.run(value, moduleID: "test.spy", enabled: true)
    await spy.setMode(.waiting)
    let result = await host.run(value, moduleID: "test.spy", enabled: true)
    #expect(result.error == .timedOut)
    #expect(result.isCached)
    #expect(result.snapshot == first.snapshot)
    await spy.waitForCancellation()
    #expect(await spy.cancellations == 1)
}

@Test func disablingRunningInstanceCancelsWithoutLateSnapshot() async {
    let spy = SpyProvider()
    await spy.setMode(.waiting)
    let host = AccessoryHost(providers: [spy])
    let value = request()
    let pending = Task { await host.run(value, moduleID: "test.spy", enabled: true) }
    await spy.waitForCalls(1)
    let disabled = await host.run(value, moduleID: "test.spy", enabled: false)
    #expect(disabled.error == .disabled)
    let result = await pending.value
    #expect(result.error == .disabled)
    await spy.waitForCancellation()
    #expect(await spy.calls == 1)
    #expect(await host.cachedSnapshot(instanceID: value.instanceID, moduleID: "test.spy") == nil)
}

@Test func callerCancellationStopsProvider() async {
    let spy = SpyProvider()
    await spy.setMode(.waiting)
    let host = AccessoryHost(providers: [spy])
    let value = request()
    let pending = Task { await host.run(value, moduleID: "test.spy", enabled: true) }
    await spy.waitForCalls(1)
    pending.cancel()
    let result = await pending.value
    #expect(result.error == .cancelled)
    await spy.waitForCancellation()
    #expect(await host.cachedSnapshot(instanceID: value.instanceID, moduleID: "test.spy") == nil)
}

@Test func replacementCancelsPreviousRefresh() async {
    let spy = SpyProvider()
    await spy.setMode(.waiting)
    let host = AccessoryHost(providers: [spy])
    let value = request()
    let pending = Task { await host.run(value, moduleID: "test.spy", enabled: true) }
    await spy.waitForCalls(1)
    await spy.setMode(.success)
    let replacement = await host.run(value, moduleID: "test.spy", enabled: true)
    #expect(replacement.snapshot?.primaryText == "Ready")
    let previous = await pending.value
    #expect(previous.error == .cancelled)
    await spy.waitForCancellation()
    #expect(await spy.calls == 2)
    #expect(await host.cachedSnapshot(instanceID: value.instanceID, moduleID: "test.spy") == replacement.snapshot)
}
