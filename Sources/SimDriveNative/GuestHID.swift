import ABIBridge
import CoreGraphics
import Darwin
import Foundation
import XPC

package enum TouchPhase: String, Sendable { case began, moved, ended }

package enum TouchEdge: String, Sendable, CaseIterable { case none, top, left, right, bottom }

package enum ButtonState: String, Sendable { case down, up }

/// The guest's orientation readings, as CoreDevice `DeviceOrientation` raw values.
package struct GuestOrientationReading: Equatable, Sendable {
    package let physical: String
    package let nonFlat: String
}

/// How long a guest service may take to create a HID service or take the messages sent to it.
let guestServiceLimit: Duration = .seconds(10)

/// Reaches a simulator's guest HID services through the Mach services its `SimDevice` looks up, as CoreDevice's
/// simulator plugin does, so no CoreDevice record is needed.
@MainActor
package struct SimulatorGuestHID {
    package let codec: GuestHIDCodec
    private let connect: @MainActor (String) async throws -> xpc_connection_t

    /// `lookUp` returns a caller-owned send right to the guest's Mach service of a name.
    package init(lookUp: @escaping @MainActor (String) throws -> UInt32) async throws {
        let runtime = ABIRuntime.shared
        codec = try await runtime.prepare { try await GuestHIDCodec(runtime: $0) }
        let makeEndpoint = try await runtime.resolve(.c(.function("xpc_endpoint_create_mach_port_4sim",
            as: ((UInt32) -> Unmanaged<AnyObject>?).self)))
        let enableGuestPeer = try await runtime.resolve(.c(.function("xpc_connection_enable_sim2host_4sim",
            as: ((Unmanaged<AnyObject>) -> Void).self)))
        connect = { name in
            let port = try lookUp(name)
            // A created endpoint owns the send right; otherwise it remains ours.
            let created: Unmanaged<AnyObject>?
            do { created = try unsafe makeEndpoint.unsafeInvoke(port) } catch {
                mach_port_deallocate(mach_task_self_, port)
                throw error
            }
            guard let created else {
                mach_port_deallocate(mach_task_self_, port)
                throw NativeError("guest-hid-endpoint", "libxpc could not create an endpoint for the guest's \(name) service.")
            }
            guard let endpoint = unsafe created.takeRetainedValue() as? xpc_endpoint_t else {
                throw NativeError("guest-hid-endpoint", "libxpc returned an endpoint for \(name) that is not an XPC object.")
            }
            let connection = xpc_connection_create_from_endpoint(endpoint)
            do { try unsafe enableGuestPeer.unsafeInvoke(.passUnretained(connection as AnyObject)) } catch {
                Self.discard(connection)
                throw error
            }
            return connection
        }
    }

    /// A new connection to the guest service of `feature`, the name of both its Mach service and its messages' feature.
    package func connection(to feature: String) async throws -> GuestHIDConnection {
        GuestHIDConnection(try await connect(feature), feature: feature, codec: codec)
    }

    /// libxpc requires a connection to be activated before its release.
    private static func discard(_ connection: xpc_connection_t) {
        xpc_connection_set_event_handler(connection) { _ in }
        xpc_connection_cancel(connection)
        xpc_connection_activate(connection)
    }
}

/// One connection to a guest HID service. The guest removes the services a connection created when it ends.
@MainActor
package final class GuestHIDConnection {
    private let connection: xpc_connection_t
    private let feature: String
    private let codec: GuestHIDCodec
    private var failure: (any Error)?
    package var hasFailed: Bool { failure != nil }

    init(_ connection: xpc_connection_t, feature: String, codec: GuestHIDCodec) {
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
    package func post(_ type: GuestHIDCodec.MessageType, _ payload: NativeSwiftValue) throws {
        if let failure { throw failure }
        xpc_connection_send_message(connection, try codec.message(type, to: feature, payload: payload))
    }

    package func request(_ type: GuestHIDCodec.MessageType, _ payload: NativeSwiftValue) async throws -> xpc_object_t {
        if let failure { throw failure }
        let message = try codec.message(type, to: feature, payload: payload)
        let connection = self.connection
        let deadline = Task { @MainActor in
            do { try await Task.sleep(for: guestServiceLimit) } catch { return }
            self.failure = NativeError("guest-service-timeout", "The guest's \(self.feature) service timed out.")
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
    package func createService(_ descriptor: NativeSwiftValue) async throws -> HIDService {
        let reply = try await request(.request, codec.createService(descriptor))
        let serviceID = try codec.serviceID(createdBy: reply)
        return HIDService(send: { [self] report in try post(.request, codec.send(report, to: serviceID)) },
            remove: { [self] in
                guard failure == nil else { return }
                try post(.request, try await codec.removeService(serviceID))
            })
    }

    /// Waits until earlier messages have left the connection; cancelling a connection discards unsent ones.
    package func flush() async throws {
        let connection = self.connection
        do {
            try await waitForCompletion(within: guestServiceLimit,
                timeout: NativeError("guest-service-timeout", "The guest's \(feature) service did not take its messages.")) { done in
                xpc_connection_send_barrier(connection) { done() }
            }
        } catch {
            if failure == nil { failure = error }
            xpc_connection_cancel(connection)
            throw error
        }
    }

    private nonisolated static func failure(_ event: xpc_object_t, feature: String) -> NativeError {
        let reason = unsafe xpc_dictionary_get_string(event, XPC_ERROR_KEY_DESCRIPTION).map { unsafe String(cString: $0) }
        return NativeError("guest-hid-connection",
            "The connection to the guest's \(feature) service ended: \(reason ?? "libxpc gave no reason").")
    }
}

/// The guest HID services' messages: CoreDeviceUtilities values encoded with Mercury's XPC encoder, as CoreDevice sends them.
@MainActor
package struct GuestHIDCodec {
    package enum MessageType: String {
        case digitizerEvent = "IndigoDigitizerEvent", buttonEvent = "IndigoButtonEvent", request = "Request"
        case orientation = "OrientationRequest"
    }

    private let featureKey: String
    private let messageTypeKey: String
    private let payloadKey: String
    private let encoders: [MessageType: (NativeSwiftValue) throws -> xpc_object_t]
    private let makeDigitizerEvent: (CGPoint, TouchPhase, TouchEdge, String) throws -> NativeSwiftValue
    private let makeButtonEvent: (UInt16, UInt16, ButtonState) throws -> NativeSwiftValue
    private let requestType: NativeSwiftType
    private let readReportData: NativeSwiftMethod<() -> Data>
    private let readCreatedService: (xpc_object_t) throws -> NativeSwiftValue
    private let orientationRequestType: NativeSwiftType
    private let orientationType: NativeSwiftType
    private let readOrientation: (xpc_object_t) throws -> GuestOrientationReading

    package init(runtime: ABIRuntime) async throws {
        try await NativeFrameworks.load(NativeFrameworks.coreDevicePath)
        let event = try await runtime.resolve(.swift(.type("CoreDeviceUtilities.HIDXPCServiceEvent")))
        featureKey = try await unsafe event.resolve(.swift(.staticGetter("featureIdentifierFieldName", as: (() -> String).self))).unsafeInvoke()
        messageTypeKey = try await unsafe event.resolve(.swift(.staticGetter("messageTypeFieldName", as: (() -> String).self))).unsafeInvoke()
        payloadKey = try await unsafe event.resolve(.swift(.staticGetter("payloadFieldName", as: (() -> String).self))).unsafeInvoke()
        let errorKey = try await unsafe event.resolve(.swift(.staticGetter("errorFieldName", as: (() -> String).self))).unsafeInvoke()

        let point = try await runtime.resolve(.swift(.type("CoreDevice.DigitizerPoint")))
        let eventType = try await runtime.resolve(.swift(.type("CoreDevice.DigitizerEventType")))
        let edge = try await runtime.resolve(.swift(.type("CoreDevice.DigitizerEdge")))
        let target = try await runtime.resolve(.swift(.type("CoreDevice.DigitizerTarget")))
        let digitizer = try await runtime.resolve(.swift(.type("CoreDeviceUtilities.IndigoDigitizerEvent")))
        let buttonState = try await runtime.resolve(.swift(.type("CoreDevice.HIDButtonState")))
        let button = try await runtime.resolve(.swift(.type("CoreDeviceUtilities.IndigoButtonEvent")))
        let request = try await runtime.resolve(.swift(.type("CoreDeviceUtilities.DDIUniversalHIDServicePayload.Request")))
        requestType = request
        orientationRequestType = try await runtime.resolve(.swift(.type("CoreDeviceUtilities.OrientationRequest")))
        orientationType = try await runtime.resolve(.swift(.type("CoreDevice.DeviceOrientation")))
        // CoreDevice passes these resilient values by address.
        let abis = try Dictionary(uniqueKeysWithValues: [point, eventType, edge, target, digitizer, buttonState, button]
            .map { ($0, try NativeType.opaque(named: $0.name)) })
        let makePoint = try await point.resolve(.swift(.initializer("init(x:y:)",
            as: ((CGFloat, CGFloat) -> NativeSwiftValue).self, valueABIs: abis)))
        let makeDigitizer = try await digitizer.resolve(.swift(.initializer("init(pointOne:pointTwo:eventType:edge:target:)",
            as: ((NativeSwiftValue, NativeSwiftValue?, NativeSwiftValue, NativeSwiftValue, NativeSwiftValue) -> NativeSwiftValue).self,
            valueABIs: abis)))
        // An initializer consumes its arguments, so each event gets its own.
        makeDigitizerEvent = { first, phase, touchEdge, targetName in
            let name = switch phase { case .began: "start"; case .moved: "position"; case .ended: "end" }
            return try unsafe makeDigitizer.unsafeInvoke(makePoint.unsafeInvoke(first.x, first.y), nil,
                eventType.makeEnumCase(named: name), edge.makeEnumCase(named: touchEdge.rawValue),
                target.makeEnumCase(named: targetName))
        }
        let makeButton = try await button.resolve(.swift(.initializer("init(usagePage:usageCode:state:)",
            as: ((UInt16, UInt16, NativeSwiftValue) -> NativeSwiftValue).self, valueABIs: abis)))
        makeButtonEvent = { page, usage, state in
            try unsafe makeButton.unsafeInvoke(page, usage, buttonState.makeEnumCase(named: state.rawValue))
        }

        let report = try await runtime.prepare { try HIDService.reportABI(runtime: $0) }
        let data = try await runtime.resolve(.swift(.type("Foundation.Data")))
        readReportData = try await report.type.resolve(.swift(.getter("data", as: (() -> Data).self,
            valueABIs: [report.type: report.abi, data: try .structure(named: data.name, fields: [.uint64, .uint64])],
            receiverABI: report.abi)))

        let encoderType = try await runtime.resolve(.swift(.type("Mercury.XPCObjectEncoder")))
        let makeEncoder = try await encoderType.resolve(.swift(.initializer("init()", as: (() -> NativeSwiftValue).self)))
        var encoders: [MessageType: (NativeSwiftValue) throws -> xpc_object_t] = [:]
        let payloadTypes: [(MessageType, NativeSwiftType)] = [(.digitizerEvent, digitizer), (.buttonEvent, button),
            (.request, request), (.orientation, orientationRequestType)]
        for (type, payloadType) in payloadTypes {
            let encode = try await encoderType.resolve(.swift(.method(
                "Mercury.XPCObjectEncoder.encode<A where A: Swift.Encodable>(A) throws -> __C.OS_xpc_object",
                as: ((NativeSwiftValue) throws -> xpc_object_t).self, genericArguments: [.type(payloadType)])))
            // CoreDevice encodes each payload with a new encoder.
            encoders[type] = { payload in try unsafe encode.unsafeInvoke(on: makeEncoder.unsafeInvoke(), payload) }
        }
        self.encoders = encoders

        let decoderType = try await runtime.resolve(.swift(.type("Mercury.XPCObjectDecoder")))
        let makeDecoder = try await decoderType.resolve(.swift(.initializer("init()", as: (() -> NativeSwiftValue).self)))
        let created = try await runtime.resolve(.swift(.type("CoreDeviceUtilities.DDIUniversalHIDServicePayload.CreatedServiceID")))
        let errorContainer = try await runtime.resolve(.swift(.type("Mercury.NSErrorContainer")))
        let serviceIDType = try await runtime.resolve(.swift(.type("CoreDevice.HIDServiceID")))
        let replyABIs = try Dictionary(uniqueKeysWithValues: [created, errorContainer, serviceIDType]
            .map { ($0, try NativeType.opaque(named: $0.name)) })
        let readServiceID = try await created.resolve(.swift(.getter("serviceID", as: (() -> NativeSwiftValue).self,
            valueABIs: replyABIs, receiverABI: replyABIs[created])))
        let readError = try await errorContainer.resolve(.swift(.getter("rawValue", as: (() -> NSError).self,
            valueABIs: replyABIs, receiverABI: replyABIs[errorContainer])))
        func decoder(of type: NativeSwiftType) async throws -> (xpc_object_t) throws -> NativeSwiftValue {
            let decode = try await decoderType.resolve(.swift(.method(
                "Mercury.XPCObjectDecoder.decode<A where A: Swift.Decodable>(_: A.Type, from: __C.OS_xpc_object) throws -> A",
                as: ((NativeSwiftValue, xpc_object_t) throws -> NativeSwiftValue).self, genericArguments: [.type(type)])))
            let metatype = try type.makeMetatypeValue()
            return { object in try unsafe decode.unsafeInvoke(on: makeDecoder.unsafeInvoke(), metatype, object) }
        }
        let decodeCreated = try await decoder(of: created)
        let decodeError = try await decoder(of: errorContainer)
        let infoType = try await runtime.resolve(.swift(.type("CoreDevice.OrientationInfo")))
        let decodeOrientation = try await decoder(of: infoType)
        let orientationABIs = try Dictionary(uniqueKeysWithValues: [infoType, orientationType]
            .map { ($0, try NativeType.opaque(named: $0.name)) })
        let physical = try await infoType.resolve(.swift(.getter("currentDeviceOrientation",
            as: (() -> NativeSwiftValue).self, valueABIs: orientationABIs, receiverABI: orientationABIs[infoType])))
        let upright = try await infoType.resolve(.swift(.getter("currentDeviceNonFlatOrientation",
            as: (() -> NativeSwiftValue).self, valueABIs: orientationABIs, receiverABI: orientationABIs[infoType])))
        let rawValue = try await orientationType.resolve(.swift(.getter("rawValue", as: (() -> String).self,
            valueABIs: orientationABIs, receiverABI: orientationABIs[orientationType])))
        readOrientation = { reply in
            if let error = xpc_dictionary_get_value(reply, errorKey) {
                throw try unsafe readError.unsafeInvoke(on: decodeError(error))
            }
            let info = try decodeOrientation(reply)
            return try unsafe GuestOrientationReading(physical: rawValue.unsafeInvoke(on: physical.unsafeInvoke(on: info)),
                nonFlat: rawValue.unsafeInvoke(on: upright.unsafeInvoke(on: info)))
        }
        readCreatedService = { reply in
            if let error = xpc_dictionary_get_value(reply, errorKey) {
                throw try unsafe readError.unsafeInvoke(on: decodeError(error))
            }
            return try unsafe readServiceID.unsafeInvoke(on: decodeCreated(reply))
        }
    }

    package func message(_ type: MessageType, to feature: String, payload: NativeSwiftValue) throws -> xpc_object_t {
        let encoded = try encoders[type]!(payload)
        let message = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(message, featureKey, feature)
        xpc_dictionary_set_string(message, messageTypeKey, type.rawValue)
        xpc_dictionary_set_value(message, payloadKey, encoded)
        return message
    }

    /// A touch at `point`, in unit coordinates of the target panel in its native orientation. `target` is a
    /// CoreDevice `DigitizerTarget` case: `mainScreen` or `display1` through `display10`.
    package func digitizerEvent(at point: CGPoint, phase: TouchPhase, edge: TouchEdge, target: String) throws -> NativeSwiftValue {
        try makeDigitizerEvent(point, phase, edge, target)
    }

    package func buttonEvent(usagePage: UInt16, usage: UInt16, state: ButtonState) throws -> NativeSwiftValue {
        try makeButtonEvent(usagePage, usage, state)
    }

    package func createService(_ descriptor: NativeSwiftValue) async throws -> NativeSwiftValue {
        try await requestType.makeEnumCase(named: "createService", payload: descriptor)
    }

    package func serviceID(createdBy reply: xpc_object_t) throws -> NativeSwiftValue {
        try readCreatedService(reply)
    }

    package func send(_ report: NativeSwiftValue, to serviceID: NativeSwiftValue) throws -> NativeSwiftValue {
        let data = try unsafe readReportData.unsafeInvoke(on: report)
        return try requestType.makeEnumCaseAndWait(named: "send", associatedValues: data, serviceID)
    }

    package func removeService(_ serviceID: NativeSwiftValue) async throws -> NativeSwiftValue {
        try await requestType.makeEnumCase(named: "removeService", payload: serviceID)
    }

    package func currentOrientationRequest() throws -> NativeSwiftValue {
        try orientationRequestType.makeEnumCase(named: "currentOrientation")
    }

    package func orientationRequest(named orientation: String) throws -> NativeSwiftValue {
        try orientationRequestType.makeEnumCaseAndWait(named: "changeOrientation",
            payload: orientationType.makeEnumCase(named: orientation))
    }

    package func orientation(from reply: xpc_object_t) throws -> GuestOrientationReading { try readOrientation(reply) }
}

/// Reads and sets the guest's device orientation.
@MainActor
package final class GuestDeviceOrientation {
    package static let feature = "com.apple.coredevice.feature.remote.devicecontrol.orientation"
    private let guest: SimulatorGuestHID
    private var connection: GuestHIDConnection

    private init(guest: SimulatorGuestHID) async throws {
        self.guest = guest
        connection = try await guest.connection(to: Self.feature)
    }

    /// The guest's orientation service, or nil when it has none, as on tvOS.
    package static func open(guest: SimulatorGuestHID) async throws -> GuestDeviceOrientation? {
        do {
            return try await GuestDeviceOrientation(guest: guest)
        } catch let error as NativeError where error.identifier == SimulatorDevice.missingServiceIdentifier {
            return nil
        }
    }

    package func read() async throws -> GuestOrientationReading {
        try await send(guest.codec.currentOrientationRequest())
    }

    /// Sets the orientation of a CoreDevice `DeviceOrientation` raw value, such as `landscapeLeft`.
    package func set(named orientation: String) async throws -> GuestOrientationReading {
        try await send(guest.codec.orientationRequest(named: orientation))
    }

    private func send(_ request: NativeSwiftValue) async throws -> GuestOrientationReading {
        if connection.hasFailed { connection = try await guest.connection(to: Self.feature) }
        return try guest.codec.orientation(from: await connection.request(.orientation, request))
    }
}
