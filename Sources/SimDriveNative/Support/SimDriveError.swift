import Foundation

/// A stable code that names a failure in simdrive's output. Each module declares its own codes as constants.
package struct ErrorCode: RawRepresentable, Hashable, Sendable {
    package let rawValue: String
    /// Whether running the same command again, unchanged, may succeed: the simulator was busy or slow, rather than the
    /// command or the device being wrong. The output's `retry` field says so.
    package let isRetryable: Bool

    package init(rawValue: String) { self.init(rawValue: rawValue, retryable: false) }

    package init(rawValue: String, retryable: Bool) {
        self.rawValue = rawValue
        isRetryable = retryable
    }

    package static func == (lhs: ErrorCode, rhs: ErrorCode) -> Bool { lhs.rawValue == rhs.rawValue }

    package func hash(into hasher: inout Hasher) { hasher.combine(rawValue) }
}

/// A failure that simdrive reports by code and message.
package struct SimDriveError: LocalizedError, Equatable, Sendable {
    package let code: ErrorCode
    package let message: String

    package init(_ code: ErrorCode, _ message: String) {
        self.code = code
        self.message = message
    }

    package var errorDescription: String? { message }
}

extension ErrorCode {
    static let frameworkLoad = ErrorCode(rawValue: "framework-load")
    static let coreSimulator = ErrorCode(rawValue: "core-simulator")
    static let deviceSet = ErrorCode(rawValue: "device-set")
    static let deviceMissing = ErrorCode(rawValue: "device-missing")
    static let guestLookup = ErrorCode(rawValue: "guest-lookup")
    static let guestEndpoint = ErrorCode(rawValue: "guest-endpoint")
    static let guestMessage = ErrorCode(rawValue: "guest-message")
    /// A guest service connection ended. Its services are gone, so its owner must open a new one.
    package static let guestConnection = ErrorCode(rawValue: "guest-connection", retryable: true)
    static let guestServiceTimeout = ErrorCode(rawValue: "guest-service-timeout", retryable: true)
    static let hidServiceRemoved = ErrorCode(rawValue: "hid-service-removed")
    static let keyboardEvent = ErrorCode(rawValue: "keyboard-event")
    static let keyboardReport = ErrorCode(rawValue: "keyboard-report")
    static let coreDeviceIdentity = ErrorCode(rawValue: "coredevice-identity")
    static let coreDeviceDevice = ErrorCode(rawValue: "coredevice-device")
    static let coreDeviceCapability = ErrorCode(rawValue: "coredevice-capability")
    static let coreDeviceErrorType = ErrorCode(rawValue: "coredevice-error-type")
    static let coreDeviceTimeout = ErrorCode(rawValue: "coredevice-timeout", retryable: true)
    static let coreDeviceNotReady = ErrorCode(rawValue: "coredevice-not-ready", retryable: true)
    static let hingeObservation = ErrorCode(rawValue: "hinge-observation")
    static let hingeSnapshot = ErrorCode(rawValue: "hinge-snapshot")
    static let hingePayload = ErrorCode(rawValue: "hinge-payload")
    static let accessibilityTimeout = ErrorCode(rawValue: "accessibility-timeout", retryable: true)
    static let accessibilityUnavailable = ErrorCode(rawValue: "accessibility-unavailable")
    package static let noElement = ErrorCode(rawValue: "no-element")
    /// The translator gave no element, or the frontmost app had no frame.
    package static let accessibilityTranslation = ErrorCode(rawValue: "accessibility-translation")
    static let guestNotification = ErrorCode(rawValue: "guest-notification")
    static let interfaceOption = ErrorCode(rawValue: "interface-option")
    static let screenAdapter = ErrorCode(rawValue: "screen-adapter")
    static let screenAdapterTimeout = ErrorCode(rawValue: "screen-adapter-timeout", retryable: true)
}
