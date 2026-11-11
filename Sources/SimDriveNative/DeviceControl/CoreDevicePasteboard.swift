import ABIBridge
import AppKit

/// One item of a pasteboard: its types, and its text when it has any.
package struct PasteboardItemContents: Equatable, Sendable {
    package let types: [String]
    package let text: String?
}

/// A simulator's general pasteboard through CoreDevice, as `devicectl device pasteboard` reaches it.
@MainActor
package final class CoreDevicePasteboard {
    private static let feature = "com.apple.coredevice.feature.pasteboard"
    private static let capability = "PasteboardCapability"
    private static let pasteboardName = "general"

    private let current: @MainActor () async throws -> NativeSwiftValue
    private let replace: @MainActor (NativeSwiftValue) async throws -> Void
    private let capture: @MainActor (NSPasteboard) async throws -> NativeSwiftValue
    private let write: @MainActor (NativeSwiftValue, NSPasteboard) throws -> Void

    /// The simulator's pasteboard, or nil when it has none, as on tvOS. `remote` is only asked for when the guest has one.
    package static func open(guest: SimulatorGuest,
                             remote openRemote: @MainActor () async throws -> CoreDeviceRemote?) async throws -> CoreDevicePasteboard? {
        guard guest.hasService(feature), let remote = try await openRemote(), try remote.supports(feature) else { return nil }
        let implementation = try await remote.implementation(capability: capability, feature: feature)
        let failure = try await remote.errorSample()
        return try await remote.runtime.prepare { runtime in
            try await CoreDevicePasteboard(runtime: runtime, implementation: implementation, failure: failure)
        }
    }

    private init<Failure: Error>(runtime: ABIRuntime, implementation: NativeSwiftValue, failure: Failure) async throws {
        let snapshotType = try await runtime.resolve(.swift(.type("CoreDeviceUtilities.PasteboardSnapshot")))
        let policyType = try await runtime.resolve(.swift(.type("CoreDeviceUtilities.PasteboardDataInclusionPolicy")))
        let abis = try Dictionary(uniqueKeysWithValues: [snapshotType, policyType].map { ($0, try NativeType.opaque(named: $0.name)) })
        // Every type's data, so that neither side keeps promises the other must resolve.
        let policy = try policyType.makeEnumCase(named: "allResolved")
        let capture = try await snapshotType.resolve(.swift(.initializer("init(from:dataPolicy:)",
            as: ((NSPasteboard, NativeSwiftValue) async throws(Failure) -> NativeSwiftValue).self, valueABIs: abis)))
        let write = try await snapshotType.resolve(.swift(.method("write(to:)",
            as: ((NSPasteboard) throws(Failure) -> Int).self, valueABIs: abis, receiverABI: .opaque(named: snapshotType.name))))
        let current = try await implementation.type.resolve(.swift(.method(
            "CoreDevice.PasteboardProtocol.currentPasteboardSnapshot(pasteboardName:dataPolicy:)",
            as: ((String, NativeSwiftValue) async throws(Failure) -> NativeSwiftValue).self, valueABIs: abis)))
        let replace = try await implementation.type.resolve(.swift(.method(
            "CoreDevice.PasteboardProtocol.setPasteboardContents(pasteboardName:pasteboardSnapshot:)",
            as: ((String, NativeSwiftValue) async throws(Failure) -> NativeSwiftValue).self, valueABIs: abis)))
        let name = Self.pasteboardName
        // An initializer owns its arguments, so each capture takes its own copy of the policy.
        self.capture = { pasteboard in try await unsafe capture.unsafeInvoke(pasteboard, policy.copy()) }
        self.write = { snapshot, pasteboard in _ = try unsafe write.unsafeInvoke(on: snapshot, pasteboard) }
        self.current = { try await unsafe current.unsafeInvoke(on: implementation, name, policy) }
        self.replace = { snapshot in _ = try await unsafe replace.unsafeInvoke(on: implementation, name, snapshot) }
    }

    package func read() async throws -> [PasteboardItemContents] {
        let snapshot = try await current()
        let relay = Self.makeRelay()
        defer { relay.releaseGlobally() }
        try write(snapshot, relay)
        return (relay.pasteboardItems ?? []).map { item in
            PasteboardItemContents(types: item.types.map(\.rawValue), text: item.string(forType: .string))
        }
    }

    /// Replaces the pasteboard with one plain-text item.
    package func write(text: String) async throws {
        let relay = Self.makeRelay()
        defer { relay.releaseGlobally() }
        relay.clearContents()
        relay.setString(text, forType: .string)
        try await replace(capture(relay))
    }

    /// CoreDevice converts snapshots to and from an `NSPasteboard`. A private one keeps the Mac's out of it, though a
    /// host that syncs pasteboards, such as Device Hub, still copies a write to the Mac.
    private static func makeRelay() -> NSPasteboard { NSPasteboard.withUniqueName() }
}
