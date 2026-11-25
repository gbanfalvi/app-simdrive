import Foundation

/// A push notification's JSON payload: a file, read where the command runs, or its text, inlined from standard input.
enum PushPayload: Equatable, Sendable {
    case file(String)
    case json(String)
}

/// What `privacy` does to an app's access, as `simctl privacy` names it.
enum PrivacyAction: String, CaseIterable, Sendable {
    /// Allows access without the alert.
    case grant
    /// Denies access.
    case revoke
    /// Asks again on next use; without a bundle identifier, for every app.
    case reset

    var needsBundleID: Bool { self != .reset }
}
