# Accessory providers

Accessories provide small display values for `boardAccessory` and `noteAccessory` slots. They are optional and independent of notes or GitHub. The bundled provider, `org.stow.sample`, is disabled until enabled from Settings or a note’s actions menu.

## Contract

Implement `AccessoryProvider` from `StowExtensionSDK`:

```swift
import StowExtensionSDK

public struct ExampleProvider: AccessoryProvider {
    public init() {}

    public let descriptor = AccessoryDescriptor(
        id: "org.example.status",
        name: "Example status",
        apiVersion: 1,
        supportedSlots: [.boardAccessory]
    )

    public func snapshot(for request: AccessoryRequest) async throws -> AccessorySnapshot {
        try Task.checkCancellation()
        return AccessorySnapshot(primaryText: "All quiet", tone: .neutral)
    }
}
```

A descriptor supplies a unique stable ID, name, supported slots, and API version. A request contains the instance ID, slot, request time, configuration version, and `JSONValue` configuration. A snapshot contains primary text, optional secondary text and system-image name, and a semantic tone. These are `Codable`, `Equatable`, and `Sendable` values. No host view, note text, credentials, or global app state is supplied.

The host validates registration and snapshot bounds. Primary text must be nonempty after trimming and at most 512 UTF-8 bytes. Secondary text is limited to 2,048 bytes; a system-image name to 128 bytes. Descriptor IDs and names have bounds too. Treat configuration as versioned input and validate it before use.

## Host behavior

`AccessoryHost` rejects disabled, missing, duplicate, invalid, unsupported-version, or unsupported-slot registrations before calling a provider. It cancels replaced work, caller cancellation, disabled instances, and work beyond the configured timeout. Results use a per-module, per-instance cache. Failures may retain the last matching snapshot with a cached marker; cancelled and disabled work cannot publish a late value.

Providers must honor cooperative cancellation and avoid unbounded work. A timeout can stop the host from waiting, but it cannot kill uncooperative in-process code. Use sanitized host error messages rather than exposing arbitrary provider errors.

Unavailable providers retain their saved instance configuration. Disabling or removing an accessory must leave notes and the rest of the board usable.

## Portability and trust

`InProcessAdapter` delegates directly. `JSONRoundTripAdapter` encodes and decodes requests and snapshots around a call to the same provider. Tests cover the same sample through both adapters. This demonstrates a portable data contract; it is not process isolation.

Current modules are statically linked trusted Swift code running with the app’s permissions. Stow is not sandboxed. Do not load an untrusted provider on the assumption that the contract restricts what its implementation can access.

Installable packaging, discovery, signing policy, process transport, and permission isolation are future design work. API version 1 does not guarantee Swift binary compatibility or drop-in plugin loading. Keep provider logic independent of the macOS host so another host can reuse the source and serialized values.
