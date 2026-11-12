import ABIBridge
import CoreGraphics
import Foundation
import XPC

/// The guest services' messages: CoreDeviceUtilities values encoded with Mercury's XPC encoder, as CoreDevice sends them.
@MainActor
struct GuestMessageCodec {
    enum MessageType: String {
        case digitizerEvent = "IndigoDigitizerEvent", buttonEvent = "IndigoButtonEvent", request = "Request"
        case orientation = "OrientationRequest"
    }

    private typealias Encode = (NativeSwiftValue) throws -> xpc_object_t
    private typealias Decode = (xpc_object_t) throws -> NativeSwiftValue

    /// The `DigitizerEdge` case of a touch away from the edges.
    private static let noEdge = "none"

    private let featureKey: String
    private let messageTypeKey: String
    private let payloadKey: String
    private let encoders: [MessageType: Encode]
    private let makeDigitizerEvent: (CGPoint, String, String, String) throws -> NativeSwiftValue
    private let makeButtonEvent: (UInt16, UInt16, String) throws -> NativeSwiftValue
    private let requestType: NativeSwiftType
    private let readReportData: (NativeSwiftValue) throws -> Data
    private let readCreatedService: Decode
    private let orientationRequestType: NativeSwiftType
    private let orientationType: NativeSwiftType
    private let readOrientation: (xpc_object_t) throws -> GuestOrientationReading

    init(runtime: ABIRuntime) async throws {
        try await NativeFrameworks.load(NativeFrameworks.coreDevicePath)
        let event = try await runtime.resolve(.swift(.type("CoreDeviceUtilities.HIDXPCServiceEvent")))
        func fieldName(_ getter: String) async throws -> String {
            try await unsafe event.resolve(.swift(.staticGetter(getter, as: (() -> String).self))).unsafeInvoke()
        }
        featureKey = try await fieldName("featureIdentifierFieldName")
        messageTypeKey = try await fieldName("messageTypeFieldName")
        payloadKey = try await fieldName("payloadFieldName")
        let replies = try await ReplyDecoder(runtime: runtime, errorKey: try await fieldName("errorFieldName"))

        let digitizer = try await Self.digitizerEvents(runtime: runtime)
        makeDigitizerEvent = digitizer.make
        let button = try await Self.buttonEvents(runtime: runtime)
        makeButtonEvent = button.make
        let request = try await Self.serviceRequests(runtime: runtime, replies: replies)
        requestType = request.type
        readReportData = request.readReportData
        readCreatedService = request.readCreatedService
        let orientation = try await Self.orientationRequests(runtime: runtime, replies: replies)
        orientationRequestType = orientation.type
        orientationType = orientation.orientationType
        readOrientation = orientation.read
        encoders = try await Self.encoders(runtime: runtime, payloadTypes: [
            .digitizerEvent: digitizer.type, .buttonEvent: button.type, .request: request.type, .orientation: orientation.type,
        ])
    }

    func message(_ type: MessageType, to feature: String, payload: NativeSwiftValue) throws -> xpc_object_t {
        guard let encode = encoders[type] else { throw SimDriveError(.guestMessage, "\(type.rawValue) has no encoder.") }
        let message = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(message, featureKey, feature)
        xpc_dictionary_set_string(message, messageTypeKey, type.rawValue)
        xpc_dictionary_set_value(message, payloadKey, try encode(payload))
        return message
    }

    /// A touch at `point`, in unit coordinates of the target panel in its native orientation.
    func digitizerEvent(at point: CGPoint, phase: TouchPhase, edge: ScreenEdge?, target: DigitizerTarget) throws -> NativeSwiftValue {
        try makeDigitizerEvent(point, phase.rawValue, edge?.rawValue ?? Self.noEdge, target.description)
    }

    func buttonEvent(_ button: HardwareButton, state: ButtonState) throws -> NativeSwiftValue {
        try makeButtonEvent(HardwareButton.usagePage, button.usage, state.rawValue)
    }

    func createService(_ descriptor: NativeSwiftValue) async throws -> NativeSwiftValue {
        try await requestType.makeEnumCase(named: "createService", payload: descriptor)
    }

    func serviceID(createdBy reply: xpc_object_t) throws -> NativeSwiftValue {
        try readCreatedService(reply)
    }

    func send(_ report: NativeSwiftValue, to serviceID: NativeSwiftValue) throws -> NativeSwiftValue {
        try requestType.makeEnumCaseAndWait(named: "send", associatedValues: try readReportData(report), serviceID)
    }

    func removeService(_ serviceID: NativeSwiftValue) async throws -> NativeSwiftValue {
        try await requestType.makeEnumCase(named: "removeService", payload: serviceID)
    }

    func currentOrientationRequest() throws -> NativeSwiftValue {
        try orientationRequestType.makeEnumCase(named: "currentOrientation")
    }

    func orientationRequest(_ orientation: DeviceOrientation) throws -> NativeSwiftValue {
        try orientationRequestType.makeEnumCaseAndWait(named: "changeOrientation",
            payload: orientationType.makeEnumCase(named: orientation.rawValue))
    }

    func orientation(from reply: xpc_object_t) throws -> GuestOrientationReading { try readOrientation(reply) }

    // MARK: Message families

    /// An initializer consumes its arguments, so each event gets its own.
    private static func digitizerEvents(runtime: ABIRuntime) async throws
        -> (type: NativeSwiftType, make: (CGPoint, String, String, String) throws -> NativeSwiftValue) {
        let point = try await runtime.resolve(.swift(.type("CoreDevice.DigitizerPoint")))
        let eventType = try await runtime.resolve(.swift(.type("CoreDevice.DigitizerEventType")))
        let edge = try await runtime.resolve(.swift(.type("CoreDevice.DigitizerEdge")))
        let target = try await runtime.resolve(.swift(.type("CoreDevice.DigitizerTarget")))
        let digitizer = try await runtime.resolve(.swift(.type("CoreDeviceUtilities.IndigoDigitizerEvent")))
        let abis = try NativeType.opaqueABIs(for: [point, eventType, edge, target, digitizer])
        let makePoint = try await point.resolve(.swift(.initializer("init(x:y:)",
            as: ((CGFloat, CGFloat) -> NativeSwiftValue).self, valueABIs: abis)))
        let makeDigitizer = try await digitizer.resolve(.swift(.initializer("init(pointOne:pointTwo:eventType:edge:target:)",
            as: ((NativeSwiftValue, NativeSwiftValue?, NativeSwiftValue, NativeSwiftValue, NativeSwiftValue) -> NativeSwiftValue).self,
            valueABIs: abis)))
        return (digitizer, { first, phase, edgeName, targetName in
            try unsafe makeDigitizer.unsafeInvoke(makePoint.unsafeInvoke(first.x, first.y), nil,
                eventType.makeEnumCase(named: phase), edge.makeEnumCase(named: edgeName), target.makeEnumCase(named: targetName))
        })
    }

    private static func buttonEvents(runtime: ABIRuntime) async throws
        -> (type: NativeSwiftType, make: (UInt16, UInt16, String) throws -> NativeSwiftValue) {
        let buttonState = try await runtime.resolve(.swift(.type("CoreDevice.HIDButtonState")))
        let button = try await runtime.resolve(.swift(.type("CoreDeviceUtilities.IndigoButtonEvent")))
        let makeButton = try await button.resolve(.swift(.initializer("init(usagePage:usageCode:state:)",
            as: ((UInt16, UInt16, NativeSwiftValue) -> NativeSwiftValue).self, valueABIs: try NativeType.opaqueABIs(for: [buttonState, button]))))
        return (button, { page, usage, state in try unsafe makeButton.unsafeInvoke(page, usage, buttonState.makeEnumCase(named: state)) })
    }

    /// The universal HID service's requests, which create services, send them reports and remove them.
    private static func serviceRequests(runtime: ABIRuntime, replies: ReplyDecoder) async throws
        -> (type: NativeSwiftType, readReportData: (NativeSwiftValue) throws -> Data, readCreatedService: Decode) {
        let request = try await runtime.resolve(.swift(.type("CoreDeviceUtilities.DDIUniversalHIDServicePayload.Request")))
        let report = try await runtime.prepare { try CoreDeviceUniversalHID.reportABI(runtime: $0) }
        let data = try await runtime.resolve(.swift(.type("Foundation.Data")))
        let reportData = try await report.type.resolve(.swift(.getter("data", as: (() -> Data).self,
            valueABIs: [report.type: report.abi, data: try .dataABI(data)], receiverABI: report.abi)))
        let created = try await runtime.resolve(.swift(.type("CoreDeviceUtilities.DDIUniversalHIDServicePayload.CreatedServiceID")))
        let serviceIDType = try await runtime.resolve(.swift(.type("CoreDevice.HIDServiceID")))
        let abis = try NativeType.opaqueABIs(for: [created, serviceIDType])
        let serviceID = try await created.resolve(.swift(.getter("serviceID", as: (() -> NativeSwiftValue).self,
            valueABIs: abis, receiverABI: abis[created])))
        let decodeCreated = try await replies.decoder(of: created)
        return (request, { try unsafe reportData.unsafeInvoke(on: $0) }, { try unsafe serviceID.unsafeInvoke(on: decodeCreated($0)) })
    }

    private static func orientationRequests(runtime: ABIRuntime, replies: ReplyDecoder) async throws
        -> (type: NativeSwiftType, orientationType: NativeSwiftType, read: (xpc_object_t) throws -> GuestOrientationReading) {
        let request = try await runtime.resolve(.swift(.type("CoreDeviceUtilities.OrientationRequest")))
        let orientationType = try await runtime.resolve(.swift(.type("CoreDevice.DeviceOrientation")))
        let infoType = try await runtime.resolve(.swift(.type("CoreDevice.OrientationInfo")))
        let decodeInfo = try await replies.decoder(of: infoType)
        let abis = try NativeType.opaqueABIs(for: [infoType, orientationType])
        let physical = try await infoType.resolve(.swift(.getter("currentDeviceOrientation",
            as: (() -> NativeSwiftValue).self, valueABIs: abis, receiverABI: abis[infoType])))
        let upright = try await infoType.resolve(.swift(.getter("currentDeviceNonFlatOrientation",
            as: (() -> NativeSwiftValue).self, valueABIs: abis, receiverABI: abis[infoType])))
        let rawValue = try await orientationType.resolve(.swift(.getter("rawValue", as: (() -> String).self,
            valueABIs: abis, receiverABI: abis[orientationType])))
        return (request, orientationType, { reply in
            let info = try decodeInfo(reply)
            let nonFlat = try unsafe rawValue.unsafeInvoke(on: upright.unsafeInvoke(on: info))
            return try unsafe GuestOrientationReading(orientation: DeviceOrientation(rawValue: nonFlat),
                physical: rawValue.unsafeInvoke(on: physical.unsafeInvoke(on: info)))
        })
    }

    /// CoreDevice encodes each payload with a new encoder.
    private static func encoders(runtime: ABIRuntime, payloadTypes: [MessageType: NativeSwiftType]) async throws -> [MessageType: Encode] {
        let encoderType = try await runtime.resolve(.swift(.type("Mercury.XPCObjectEncoder")))
        let makeEncoder = try await encoderType.resolve(.swift(.initializer("init()", as: (() -> NativeSwiftValue).self)))
        var encoders: [MessageType: Encode] = [:]
        for (type, payloadType) in payloadTypes {
            let encode = try await encoderType.resolve(.swift(.method(
                "Mercury.XPCObjectEncoder.encode<A where A: Swift.Encodable>(A) throws -> __C.OS_xpc_object",
                as: ((NativeSwiftValue) throws -> xpc_object_t).self, genericArguments: [.type(payloadType)])))
            encoders[type] = { payload in try unsafe encode.unsafeInvoke(on: makeEncoder.unsafeInvoke(), payload) }
        }
        return encoders
    }
}

/// Decodes replies with Mercury's XPC decoder. A reply that carries an error throws it instead.
@MainActor
private struct ReplyDecoder {
    private typealias Decode = (xpc_object_t) throws -> NativeSwiftValue

    private let errorKey: String
    private let decoderType: NativeSwiftType
    private let makeDecoder: () throws -> NativeSwiftValue
    private let readError: (xpc_object_t) throws -> NSError

    init(runtime: ABIRuntime, errorKey: String) async throws {
        let decoderType = try await runtime.resolve(.swift(.type("Mercury.XPCObjectDecoder")))
        let initializer = try await decoderType.resolve(.swift(.initializer("init()", as: (() -> NativeSwiftValue).self)))
        let makeDecoder = { try unsafe initializer.unsafeInvoke() }
        let container = try await runtime.resolve(.swift(.type("Mercury.NSErrorContainer")))
        let abis = try NativeType.opaqueABIs(for: [container])
        let rawValue = try await container.resolve(.swift(.getter("rawValue", as: (() -> NSError).self,
            valueABIs: abis, receiverABI: abis[container])))
        let decodeContainer = try await Self.decoder(of: container, decoderType: decoderType, makeDecoder: makeDecoder)
        self.errorKey = errorKey
        self.decoderType = decoderType
        self.makeDecoder = makeDecoder
        readError = { try unsafe rawValue.unsafeInvoke(on: decodeContainer($0)) }
    }

    /// Decodes replies whose payload is a `type`.
    func decoder(of type: NativeSwiftType) async throws -> (xpc_object_t) throws -> NativeSwiftValue {
        let decode = try await Self.decoder(of: type, decoderType: decoderType, makeDecoder: makeDecoder)
        return { [errorKey, readError] reply in
            if let error = xpc_dictionary_get_value(reply, errorKey) { throw try readError(error) }
            return try decode(reply)
        }
    }

    private static func decoder(of type: NativeSwiftType, decoderType: NativeSwiftType,
                                makeDecoder: @escaping () throws -> NativeSwiftValue) async throws -> Decode {
        let decode = try await decoderType.resolve(.swift(.method(
            "Mercury.XPCObjectDecoder.decode<A where A: Swift.Decodable>(_: A.Type, from: __C.OS_xpc_object) throws -> A",
            as: ((NativeSwiftValue, xpc_object_t) throws -> NativeSwiftValue).self, genericArguments: [.type(type)])))
        let metatype = try type.makeMetatypeValue()
        return { object in try unsafe decode.unsafeInvoke(on: makeDecoder(), metatype, object) }
    }
}
