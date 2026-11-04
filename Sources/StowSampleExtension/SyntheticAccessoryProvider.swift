import StowExtensionSDK

/// An optional example with no network access, background timers, or host-state dependencies.
public struct SyntheticAccessoryProvider: AccessoryProvider {
    public init() {}
    public let descriptor = AccessoryDescriptor(
        id: "org.stow.sample", name: "Sample accessory", supportedSlots: [.boardAccessory, .noteAccessory]
    )

    public func snapshot(for request: AccessoryRequest) async throws -> AccessorySnapshot {
        AccessorySnapshot(
            primaryText: "Sample accessory", secondaryText: "native, optional, portable",
            systemImage: "shippingbox", tone: .neutral)
    }
}
