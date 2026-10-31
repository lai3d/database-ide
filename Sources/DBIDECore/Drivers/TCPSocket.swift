import Darwin
import Foundation

/// A blocking TCP socket with a buffered reader. Used from a driver's serial queue;
/// `shutdown()` may be called from any thread to abort a blocked read.
final class TCPSocket: @unchecked Sendable {
    private var fd: Int32 = -1
    private var buffer: [UInt8] = []
    private var bufferIndex = 0
    private let lock = NSLock()

    init(host: String, port: Int, timeout: TimeInterval = 10) throws {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP
        var result: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo(host, String(port), &hints, &result)
        guard rc == 0, let first = result else {
            throw DatabaseError("Cannot resolve host '\(host)': \(String(cString: gai_strerror(rc)))")
        }
        defer { freeaddrinfo(result) }

        var lastError = "no addresses"
        var info: UnsafeMutablePointer<addrinfo>? = first
        while let ai = info {
            info = ai.pointee.ai_next
            let s = socket(ai.pointee.ai_family, ai.pointee.ai_socktype, ai.pointee.ai_protocol)
            if s < 0 { continue }
            var one: Int32 = 1
            setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(s, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
            if let err = Self.connect(s, ai.pointee.ai_addr, ai.pointee.ai_addrlen, timeout: timeout) {
                lastError = err
                Darwin.close(s)
                continue
            }
            fd = s
            return
        }
        throw DatabaseError("Cannot connect to \(host):\(port): \(lastError)")
    }

    /// Non-blocking connect + poll so an unreachable host fails within `timeout`.
    private static func connect(
        _ s: Int32, _ addr: UnsafeMutablePointer<sockaddr>?, _ len: socklen_t, timeout: TimeInterval
    ) -> String? {
        let flags = fcntl(s, F_GETFL, 0)
        _ = fcntl(s, F_SETFL, flags | O_NONBLOCK)
        defer { _ = fcntl(s, F_SETFL, flags) }
        if Darwin.connect(s, addr, len) == 0 { return nil }
        guard errno == EINPROGRESS else { return String(cString: strerror(errno)) }
        var pfd = pollfd(fd: s, events: Int16(POLLOUT), revents: 0)
        let n = poll(&pfd, 1, Int32(timeout * 1000))
        if n == 0 { return "timed out" }
        if n < 0 { return String(cString: strerror(errno)) }
        var err: Int32 = 0
        var errLen = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(s, SOL_SOCKET, SO_ERROR, &err, &errLen)
        return err == 0 ? nil : String(cString: strerror(err))
    }

    private var currentFD: Int32 {
        lock.lock()
        defer { lock.unlock() }
        return fd
    }

    func write(_ bytes: [UInt8]) throws {
        var offset = 0
        while offset < bytes.count {
            let fd = currentFD
            guard fd >= 0 else { throw DatabaseError("Connection closed") }
            let n = bytes[offset...].withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
            if n < 0 {
                if errno == EINTR { continue }
                throw DatabaseError("Write failed: \(String(cString: strerror(errno)))")
            }
            offset += n
        }
    }

    private func fill() throws {
        if bufferIndex > 0 && bufferIndex == buffer.count {
            buffer.removeAll(keepingCapacity: true)
            bufferIndex = 0
        }
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let fd = currentFD
            guard fd >= 0 else { throw DatabaseError("Connection closed") }
            let n = chunk.withUnsafeMutableBytes { Darwin.recv(fd, $0.baseAddress, $0.count, 0) }
            if n > 0 {
                buffer.append(contentsOf: chunk[0..<n])
                return
            }
            if n == 0 { throw DatabaseError("Server closed the connection") }
            if errno == EINTR { continue }
            throw DatabaseError("Read failed: \(String(cString: strerror(errno)))")
        }
    }

    func read(_ count: Int) throws -> [UInt8] {
        while buffer.count - bufferIndex < count { try fill() }
        defer { bufferIndex += count }
        return Array(buffer[bufferIndex..<bufferIndex + count])
    }

    /// Unblocks any pending read/write; subsequent I/O fails.
    func shutdown() {
        lock.lock()
        defer { lock.unlock() }
        if fd >= 0 { Darwin.shutdown(fd, SHUT_RDWR) }
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
    }

    deinit { close() }
}
