import ABIBridge
import Foundation
import XPC

/// A setting the guest applies itself, as the Settings app does, through a CoreDevice action pair.
package enum GuestSetting: String, CaseIterable, Sendable {
    case voiceOver = "VoiceOver"
    case colorFilter = "ColorFilter"
    case reduceMotion = "ReduceMotion"
    case showBorders = "ShowBorders"
    case reduceTransparency = "ReduceTransparency"

    var getDeclaration: String { "Get\(rawValue)ActionDeclaration" }
    var setDeclaration: String { "Set\(rawValue)ActionDeclaration" }
}

/// Reads and changes guest settings by sending CoreDevice's setting actions straight to the guest services that perform
/// them, with no CoreDevice record. Inputs and outputs are the actions' own types, carried as JSON objects.
@MainActor
package final class GuestSettingActions {
    private let guest: SimulatorGuest
    private let udid: String
    private var actions: [String: Action] = [:]
    private var connections: [String: GuestConnection] = [:]

    private init(guest: SimulatorGuest, udid: String) {
        self.guest = guest
        self.udid = udid
    }

    package static func open(guest: SimulatorGuest, udid: String) -> GuestSettingActions {
        GuestSettingActions(guest: guest, udid: udid)
    }

    /// Whether the guest has the service that performs the setting's actions.
    package func supports(_ setting: GuestSetting) async throws -> Bool {
        guest.hasService(try await action(setting.setDeclaration, readsOutput: false).feature)
    }

    /// The setting's current value, as its Get action's output encodes to JSON.
    package func value(of setting: GuestSetting) async throws -> [String: Any] {
        try await perform(setting.getDeclaration, input: [:], readsOutput: true)
    }

    /// Applies `input`, the JSON of the setting's Set action input.
    package func set(_ setting: GuestSetting, input: [String: Any]) async throws {
        _ = try await perform(setting.setDeclaration, input: input, readsOutput: false)
    }

    /// The JSON of a `DeviceColorFilter.FilterType` member, such as `deuteranopia`, as the color filter's input takes it.
    package func colorFilterType(_ member: String) async throws -> Any {
        let type = try await ABIRuntime.shared.resolve(.swift(.type("CoreDeviceUtilities.DeviceColorFilter.FilterType")))
        let getter = try await type.resolve(.swift(.staticGetter(member, as: (() -> NativeSwiftValue).self,
            valueABIs: [type: try .opaque(named: type.name)])))
        return try JSONSerialization.jsonObject(with: Action.json(of: unsafe getter.unsafeInvoke()))
    }

    private func action(_ declaration: String, readsOutput: Bool) async throws -> Action {
        if let existing = actions[declaration] { return existing }
        let action = try await Action(declaration: declaration, readsOutput: readsOutput)
        actions[declaration] = action
        return action
    }

    private func perform(_ declaration: String, input: [String: Any], readsOutput: Bool) async throws -> [String: Any] {
        let action = try await action(declaration, readsOutput: readsOutput)
        let connection: GuestConnection
        if let existing = connections[action.feature], !existing.hasFailed { connection = existing } else {
            guard guest.hasService(action.feature) else {
                throw SimDriveError(.guestSetting, "The guest has no \(action.feature) service.")
            }
            connection = try await guest.connection(to: action.feature)
            connections[action.feature] = connection
        }
        let message = try action.message(udid: udid, input: JSONSerialization.data(withJSONObject: input))
        return try action.output(from: await connection.reply(to: message))
    }

    /// One action's identifier, the guest service that performs it, and its input and output codecs.
    private struct Action {
        private static let coreDeviceBundle = "/Library/Developer/PrivateFrameworks/CoreDevice.framework"

        let feature: String
        private let identifier: String
        private let encodeInput: (Data) throws -> xpc_object_t
        private let decodeOutput: ((xpc_object_t) throws -> Data)?

        init(declaration: String, readsOutput: Bool) async throws {
            let runtime = ABIRuntime.shared
            try await NativeFrameworks.load(NativeFrameworks.coreDevicePath)
            let name = "CoreDeviceUtilities." + declaration
            let type = try await runtime.resolve(.swift(.type(name)))
            identifier = try await unsafe type.resolve(.swift(.staticGetter("identifier", as: (() -> String).self))).unsafeInvoke()
            feature = try await Self.feature(of: type)
            let inputType = try await runtime.resolve(.swift(.type(name + ".Input")))
            let decodeJSON = try await Self.jsonDecode(inputType, runtime: runtime)
            let encoder = try await runtime.resolve(.swift(.type("Mercury.XPCObjectEncoder")))
            let makeEncoder = try await encoder.resolve(.swift(.initializer("init()", as: (() -> NativeSwiftValue).self)))
            let encode = try await encoder.resolve(.swift(.method(
                "Mercury.XPCObjectEncoder.encode<A where A: Swift.Encodable>(A) throws -> __C.OS_xpc_object",
                as: ((NativeSwiftValue) throws -> xpc_object_t).self, genericArguments: [.type(inputType)])))
            encodeInput = { json in try unsafe encode.unsafeInvoke(on: makeEncoder.unsafeInvoke(), decodeJSON(json)) }
            guard readsOutput else {
                decodeOutput = nil
                return
            }
            let outputType = try await runtime.resolve(.swift(.type(name + ".Output")))
            let decoder = try await runtime.resolve(.swift(.type("Mercury.XPCObjectDecoder")))
            let makeDecoder = try await decoder.resolve(.swift(.initializer("init()", as: (() -> NativeSwiftValue).self)))
            let decode = try await decoder.resolve(.swift(.method(
                "Mercury.XPCObjectDecoder.decode<A where A: Swift.Decodable>(_: A.Type, from: __C.OS_xpc_object) throws -> A",
                as: ((NativeSwiftValue, xpc_object_t) throws -> NativeSwiftValue).self, genericArguments: [.type(outputType)])))
            let metatype = try outputType.makeMetatypeValue()
            decodeOutput = { object in try Self.json(of: unsafe decode.unsafeInvoke(on: makeDecoder.unsafeInvoke(), metatype, object)) }
        }

        /// The guest service named by the declaration's `executionLocation`, which CoreDeviceUtilities 699.2 (Xcode 27.3)
        /// moved from each declaration to the `ActionDeclaration` protocol.
        private static func feature(of type: NativeSwiftType) async throws -> String {
            let location: NativeSwiftValue
            do {
                location = try await unsafe type.resolve(.swift(.staticGetter("executionLocation",
                    as: (() -> NativeSwiftValue).self))).unsafeInvoke()
            } catch ABIResolutionError.declarationNotFound {
                location = try await unsafe type.resolve(.swift(.staticGetter("CoreDeviceUtilities.ActionDeclaration.executionLocation",
                    as: (() -> NativeSwiftValue).self))).unsafeInvoke()
            }
            guard let payload = try await location.copyEnumPayload(forCase: "remoteDevice"),
                  let feature = try payload.withCopy({ $0 as? String }) else {
                throw SimDriveError(.guestSetting, "\(type.name) does not run in a guest service.")
            }
            return feature
        }

        /// Decodes JSON into a native `type` with Foundation's `JSONDecoder`, resolved for that type.
        private static func jsonDecode(_ type: NativeSwiftType, runtime: ABIRuntime) async throws -> (Data) throws -> NativeSwiftValue {
            let jsonDecoder = try await runtime.resolve(.swift(.type(String(reflecting: JSONDecoder.self))))
            let data = try await runtime.resolve(.swift(.type("Foundation.Data")))
            let decode = try await jsonDecoder.resolve(.swift(.method("decode(_:from:)",
                as: ((NativeSwiftValue, Data) throws -> NativeSwiftValue).self, genericArguments: [.type(type)],
                valueABIs: [data: try .structure(named: data.name, fields: [.uint64, .uint64])])))
            let metatype = try type.makeMetatypeValue()
            return { json in try unsafe decode.unsafeInvoke(on: JSONDecoder(), metatype, json) }
        }

        static func json(of value: NativeSwiftValue) throws -> Data {
            try value.withCopy { value in
                guard let encodable = value as? any Encodable else {
                    throw SimDriveError(.guestMessage, "A CoreDevice setting value is not encodable.")
                }
                return try JSONEncoder().encode(encodable)
            }
        }

        func message(udid: String, input: Data) throws -> xpc_object_t {
            let message = xpc_dictionary_create(nil, nil, 0)
            xpc_dictionary_set_string(message, "CoreDevice.actionIdentifier", identifier)
            xpc_dictionary_set_string(message, "CoreDevice.deviceIdentifier", udid)
            xpc_dictionary_set_string(message, "CoreDevice.invocationIdentifier", UUID().uuidString)
            xpc_dictionary_set_int64(message, "CoreDevice.CoreDeviceDDIProtocolVersion", 1)
            xpc_dictionary_set_value(message, "CoreDevice.coreDeviceVersion", try Self.coreDeviceVersion())
            xpc_dictionary_set_value(message, "CoreDevice.input", try encodeInput(input))
            return message
        }

        /// The host's CoreDevice version, in the shape of CoreDevice's `Version`.
        private static func coreDeviceVersion() throws -> xpc_object_t {
            guard let version = Bundle(path: coreDeviceBundle)?.object(forInfoDictionaryKey: "CFBundleVersion") as? String else {
                throw SimDriveError(.guestSetting, "CoreDevice's version is unavailable.")
            }
            let parts = version.split(separator: ".").compactMap { UInt64($0) }
            let components = xpc_array_create(nil, 0)
            for part in parts { xpc_array_append_value(components, xpc_uint64_create(part)) }
            let value = xpc_dictionary_create(nil, nil, 0)
            xpc_dictionary_set_value(value, "components", components)
            xpc_dictionary_set_int64(value, "originalComponentsCount", Int64(parts.count))
            xpc_dictionary_set_string(value, "stringValue", version)
            return value
        }

        func output(from reply: xpc_object_t) throws -> [String: Any] {
            if let error = xpc_dictionary_get_value(reply, "CoreDevice.error") {
                let description = unsafe xpc_dictionary_get_value(error, "userInfo")
                    .flatMap { unsafe xpc_dictionary_get_string($0, NSLocalizedDescriptionKey) }
                    .map { unsafe String(cString: $0) }
                let code = xpc_dictionary_get_int64(error, "code")
                let reason = description.map { $0.hasSuffix(".") ? $0 : $0 + "." } ?? "no description."
                throw SimDriveError(.guestSetting, "The guest refused the setting (CoreDevice error \(code)): \(reason)")
            }
            guard let decodeOutput else { return [:] }
            guard let output = xpc_dictionary_get_value(reply, "CoreDevice.output") else {
                throw SimDriveError(.guestSetting, "The guest's reply has no output.")
            }
            return try JSONSerialization.jsonObject(with: decodeOutput(output)) as? [String: Any] ?? [:]
        }
    }
}
