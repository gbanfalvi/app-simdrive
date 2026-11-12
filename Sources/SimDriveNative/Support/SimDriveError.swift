import Foundation

/// A stable code that names a failure in simdrive's output. Each module declares its own codes as constants.
package struct ErrorCode: RawRepresentable, Hashable, Sendable {
    package let rawValue: String

    package init(rawValue: String) { self.rawValue = rawValue }
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
    package static let guestConnection = ErrorCode(rawValue: "guest-connection")
    static let guestServiceTimeout = ErrorCode(rawValue: "guest-service-timeout")
    static let hidServiceRemoved = ErrorCode(rawValue: "hid-service-removed")
    static let keyboardEvent = ErrorCode(rawValue: "keyboard-event")
    static let keyboardReport = ErrorCode(rawValue: "keyboard-report")
    static let coreDeviceIdentity = ErrorCode(rawValue: "coredevice-identity")
    static let coreDeviceDevice = ErrorCode(rawValue: "coredevice-device")
    static let coreDeviceCapability = ErrorCode(rawValue: "coredevice-capability")
    static let coreDeviceErrorType = ErrorCode(rawValue: "coredevice-error-type")
    static let hingeObservation = ErrorCode(rawValue: "hinge-observation")
    static let hingeSnapshot = ErrorCode(rawValue: "hinge-snapshot")
    static let hingePayload = ErrorCode(rawValue: "hinge-payload")
    static let accessibilityTimeout = ErrorCode(rawValue: "accessibility-timeout")
    static let accessibilityTranslation = ErrorCode(rawValue: "accessibility-translation")
    static let guestNotification = ErrorCode(rawValue: "guest-notification")
}
