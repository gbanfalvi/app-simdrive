import ABIBridge

/// One guest UniversalHID service, which lasts until it is removed or its connection ends. Its owner builds the
/// reports and orders their sends.
@MainActor
final class GuestHIDService {
    static let universalHIDFeature = "com.apple.coredevice.feature.remote.universalhidservice"

    private let sendNative: (NativeSwiftValue) throws -> Void
    private let removeNative: () async throws -> Void
    private var isRemoved = false

    init(send: @escaping (NativeSwiftValue) throws -> Void, remove: @escaping () async throws -> Void) {
        sendNative = send
        removeNative = remove
    }

    func send(_ report: NativeSwiftValue) throws {
        guard !isRemoved else { throw SimDriveError(.hidServiceRemoved, "The HID service has ended.") }
        try sendNative(report)
    }

    func remove() async throws {
        guard !isRemoved else { return }
        try await removeNative()
        isRemoved = true
    }
}
