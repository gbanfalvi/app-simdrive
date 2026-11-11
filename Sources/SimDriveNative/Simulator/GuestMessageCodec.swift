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

    /// The `DigitizerEdge` case of a touch away from the edges.
    private static let noEdge = "none"

    private let featureKey: String
    private let messageTypeKey: String
    private let payloadKey: String
    private let encoders: [MessageType: (NativeSwiftValue) throws -> xpc_object_t]
    private let makeDigitizerEvent: (CGPoint, String, String, String) throws -> NativeSwiftValue
    private let makeButtonEvent: (UInt16, UInt16, String) throws -> NativeSwiftValue
    private let requestType: NativeSwiftType
    private let readReportData: NativeSwiftMethod<() -> Data>
    private let readCreatedService: (xpc_object_t) throws -> NativeSwiftValue
    private let orientationRequestType: NativeSwiftType
    private let orientationType: NativeSwiftType
    private let readOrientation: (xpc_object_t) throws -> GuestOrientationReading

    init(runtime: ABIRuntime) async throws {
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
        makeDigitizerEvent = { first, phase, edgeName, targetName in
            try unsafe makeDigitizer.unsafeInvoke(makePoint.unsafeInvoke(first.x, first.y), nil,
                eventType.makeEnumCase(named: phase), edge.makeEnumCase(named: edgeName), target.makeEnumCase(named: targetName))
        }
        let makeButton = try await button.resolve(.swift(.initializer("init(usagePage:usageCode:state:)",
            as: ((UInt16, UInt16, NativeSwiftValue) -> NativeSwiftValue).self, valueABIs: abis)))
        makeButtonEvent = { page, usage, state in
            try unsafe makeButton.unsafeInvoke(page, usage, buttonState.makeEnumCase(named: state))
        }

        let report = try await runtime.prepare { try CoreDeviceUniversalHID.reportABI(runtime: $0) }
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
            let nonFlat = try unsafe rawValue.unsafeInvoke(on: upright.unsafeInvoke(on: info))
            return try unsafe GuestOrientationReading(orientation: DeviceOrientation(rawValue: nonFlat),
                physical: rawValue.unsafeInvoke(on: physical.unsafeInvoke(on: info)))
        }
        readCreatedService = { reply in
            if let error = xpc_dictionary_get_value(reply, errorKey) {
                throw try unsafe readError.unsafeInvoke(on: decodeError(error))
            }
            return try unsafe readServiceID.unsafeInvoke(on: decodeCreated(reply))
        }
    }

    func message(_ type: MessageType, to feature: String, payload: NativeSwiftValue) throws -> xpc_object_t {
        let encoded = try encoders[type]!(payload)
        let message = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(message, featureKey, feature)
        xpc_dictionary_set_string(message, messageTypeKey, type.rawValue)
        xpc_dictionary_set_value(message, payloadKey, encoded)
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
        let data = try unsafe readReportData.unsafeInvoke(on: report)
        return try requestType.makeEnumCaseAndWait(named: "send", associatedValues: data, serviceID)
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
}
