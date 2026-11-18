/// Delays that the guest's input services need.
enum GuestInputTiming {
    /// The guest matches a new input service shortly after it appears, and drops events sent before.
    static let settle: Duration = .milliseconds(400)
    /// The guest drops the events of a connection that ends before it has activated them, even ones its service has
    /// confirmed handling, unless the connection outlives that confirmation by this long.
    static let drain: Duration = .milliseconds(300)
}

/// Sleeps without throwing, so a held key, touch or button is always released.
package func pause(_ duration: Duration) async {
    try? await Task.sleep(for: duration)
}
