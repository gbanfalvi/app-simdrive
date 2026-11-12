/// Delays that the guest's input services need.
enum GuestInputTiming {
    /// The guest matches a new input service shortly after it appears, and drops events sent before.
    static let settle: Duration = .milliseconds(400)
    /// The guest drops the events of a connection that ends before it has activated them. A Duo's panels need
    /// longer than 500 ms.
    static let drain: Duration = .milliseconds(1000)
}

/// Sleeps without throwing, so a held key, touch or button is always released.
package func pause(_ duration: Duration) async {
    try? await Task.sleep(for: duration)
}
