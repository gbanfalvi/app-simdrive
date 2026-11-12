import Darwin
import Foundation
import SimDriveNative

/// Newline-terminated messages over a Unix domain stream socket. Each connection carries one request and its reply.
enum UnixSocket {
    private static let backlog: Int32 = 16
    /// Inline steps can make a request large; the cap stops a peer that never sends a newline.
    private static let maximumMessage = 16 << 20
    private static let readChunk = 64 << 10
    private static let newline = UInt8(ascii: "\n")

    /// Listens at `path`, replacing a socket file that nothing answers on.
    static func listen(at path: String) throws -> Int32 {
        if let existing = connect(to: path) {
            close(existing)
            throw SimDriveError(.daemonRunning, "Another daemon already listens at \(path).")
        }
        unlink(path)
        let socketDescriptor = try makeSocket()
        var address = try address(for: path)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socketDescriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, Darwin.listen(socketDescriptor, backlog) == 0 else {
            let reason = String(cString: strerror(errno))
            close(socketDescriptor)
            throw SimDriveError(.daemonSocket, "Could not listen at \(path): \(reason)")
        }
        return socketDescriptor
    }

    /// A connection to the listener at `path`, or nil when nothing listens there.
    static func connect(to path: String) -> Int32? {
        guard let socketDescriptor = try? makeSocket(), var address = try? address(for: path) else { return nil }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(socketDescriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else {
            close(socketDescriptor)
            return nil
        }
        return socketDescriptor
    }

    /// Reads until a newline or the end of the stream.
    static func readMessage(from socketDescriptor: Int32) throws -> Data {
        var message = Data()
        var buffer = [UInt8](repeating: 0, count: readChunk)
        while message.count < maximumMessage {
            let count = read(socketDescriptor, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw SimDriveError(.daemonSocket, "Reading failed: \(String(cString: strerror(errno)))") }
            guard count > 0 else { break }
            if let end = buffer[0..<count].firstIndex(of: newline) {
                message.append(contentsOf: buffer[0..<end])
                break
            }
            message.append(contentsOf: buffer[0..<count])
        }
        return message
    }

    static func writeMessage(_ message: Data, to socketDescriptor: Int32) throws {
        var bytes = [UInt8](message)
        bytes.append(newline)
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes { write(socketDescriptor, $0.baseAddress, $0.count) }
            if written < 0, errno == EINTR { continue }
            guard written > 0 else { throw SimDriveError(.daemonSocket, "Writing failed: \(String(cString: strerror(errno)))") }
            offset += written
        }
    }

    private static func makeSocket() throws -> Int32 {
        let socketDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketDescriptor >= 0 else { throw SimDriveError(.daemonSocket, "Could not create a socket.") }
        var noSignal: Int32 = 1
        setsockopt(socketDescriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        return socketDescriptor
    }

    private static func address(for path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else { throw SimDriveError(.daemonSocket, "The socket path \(path) is too long.") }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        return address
    }
}
