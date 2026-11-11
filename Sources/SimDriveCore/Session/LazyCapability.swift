/// A device capability opened on first use. Once the device turns out to lack it, it stays unavailable.
@MainActor
final class LazyCapability<Service> {
    private enum State {
        case unknown, unavailable
        case available(Service)
    }

    private let open: @MainActor () async throws -> Service?
    private var state = State.unknown

    /// `open` returns nil when the device lacks the capability. When it throws, the next use tries again.
    init(_ open: @escaping @MainActor () async throws -> Service?) {
        self.open = open
    }

    /// The service, opening it if needed, or nil when the device lacks it.
    func value() async throws -> Service? {
        switch state {
        case .available(let service):
            return service
        case .unavailable:
            return nil
        case .unknown:
            let service = try await open()
            state = service.map { .available($0) } ?? .unavailable
            return service
        }
    }

    /// The service if it is already open.
    var existing: Service? {
        guard case .available(let service) = state else { return nil }
        return service
    }
}
