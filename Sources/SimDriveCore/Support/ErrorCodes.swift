import SimDriveNative

extension ErrorCode {
    static let usage = ErrorCode(rawValue: "usage")
    static let ambiguousDevice = ErrorCode(rawValue: "ambiguous-device")
    static let notBooted = ErrorCode(rawValue: "not-booted")
    static let simulatorStarting = ErrorCode(rawValue: "simulator-starting", retryable: true)
    static let notADeviceCommand = ErrorCode(rawValue: "not-a-device-command")
    static let developerDirectory = ErrorCode(rawValue: "developer-directory")
    static let simctl = ErrorCode(rawValue: "simctl")
    static let toolTimeout = ErrorCode(rawValue: "tool-timeout", retryable: true)
    static let devicectl = ErrorCode(rawValue: "devicectl")
    static let launchNotFrontmost = ErrorCode(rawValue: "launch-not-frontmost", retryable: true)
    static let appNotInstalled = ErrorCode(rawValue: "app-not-installed")
    static let appInvalid = ErrorCode(rawValue: "app-invalid")
    static let noLogScope = ErrorCode(rawValue: "no-log-scope")
    static let logTimeout = ErrorCode(rawValue: "log-timeout")
    static let logRead = ErrorCode(rawValue: "log-read")
    static let unknownKey = ErrorCode(rawValue: "unknown-key")
    static let unsupportedCharacter = ErrorCode(rawValue: "unsupported-character")
    static let noTouchscreen = ErrorCode(rawValue: "no-touchscreen")
    static let noScreenshot = ErrorCode(rawValue: "no-screenshot")
    static let staleScreenshot = ErrorCode(rawValue: "stale-screenshot")
    static let screenshot = ErrorCode(rawValue: "screenshot")
    static let screenshotRead = ErrorCode(rawValue: "screenshot-read")
    static let screenshotScale = ErrorCode(rawValue: "screenshot-scale")
    static let screenshotWrite = ErrorCode(rawValue: "screenshot-write")
    static let singleDisplay = ErrorCode(rawValue: "single-display")
    static let unknownDisplay = ErrorCode(rawValue: "unknown-display")
    static let orientationUnsupported = ErrorCode(rawValue: "orientation-unsupported")
    static let pasteboardUnsupported = ErrorCode(rawValue: "pasteboard-unsupported")
    static let postureUnsupported = ErrorCode(rawValue: "posture-unsupported")
    static let postureTimeout = ErrorCode(rawValue: "posture-timeout", retryable: true)
    static let splitUnsupported = ErrorCode(rawValue: "split-unsupported")
    static let splitSideUnknown = ErrorCode(rawValue: "split-side-unknown")
    static let splitDropped = ErrorCode(rawValue: "split-dropped", retryable: true)
    static let accessibilityUnsupported = ErrorCode(rawValue: "accessibility-unsupported")
    static let ambiguousElement = ErrorCode(rawValue: "ambiguous-element")
    static let elementOffscreen = ErrorCode(rawValue: "element-offscreen")
    static let elementStillShown = ErrorCode(rawValue: "element-still-shown")
    static let elementCovered = ErrorCode(rawValue: "element-covered")
    static let appAccessibilityOff = ErrorCode(rawValue: "app-accessibility-off")
    static let settingUnsupported = ErrorCode(rawValue: "setting-unsupported")
    static let guestPreferences = ErrorCode(rawValue: "guest-preferences")
    static let stepInvalid = ErrorCode(rawValue: "step-invalid")
    /// Retryable when the failed step's own error is; see `stepFailed(retryable:)`.
    static let stepFailed = ErrorCode(rawValue: "step-failed")
    static let badRequest = ErrorCode(rawValue: "bad-request")
    static let staleDaemon = ErrorCode(rawValue: "stale-daemon", retryable: true)
    static let daemonEnded = ErrorCode(rawValue: "daemon-ended", retryable: true)
    static let daemonStart = ErrorCode(rawValue: "daemon-start", retryable: true)
    static let daemonRunning = ErrorCode(rawValue: "daemon-running")
    static let daemonSocket = ErrorCode(rawValue: "daemon-socket")
    static let stateDirectory = ErrorCode(rawValue: "state-directory")

    /// `step-failed`, retryable as the step's own error was, so `run` reports whether running it again may help.
    static func stepFailed(retryable: Bool) -> ErrorCode {
        ErrorCode(rawValue: stepFailed.rawValue, retryable: retryable)
    }
}

extension SimDriveError {
    /// A malformed command line, with a pointer to the help.
    static func usage(_ message: String) -> SimDriveError {
        SimDriveError(.usage, "\(message). Run `simdrive help` for usage.")
    }
}
