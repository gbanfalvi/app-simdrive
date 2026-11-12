import SimDriveNative

/// A device capability opened on first use. Once the device turns out to lack it, it stays unavailable.
@MainActor
final class LazyCapability<Service> {
    private enum State {
        case unknown, unavailable
        case available(Service)
    }

    private let open: @MainActor () async throws -> Service?
    private let isUsable: @MainActor (Service) -> Bool
    private let release: @MainActor (Service) async -> Void
    private var state = State.unknown

    /// `open` returns nil when the device lacks the capability. When it throws, the next use tries again.
    /// A service that is no longer usable, such as one whose guest connection ended, is opened again on next use.
    init(isUsable: @escaping @MainActor (Service) -> Bool = { _ in true },
         close: @escaping @MainActor (Service) async -> Void = { _ in },
         _ open: @escaping @MainActor () async throws -> Service?) {
        self.open = open
        self.isUsable = isUsable
        release = close
    }

    /// The service, opening it if needed, or nil when the device lacks it.
    func value() async throws -> Service? {
        switch state {
        case .available(let service) where isUsable(service):
            return service
        case .unavailable:
            return nil
        case .unknown, .available:
            let service = try await open()
            state = service.map { .available($0) } ?? .unavailable
            return service
        }
    }

    /// The service, or `error` when the device lacks it.
    func required(orThrow error: @autoclosure () -> SimDriveError) async throws -> Service {
        guard let service = try await value() else { throw error() }
        return service
    }

    /// Closes the open service; the next use opens it again.
    func close() async {
        guard case .available(let service) = state else { return }
        state = .unknown
        await release(service)
    }
}
