import ABIBridge
import AppKit

/// What a guest hardware keyboard needs: CoreDevice's main keyboard descriptor, and UniversalHIDKit's `EventObserver`,
/// which translates AppKit key events into reports as Device Hub does. Preparing them resolves many symbols, so one
/// instance serves every keyboard of a process.
@MainActor
package struct KeyboardBindings {
    private static let systemUniversalHIDURL = URL(fileURLWithPath: "/System/Library/PrivateFrameworks/UniversalHID.framework/Versions/A/UniversalHID")
    private static let universalHIDKitURL = URL(fileURLWithPath: "/System/Library/PrivateFrameworks/UniversalHIDKit.framework/Versions/A/UniversalHIDKit")

    private let makeObserver: () throws -> NativeSwiftValue
    private let translate: (NativeSwiftValue, NSEvent) throws -> [NativeSwiftValue]
    private let makeMainKeyboardDescriptor: () throws -> NativeSwiftValue

    package init(runtime: ABIRuntime = .shared) async throws {
        let translation = try await runtime.prepare { try await Self.translation(runtime: $0) }
        makeObserver = translation.makeObserver
        translate = translation.translate
        guard try !translate(makeObserver(), Self.sampleKey(.keyDown)).isEmpty else {
            throw SimDriveError(.keyboardReport, "UniversalHIDKit did not report a key press.")
        }
        let descriptorType = try await runtime.resolve(.swift(.type("CoreDevice.HIDServiceDescriptor")))
        let descriptorABIs: [NativeSwiftType: NativeType] = [descriptorType: try .opaque(named: descriptorType.name)]
        let setSoftwareKeyboard = try await descriptorType.resolve(.swift(.method("setSoftwareKeyboard(_:)",
            as: ((Bool) -> Bool).self, valueABIs: descriptorABIs, receiverABI: descriptorABIs[descriptorType], receiver: .mutating)))
        let mainKeyboard = try await descriptorType.resolve(.swift(.staticMethod("mainKeyboard()",
            as: (() -> NativeSwiftValue).self, valueABIs: descriptorABIs)))
        // The guest takes input only from a hardware keyboard, which the main keyboard is not by default.
        makeMainKeyboardDescriptor = {
            let descriptor = try unsafe mainKeyboard.unsafeInvoke()
            _ = try unsafe setSoftwareKeyboard.unsafeInvoke(on: descriptor, false)
            return descriptor
        }
    }

    func makeTranslator() throws -> KeyReportTranslator {
        KeyReportTranslator(observer: try makeObserver(), translate: translate)
    }

    func mainKeyboardDescriptor() throws -> NativeSwiftValue { try makeMainKeyboardDescriptor() }

    /// UniversalHIDKit uses the system UniversalHID module and CoreDevice its bundled one, so reports cross as bytes.
    private static func translation(runtime: ABIRuntime) async throws
        -> (makeObserver: () throws -> NativeSwiftValue, translate: (NativeSwiftValue, NSEvent) throws -> [NativeSwiftValue]) {
        try await NativeFrameworks.load(universalHIDKitURL.path)
        let system = systemUniversalHIDURL
        let eventType = try await runtime.resolve(.swift(.type("UniversalHID.HIDEventType")), in: .path(system), loading: .loadedOnly)
        let maskType = try await runtime.resolve(.swift(.type("UniversalHID.HIDEventMask")), in: .path(system), loading: .loadedOnly)
        let observerType = try await runtime.resolve(.swift(.type("UniversalHIDKit.EventObserver",
            genericArguments: [.type(NSEvent.self)])), in: .path(universalHIDKitURL), loading: .loadedOnly)
        let systemReport = try await runtime.resolve(.swift(.type("UniversalHID.HIDReport")), in: .path(system), loading: .loadedOnly)
        try await CoreDeviceUniversalHID.load()
        let coreDeviceReport = try await runtime.prepare { try CoreDeviceUniversalHID.reportABI(runtime: $0) }
        let data = try await runtime.resolve(.swift(.type("Foundation.Data")))
        let dataABI = try NativeType.structure(named: data.name, fields: [.uint64, .uint64])
        // These single-field and Data-wrapping values pass their stored words directly, as DeviceKit passes them.
        let systemReportABI = try NativeType.structure(named: systemReport.name, fields: [.uint64, .uint64])
        let systemABIs: [NativeSwiftType: NativeType] = [
            eventType: try .structure(named: eventType.name, fields: [.uint32]),
            maskType: try .structure(named: maskType.name, fields: [.uint64]),
            systemReport: systemReportABI,
            data: dataABI,
        ]
        let maskValue = try await eventType.resolve(.swift(.getter("maskValue", as: (() -> UInt).self,
            valueABIs: systemABIs, receiverABI: systemABIs[eventType])))
        let makeMask = try await maskType.resolve(.swift(.initializer("init(rawValue:)", as: ((UInt) -> NativeSwiftValue).self,
            valueABIs: systemABIs)))
        let makeObserver = try await observerType.resolve(.swift(.initializer("init(eventMask:)",
            as: ((NativeSwiftValue) -> NativeSwiftValue).self, valueABIs: systemABIs)))
        let process = try await observerType.resolve(.swift(.method("processEvent(_:)", as: ((NSEvent) -> NativeSwiftValue).self,
            valueABIs: systemABIs)))
        let keyboard = try await eventType.resolve(.swift(.staticGetter("keyboard", as: (() -> NativeSwiftValue).self,
            valueABIs: systemABIs)))
        let mask = try unsafe maskValue.unsafeInvoke(on: keyboard.unsafeInvoke())
        let readData = try await systemReport.resolve(.swift(.getter("data", as: (() -> Data).self,
            valueABIs: systemABIs, receiverABI: systemReportABI)))
        let makeReport = try await coreDeviceReport.type.resolve(.swift(.initializer("init(data:)",
            as: ((Data) -> NativeSwiftValue).self, valueABIs: [coreDeviceReport.type: coreDeviceReport.abi, data: dataABI])))
        // The initializer consumes its mask, so each observer gets its own.
        let observe = { try unsafe makeObserver.unsafeInvoke(makeMask.unsafeInvoke(mask)) }

        // A result is an array of (report, senderID) whose element type comes from the system module.
        let probe = try unsafe process.unsafeInvoke(on: observe(), sampleKey(.keyDown))
        let count = try await probe.type.resolve(.swift(.getter("count", as: (() -> Int).self)))
        let element = try await probe.type.resolve(.swift(.getter("Swift.Array.subscript.getter : (Swift.Int) -> A",
            as: ((Int) -> NativeSwiftValue).self)))
        let translate = { (observer: NativeSwiftValue, event: NSEvent) throws -> [NativeSwiftValue] in
            let results = try unsafe process.unsafeInvoke(on: observer, event)
            let reports = try unsafe count.unsafeInvoke(on: results)
            return try (0..<reports).map { index in
                let result = try unsafe element.unsafeInvoke(on: results, index)
                return try result.withCopy { value in
                    guard let (report, _) = value as? (Any, UInt64) else {
                        throw SimDriveError(.keyboardReport, "UniversalHIDKit returned an unexpected event report.")
                    }
                    return try unsafe makeReport.unsafeInvoke(readData.unsafeInvoke(on: report))
                }
            }
        }
        return (observe, translate)
    }

    private static func sampleKey(_ type: NSEvent.EventType) throws -> NSEvent {
        guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0) else {
            throw SimDriveError(.keyboardEvent, "AppKit could not create a sample key event.")
        }
        return event
    }
}

/// An `EventObserver` with one keyboard's key and modifier state.
struct KeyReportTranslator {
    fileprivate let observer: NativeSwiftValue
    fileprivate let translate: (NativeSwiftValue, NSEvent) throws -> [NativeSwiftValue]

    func reports(for event: NSEvent) throws -> [NativeSwiftValue] { try translate(observer, event) }
}

/// CoreDevice's bundled UniversalHID module, whose `HIDReport` its HID services take. The system has another of that name.
enum CoreDeviceUniversalHID {
    private static let url = URL(fileURLWithPath: "/Library/Developer/PrivateFrameworks/CoreDevice.framework/Versions/A/Frameworks/UniversalHID.framework/Versions/A/UniversalHID")

    static func load() async throws {
        try await NativeFrameworks.load(url.path)
    }

    /// `HIDReport` wraps the report's `Data`, whose two words its exported members pass directly. Needs ``load()`` first.
    static func reportABI(runtime: ABIRuntime) throws -> (type: NativeSwiftType, abi: NativeType) {
        let type = try runtime.resolveAndWait(.swift(.type("UniversalHID.HIDReport")), in: .path(url), loading: .loadedOnly)
        return (type, try .structure(named: type.name, fields: [.uint64, .uint64]))
    }
}
