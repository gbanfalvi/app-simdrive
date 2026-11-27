import Darwin
import Dispatch
import XPC

/// One XPC connection to a guest service, whichever transport carries it. Handlers run on the main queue.
@MainActor
protocol GuestLink: AnyObject {
    func setEventHandler(_ handler: @escaping @Sendable (xpc_object_t) -> Void)
    func activate()
    func send(_ message: xpc_object_t)
    func send(_ message: xpc_object_t, reply: @escaping @Sendable (xpc_object_t) -> Void)
    func cancel()
}

/// A physical device's service, through CoreDevice's RemoteXPC connection to its developer disk image's daemon.
@MainActor
final class RemoteDeviceLink: GuestLink {
    private typealias Handler = @convention(block) (xpc_object_t) -> Void
    private typealias SetHandler = @convention(c) (AnyObject, @escaping Handler) -> Void
    private typealias Unary = @convention(c) (AnyObject) -> Void
    private typealias Send = @convention(c) (AnyObject, xpc_object_t) -> Void
    private typealias SendReply = @convention(c) (AnyObject, xpc_object_t, DispatchQueue, @escaping Handler) -> Void

    private struct Functions {
        let setHandler: SetHandler, activate: Unary, cancel: Unary, send: Send, sendReply: SendReply
    }

    private static let remoteXPCPath = "/System/Library/PrivateFrameworks/RemoteXPC.framework/RemoteXPC"
    private static let functions: Functions? = {
        guard let handle = dlopen(remoteXPCPath, RTLD_NOW) else { return nil }
        func load<Function>(_ name: String, _: Function.Type) -> Function? {
            dlsym(handle, name).map { unsafe unsafeBitCast($0, to: Function.self) }
        }
        guard let setHandler = load("xpc_remote_connection_set_event_handler", SetHandler.self),
              let activate = load("xpc_remote_connection_activate", Unary.self),
              let cancel = load("xpc_remote_connection_cancel", Unary.self),
              let send = load("xpc_remote_connection_send_message", Send.self),
              let sendReply = load("xpc_remote_connection_send_message_with_reply", SendReply.self) else { return nil }
        return Functions(setHandler: setHandler, activate: activate, cancel: cancel, send: send, sendReply: sendReply)
    }()

    private let connection: AnyObject
    private let functions: Functions

    init(_ connection: AnyObject) throws {
        guard let functions = Self.functions else {
            throw SimDriveError(.guestEndpoint, "RemoteXPC's connection functions are missing from \(Self.remoteXPCPath).")
        }
        self.connection = connection
        self.functions = functions
    }

    func setEventHandler(_ handler: @escaping @Sendable (xpc_object_t) -> Void) { functions.setHandler(connection, handler) }
    func activate() { functions.activate(connection) }
    func send(_ message: xpc_object_t) { functions.send(connection, message) }

    func send(_ message: xpc_object_t, reply: @escaping @Sendable (xpc_object_t) -> Void) {
        functions.sendReply(connection, message, .main, reply)
    }

    func cancel() { functions.cancel(connection) }
}

/// A simulator guest's service, through a Mach right that CoreSimulator looked up.
@MainActor
final class SimulatorLink: GuestLink {
    private let connection: xpc_connection_t

    init(_ connection: xpc_connection_t) {
        self.connection = connection
        xpc_connection_set_target_queue(connection, .main)
    }

    func setEventHandler(_ handler: @escaping @Sendable (xpc_object_t) -> Void) {
        xpc_connection_set_event_handler(connection, handler)
    }

    func activate() { xpc_connection_activate(connection) }
    func send(_ message: xpc_object_t) { xpc_connection_send_message(connection, message) }

    func send(_ message: xpc_object_t, reply: @escaping @Sendable (xpc_object_t) -> Void) {
        xpc_connection_send_message_with_reply(connection, message, .main, reply)
    }

    func cancel() { xpc_connection_cancel(connection) }

    /// libxpc requires a connection to be activated before its release, even one being discarded.
    static func discard(_ connection: xpc_connection_t) {
        xpc_connection_set_event_handler(connection) { _ in }
        xpc_connection_cancel(connection)
        xpc_connection_activate(connection)
    }
}
