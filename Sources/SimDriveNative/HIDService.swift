import ABIBridge
import Foundation

/// One guest UniversalHID service. Its owner builds the reports and orders their sends.
@MainActor
package final class HIDService {
    /// CoreDevice consumes its bundled module; the system has another module of the same name.
    nonisolated static let universalHIDURL = URL(fileURLWithPath: "/Library/Developer/PrivateFrameworks/CoreDevice.framework/Versions/A/Frameworks/UniversalHID.framework/Versions/A/UniversalHID")
    package nonisolated static let universalHIDFeature = "com.apple.coredevice.feature.remote.universalhidservice"

    private let sendNative: (NativeSwiftValue) throws -> Void
    private let removeNative: () async throws -> Void
    private var isRemoved = false

    init(send: @escaping (NativeSwiftValue) throws -> Void, remove: @escaping () async throws -> Void) {
        sendNative = send
        removeNative = remove
    }

    nonisolated static func loadUniversalHID() async throws {
        try await NativeFrameworks.load(universalHIDURL.path)
    }

    /// A type of CoreDevice's own UniversalHID module, once ``loadUniversalHID()`` has loaded it.
    nonisolated static func universalHIDType(_ name: String, runtime: ABIRuntime) throws -> NativeSwiftType {
        try runtime.resolveAndWait(.swift(.type("UniversalHID." + name)), in: .path(universalHIDURL), loading: .loadedOnly)
    }

    /// `HIDReport` wraps the report's `Data`, whose two words its exported members pass directly.
    nonisolated static func reportABI(runtime: ABIRuntime) throws -> (type: NativeSwiftType, abi: NativeType) {
        let type = try universalHIDType("HIDReport", runtime: runtime)
        return (type, try .structure(named: type.name, fields: [.uint64, .uint64]))
    }

    func send(_ report: NativeSwiftValue) throws {
        guard !isRemoved else { throw NativeError("hid-service-removed", "The HID service has ended.") }
        try sendNative(report)
    }

    func stop() async throws {
        guard !isRemoved else { return }
        try await removeNative()
        isRemoved = true
    }
}
