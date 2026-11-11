import ABIBridge
import AppKit

/// Translates AppKit key events into UniversalHID reports with UniversalHIDKit's `EventObserver`, as Device Hub does.
/// UniversalHIDKit uses the system UniversalHID module and CoreDevice its bundled one, so reports cross as bytes.
@MainActor
struct KeyboardReports {
    static let systemUniversalHIDURL = URL(fileURLWithPath: "/System/Library/PrivateFrameworks/UniversalHID.framework/Versions/A/UniversalHID")
    static let universalHIDKitURL = URL(fileURLWithPath: "/System/Library/PrivateFrameworks/UniversalHIDKit.framework/Versions/A/UniversalHIDKit")

    /// An `EventObserver` with one keyboard's key and modifier state.
    struct Translator {
        fileprivate let observer: NativeSwiftValue
        fileprivate let translate: (NativeSwiftValue, NSEvent) throws -> [NativeSwiftValue]

        func reports(for event: NSEvent) throws -> [NativeSwiftValue] { try translate(observer, event) }
    }

    private let makeObserver: () throws -> NativeSwiftValue
    private let translate: (NativeSwiftValue, NSEvent) throws -> [NativeSwiftValue]

    init(runtime: ABIRuntime) async throws {
        try await NativeFrameworks.load(Self.universalHIDKitURL.path)
        let system = Self.systemUniversalHIDURL
        let eventType = try await runtime.resolve(.swift(.type("UniversalHID.HIDEventType")), in: .path(system), loading: .loadedOnly)
        let maskType = try await runtime.resolve(.swift(.type("UniversalHID.HIDEventMask")), in: .path(system), loading: .loadedOnly)
        let observerType = try await runtime.resolve(.swift(.type("UniversalHIDKit.EventObserver",
            genericArguments: [.type(NSEvent.self)])), in: .path(Self.universalHIDKitURL), loading: .loadedOnly)
        let systemReport = try await runtime.resolve(.swift(.type("UniversalHID.HIDReport")), in: .path(system), loading: .loadedOnly)
        try await HIDService.loadUniversalHID()
        let coreDeviceReport = try await runtime.prepare { try HIDService.reportABI(runtime: $0) }
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
        let probe = try unsafe process.unsafeInvoke(on: observe(), Self.sampleKey(.keyDown))
        let count = try await probe.type.resolve(.swift(.getter("count", as: (() -> Int).self)))
        let element = try await probe.type.resolve(.swift(.getter("Swift.Array.subscript.getter : (Swift.Int) -> A",
            as: ((Int) -> NativeSwiftValue).self)))
        translate = { observer, event in
            let results = try unsafe process.unsafeInvoke(on: observer, event)
            let reports = try unsafe count.unsafeInvoke(on: results)
            return try (0..<reports).map { index in
                let result = try unsafe element.unsafeInvoke(on: results, index)
                return try result.withCopy { value in
                    guard let (report, _) = value as? (Any, UInt64) else {
                        throw NativeError("keyboard-report", "UniversalHIDKit returned an unexpected event report.")
                    }
                    return try unsafe makeReport.unsafeInvoke(readData.unsafeInvoke(on: report))
                }
            }
        }
        self.makeObserver = observe
    }

    func makeTranslator() throws -> Translator {
        Translator(observer: try makeObserver(), translate: translate)
    }

    static func sampleKey(_ type: NSEvent.EventType) throws -> NSEvent {
        guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0) else {
            throw NativeError("keyboard-sample", "AppKit could not create a sample key event.")
        }
        return event
    }
}

/// What a guest hardware keyboard needs: CoreDevice's generic main keyboard descriptor and the key report translator.
/// Preparing them resolves many symbols, so one instance serves every keyboard connection of a process.
@MainActor
package struct KeyboardBindings {
    private let reports: KeyboardReports
    private let makeMainKeyboardDescriptor: () throws -> NativeSwiftValue

    package init(runtime: ABIRuntime = .shared) async throws {
        reports = try await runtime.prepare { try await KeyboardReports(runtime: $0) }
        guard try !reports.makeTranslator().reports(for: KeyboardReports.sampleKey(.keyDown)).isEmpty else {
            throw NativeError("keyboard-report", "UniversalHIDKit did not report a key press.")
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

    func makeTranslator() throws -> KeyboardReports.Translator { try reports.makeTranslator() }

    func mainKeyboardDescriptor() throws -> NativeSwiftValue { try makeMainKeyboardDescriptor() }
}
