import ABIBridge
import Foundation
import XPC

/// How long a guest service may take to reply or to take the messages sent to it.
let guestServiceLimit: Duration = .seconds(10)

/// One connection to a guest service. The guest removes the services a connection created when it ends.
@MainActor
final class GuestConnection {
    private let link: any GuestLink
    private let feature: String
    private let codec: GuestMessageCodec
    private var failure: (any Error)?
    private var lastPost: ContinuousClock.Instant?
    /// When the guest service last confirmed handling every earlier message.
    private var lastHandled: ContinuousClock.Instant?
    var hasFailed: Bool { failure != nil }

    init(_ link: any GuestLink, feature: String, codec: GuestMessageCodec) {
        self.link = link
        self.feature = feature
        self.codec = codec
        link.setEventHandler { [weak self] event in
            guard xpc_get_type(event) == XPC_TYPE_ERROR else { return }
            let failure = Self.failure(event, feature: feature)
            MainActor.assumeIsolated { if let self, self.failure == nil { self.failure = failure } }
        }
        link.activate()
    }

    isolated deinit { link.cancel() }

    /// Sends a message that has no reply. The service receives a connection's messages in order.
    func post(_ type: GuestMessageCodec.MessageType, _ payload: NativeSwiftValue) throws {
        try post(try codec.message(type, to: feature, payload: payload))
    }

    /// Posts a message whose payload its sender encoded.
    func post(_ type: GuestMessageCodec.MessageType, encoded payload: xpc_object_t) throws {
        try post(codec.message(type, to: feature, encoded: payload))
    }

    private func post(_ message: xpc_object_t) throws {
        if let failure { throw failure }
        link.send(message)
        lastPost = .now
    }

    func request(_ type: GuestMessageCodec.MessageType, _ payload: NativeSwiftValue) async throws -> xpc_object_t {
        try await reply(to: try codec.message(type, to: feature, payload: payload))
    }

    /// Sends a message its sender built whole, as CoreDevice's actions are, and waits for the reply.
    func reply(to message: xpc_object_t) async throws -> xpc_object_t {
        if let failure { throw failure }
        let link = self.link
        let deadline = Task { @MainActor in
            do { try await Task.sleep(for: guestServiceLimit) } catch { return }
            self.failure = SimDriveError(.guestServiceTimeout, "The guest's \(self.feature) service timed out.")
            link.cancel()
        }
        defer { deadline.cancel() }
        let reply: xpc_object_t = await withCheckedContinuation { continuation in
            link.send(message) { reply in
                nonisolated(unsafe) let received = reply
                continuation.resume(returning: received)
            }
        }
        if let failure { throw failure }
        guard xpc_get_type(reply) != XPC_TYPE_ERROR else {
            let error = Self.failure(reply, feature: feature)
            failure = error
            throw error
        }
        return reply
    }

    /// Creates the guest service that `descriptor`, a CoreDevice `HIDServiceDescriptor`, describes.
    func createService(_ descriptor: NativeSwiftValue) async throws -> GuestHIDService {
        let reply = try await request(.request, codec.createService(descriptor))
        let serviceID = try codec.serviceID(createdBy: reply)
        return GuestHIDService(send: { [self] report in try post(.request, codec.send(report, to: serviceID)) },
            remove: { [self] in
                guard failure == nil else { return }
                try post(.request, try await codec.removeService(serviceID))
            })
    }

    /// Waits until the guest service has handled earlier messages; cancelling a connection discards unhandled ones.
    func flush() async throws {
        _ = try await reply(to: codec.barrier())
        lastHandled = .now
    }

    /// Waits until the guest has had time to take the last message, which it drops if the connection ends first.
    func drain() async {
        guard let lastPost else { return }
        if lastHandled.map({ $0 < lastPost }) ?? true { try? await flush() }
        guard let lastHandled, lastHandled >= lastPost else { return }
        let remaining = GuestInputTiming.drain - (ContinuousClock.now - lastHandled)
        if remaining > .zero { await pause(remaining) }
    }

    private nonisolated static func failure(_ event: xpc_object_t, feature: String) -> SimDriveError {
        let reason = unsafe xpc_dictionary_get_string(event, XPC_ERROR_KEY_DESCRIPTION).map { unsafe String(cString: $0) }
        return SimDriveError(.guestConnection,
            "The connection to the guest's \(feature) service ended: \(reason ?? "libxpc gave no reason").")
    }
}
