import ABIBridge
import Darwin
import Foundation
import XPC

/// How long a guest service may take to reply or to take the messages sent to it.
let guestServiceLimit: Duration = .seconds(10)

/// Reaches a simulator's guest services through the Mach services its `SimDevice` looks up, as CoreDevice's
/// simulator plugin does, so no CoreDevice record is needed.
@MainActor
package struct SimulatorGuest {
    let codec: GuestMessageCodec
    private let device: SimulatorDevice
    private let connect: @MainActor (String) async throws -> xpc_connection_t

    package init(device: SimulatorDevice) async throws {
        self.device = device
        let runtime = ABIRuntime.shared
        codec = try await runtime.prepare { try await GuestMessageCodec(runtime: $0) }
        let makeEndpoint = try await runtime.resolve(.c(.function("xpc_endpoint_create_mach_port_4sim",
            as: ((UInt32) -> Unmanaged<AnyObject>?).self)))
        let enableGuestPeer = try await runtime.resolve(.c(.function("xpc_connection_enable_sim2host_4sim",
            as: ((Unmanaged<AnyObject>) -> Void).self)))
        connect = { name in
            let port = try device.lookUp(name)
            // A created endpoint owns the send right; otherwise it remains ours.
            let created: Unmanaged<AnyObject>?
            do { created = try unsafe makeEndpoint.unsafeInvoke(port) } catch {
                mach_port_deallocate(mach_task_self_, port)
                throw error
            }
            guard let created else {
                mach_port_deallocate(mach_task_self_, port)
                throw SimDriveError(.guestEndpoint, "libxpc could not create an endpoint for the guest's \(name) service.")
            }
            guard let endpoint = unsafe created.takeRetainedValue() as? xpc_endpoint_t else {
                throw SimDriveError(.guestEndpoint, "libxpc returned an endpoint for \(name) that is not an XPC object.")
            }
            let connection = xpc_connection_create_from_endpoint(endpoint)
            do { try unsafe enableGuestPeer.unsafeInvoke(.passUnretained(connection as AnyObject)) } catch {
                Self.discard(connection)
                throw error
            }
            return connection
        }
    }

    /// Whether the guest has the service of `feature`. tvOS, for one, has no orientation or pasteboard service.
    func hasService(_ feature: String) -> Bool { device.hasService(feature) }

    /// A new connection to the guest service of `feature`, the name of both its Mach service and its messages' feature.
    func connection(to feature: String) async throws -> GuestConnection {
        GuestConnection(try await connect(feature), feature: feature, codec: codec)
    }

    /// libxpc requires a connection to be activated before its release.
    private static func discard(_ connection: xpc_connection_t) {
        xpc_connection_set_event_handler(connection) { _ in }
        xpc_connection_cancel(connection)
        xpc_connection_activate(connection)
    }
}

/// One connection to a guest service. The guest removes the services a connection created when it ends.
@MainActor
final class GuestConnection {
    private let connection: xpc_connection_t
    private let feature: String
    private let codec: GuestMessageCodec
    private var failure: (any Error)?
    private var lastPost: ContinuousClock.Instant?
    var hasFailed: Bool { failure != nil }

    init(_ connection: xpc_connection_t, feature: String, codec: GuestMessageCodec) {
        self.connection = connection
        self.feature = feature
        self.codec = codec
        xpc_connection_set_target_queue(connection, .main)
        xpc_connection_set_event_handler(connection) { [weak self] event in
            guard xpc_get_type(event) == XPC_TYPE_ERROR else { return }
            let failure = Self.failure(event, feature: feature)
            MainActor.assumeIsolated { if let self, self.failure == nil { self.failure = failure } }
        }
        xpc_connection_activate(connection)
    }

    isolated deinit { xpc_connection_cancel(connection) }

    /// Sends a message that has no reply. The service receives a connection's messages in order.
    func post(_ type: GuestMessageCodec.MessageType, _ payload: NativeSwiftValue) throws {
        if let failure { throw failure }
        xpc_connection_send_message(connection, try codec.message(type, to: feature, payload: payload))
        lastPost = .now
    }

    func request(_ type: GuestMessageCodec.MessageType, _ payload: NativeSwiftValue) async throws -> xpc_object_t {
        if let failure { throw failure }
        let message = try codec.message(type, to: feature, payload: payload)
        let connection = self.connection
        let deadline = Task { @MainActor in
            do { try await Task.sleep(for: guestServiceLimit) } catch { return }
            self.failure = SimDriveError(.guestServiceTimeout, "The guest's \(self.feature) service timed out.")
            xpc_connection_cancel(connection)
        }
        defer { deadline.cancel() }
        let reply: xpc_object_t = await withCheckedContinuation { continuation in
            xpc_connection_send_message_with_reply(connection, message, .main) { reply in
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

    /// Waits until earlier messages have left the connection; cancelling a connection discards unsent ones.
    func flush() async throws {
        let connection = self.connection
        do {
            try await waitForCompletion(within: guestServiceLimit,
                timeout: SimDriveError(.guestServiceTimeout, "The guest's \(feature) service did not take its messages.")) { done in
                xpc_connection_send_barrier(connection) { done(()) }
            }
        } catch {
            if failure == nil { failure = error }
            xpc_connection_cancel(connection)
            throw error
        }
    }

    /// Waits until the guest has had time to take the last message, which it drops if the connection ends first.
    func drain() async {
        guard let lastPost else { return }
        let remaining = GuestInputTiming.drain - (ContinuousClock.now - lastPost)
        if remaining > .zero { await pause(remaining) }
    }

    private nonisolated static func failure(_ event: xpc_object_t, feature: String) -> SimDriveError {
        let reason = unsafe xpc_dictionary_get_string(event, XPC_ERROR_KEY_DESCRIPTION).map { unsafe String(cString: $0) }
        return SimDriveError(.guestConnection,
            "The connection to the guest's \(feature) service ended: \(reason ?? "libxpc gave no reason").")
    }
}
