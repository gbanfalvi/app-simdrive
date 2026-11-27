import ABIBridge
import Darwin
import Foundation
import XPC

private let libxpc = ImageSelector.installName("/usr/lib/system/libxpc.dylib")

/// A device's guest services: the CoreDevice daemons a simulator runs in its guest and a physical device runs from its
/// developer disk image. Both speak the same messages, so only how a connection is made differs.
@MainActor
package struct Guest {
    let codec: GuestMessageCodec
    /// The identifier setting actions name the device by.
    let deviceIdentifier: String
    private let hasServiceNamed: @MainActor (String) -> Bool
    private let connect: @MainActor (String) async throws -> any GuestLink

    init(codec: GuestMessageCodec, deviceIdentifier: String, hasService: @escaping @MainActor (String) -> Bool,
         connect: @escaping @MainActor (String) async throws -> any GuestLink) {
        self.codec = codec
        self.deviceIdentifier = deviceIdentifier
        hasServiceNamed = hasService
        self.connect = connect
    }

    /// A simulator's guest, reached through the Mach services its `SimDevice` looks up, as CoreDevice's simulator plugin
    /// does, so no CoreDevice record is needed.
    package init(simulator device: SimulatorDevice) async throws {
        let runtime = ABIRuntime.shared
        let codec = try await runtime.prepare { try await GuestMessageCodec(runtime: $0) }
        let makeEndpoint = try await runtime.resolve(.c(.function("xpc_endpoint_create_mach_port_4sim",
            as: ((UInt32) -> Unmanaged<AnyObject>?).self)), in: libxpc, loading: .loadedOnly)
        let enableGuestPeer = try await runtime.resolve(.c(.function("xpc_connection_enable_sim2host_4sim",
            as: ((Unmanaged<AnyObject>) -> Void).self)), in: libxpc, loading: .loadedOnly)
        self.init(codec: codec, deviceIdentifier: device.udid, hasService: { device.hasService($0) }) { name in
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
                SimulatorLink.discard(connection)
                throw error
            }
            return SimulatorLink(connection)
        }
    }

    /// A physical device's guest: the daemons of its developer disk image, reached through CoreDevice's RemoteXPC
    /// connections. Setting actions name the device by its CoreDevice identifier; its hardware UDID is refused.
    package init(physical remote: CoreDeviceRemote) async throws {
        let codec = try await ABIRuntime.shared.prepare { try await GuestMessageCodec(runtime: $0) }
        self.init(codec: codec, deviceIdentifier: remote.identifier.uuidString,
                  hasService: { (try? remote.supports($0)) ?? false }) { feature in
            try RemoteDeviceLink(try await remote.remoteConnection(to: feature))
        }
    }

    /// Whether the guest has the service of `feature`. tvOS, for one, has no orientation or pasteboard service.
    func hasService(_ feature: String) -> Bool { hasServiceNamed(feature) }

    /// A new connection to the guest service of `feature`, the name of both its service and its messages' feature.
    func connection(to feature: String) async throws -> GuestConnection {
        GuestConnection(try await connect(feature), feature: feature, codec: codec)
    }
}
