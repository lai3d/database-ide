import Foundation
import Network
import Security

/// Plaintext exchange performed below TLS before the handshake starts
/// (PostgreSQL SSLRequest, MySQL greeting + SSL request packet).
final class TLSPreamble: @unchecked Sendable {
    enum Step {
        /// Send bytes.
        case write([UInt8])
        /// Read exactly n bytes, then decide what to do next.
        case read(Int, ([UInt8]) throws -> [Step])
    }

    var steps: [Step]
    /// Set by a step to abort before TLS (e.g. the server refused SSL).
    var refusal: Error?
    /// Bytes the preamble consumed that the driver still needs (MySQL greeting).
    var captured: [UInt8] = []

    init(_ steps: [Step]) { self.steps = steps }
}

/// TLS 1.2 / 1.3 via Network.framework, wrapped as a blocking ByteStream.
/// An optional preamble runs in a framer *below* TLS so in-protocol STARTTLS works.
final class NWTLSStream: ByteStream, @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "dbide.tls")
    private var buffer: [UInt8] = []
    private var index = 0
    private(set) var negotiatedDescription = "TLS"
    private var closed = false

    init(host: String, port: Int, options: TLSOptions, preamble: TLSPreamble? = nil, alpn: [String] = [], timeout: TimeInterval = 15) throws {
        let serverName = options.serverName ?? host
        let tls = NWProtocolTLS.Options()
        let sec = tls.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv12)
        if !Self.isIPAddress(serverName) { sec_protocol_options_set_tls_server_name(sec, serverName) }
        for proto in alpn { sec_protocol_options_add_tls_application_protocol(sec, proto) }
        let verifyMode = options.mode
        let anchors = try options.rootCertificatePath.flatMap { $0.isEmpty ? nil : try TLSStream.loadCertificates(($0 as NSString).expandingTildeInPath) }
        sec_protocol_options_set_verify_block(sec, { _, trustRef, complete in
            guard verifyMode == .verifyCA || verifyMode == .verifyFull else { return complete(true) }
            let trust = sec_trust_copy_ref(trustRef).takeRetainedValue()
            SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, verifyMode == .verifyFull ? serverName as CFString : nil))
            if let anchors {
                SecTrustSetAnchorCertificates(trust, anchors as CFArray)
                SecTrustSetAnchorCertificatesOnly(trust, true)
            }
            complete(SecTrustEvaluateWithError(trust, nil))
        }, DispatchQueue.global())

        let params = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        if preamble != nil {
            // Application protocols are ordered top to bottom: TLS above the framer.
            params.defaultProtocolStack.applicationProtocols.append(NWProtocolFramer.Options(definition: PreambleFramer.definition))
            PreambleRegistry.lock.lock()
            PreambleRegistry.set(preamble)
        }
        defer {
            if preamble != nil {
                PreambleRegistry.set(nil)
                PreambleRegistry.lock.unlock()
            }
        }
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else { throw DatabaseError("Invalid port \(port)") }
        connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: params)

        let ready = DispatchSemaphore(value: 0)
        let state = Box<Result<Void, Error>?>(nil)
        connection.stateUpdateHandler = { s in
            switch s {
            case .ready:
                if state.value == nil { state.value = .success(()); ready.signal() }
            case .failed(let e), .waiting(let e):
                if state.value == nil { state.value = .failure(e); ready.signal() }
            case .cancelled:
                if state.value == nil { state.value = .failure(DatabaseError("Connection cancelled")); ready.signal() }
            default: break
            }
        }
        connection.start(queue: queue)
        if ready.wait(timeout: .now() + timeout) == .timedOut {
            connection.cancel()
            throw DatabaseError("TLS connection to \(host):\(port) timed out")
        }
        if case .failure(let e) = state.value! {
            connection.cancel()
            if let refusal = preamble?.refusal { throw refusal }
            throw DatabaseError("TLS connection failed: \((e as? NWError).map(Self.describe) ?? e.localizedDescription)")
        }
        if let meta = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata {
            let v = sec_protocol_metadata_get_negotiated_tls_protocol_version(meta.securityProtocolMetadata)
            let version = v == .TLSv13 ? "TLSv1.3" : v == .TLSv12 ? "TLSv1.2" : "TLS"
            let suite = sec_protocol_metadata_get_negotiated_tls_ciphersuite(meta.securityProtocolMetadata)
            negotiatedDescription = "\(version) (cipher 0x\(String(suite.rawValue, radix: 16, uppercase: true)))"
        }
    }

    private final class Box<T>: @unchecked Sendable {
        var value: T
        init(_ v: T) { value = v }
    }

    static func describe(_ e: NWError) -> String {
        switch e {
        case .tls(let status): return TLSStream.describe(status)
        case .posix(let code): return String(cString: strerror(code.rawValue))
        default: return e.debugDescription
        }
    }

    static func isIPAddress(_ host: String) -> Bool {
        var v4 = in_addr(), v6 = in6_addr()
        return inet_pton(AF_INET, host, &v4) == 1 || inet_pton(AF_INET6, host, &v6) == 1
    }

    func write(_ bytes: [UInt8]) throws {
        let done = DispatchSemaphore(value: 0)
        let err = Box<NWError?>(nil)
        connection.send(content: Data(bytes), completion: .contentProcessed { e in
            err.value = e
            done.signal()
        })
        done.wait()
        if let e = err.value { throw DatabaseError("Write failed: \(Self.describe(e))") }
    }

    func read(_ count: Int) throws -> [UInt8] {
        while buffer.count - index < count {
            if index > 0 {
                buffer.removeFirst(index)
                index = 0
            }
            let done = DispatchSemaphore(value: 0)
            let result = Box<(Data?, Bool, NWError?)>((nil, false, nil))
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, complete, e in
                result.value = (data, complete, e)
                done.signal()
            }
            done.wait()
            let (data, complete, e) = result.value
            if let data, !data.isEmpty { buffer.append(contentsOf: data) }
            if let e { throw DatabaseError("Read failed: \(Self.describe(e))") }
            if complete && (data?.isEmpty ?? true) { throw DatabaseError("Server closed the connection") }
        }
        defer { index += count }
        return Array(buffer[index..<index + count])
    }

    func close() {
        guard !closed else { return }
        closed = true
        connection.cancel()
    }

    deinit { close() }
}

/// Runs a TLSPreamble on the raw TCP stream, then becomes a pass-through for TLS above.
final class PreambleFramer: NWProtocolFramerImplementation {
    static let label = "DBIDEPreamble"
    static let definition = NWProtocolFramer.Definition(implementation: PreambleFramer.self)

    private var preamble: TLSPreamble?
    private var queue: [TLSPreamble.Step] = []
    private var pendingRead: (Int, ([UInt8]) throws -> [TLSPreamble.Step])?
    private var inbox: [UInt8] = []

    required init(framer: NWProtocolFramer.Instance) {}

    func start(framer: NWProtocolFramer.Instance) -> NWProtocolFramer.StartResult {
        // The preamble is handed over through PreambleRegistry (held locked by the opener).
        preamble = PreambleRegistry.current()
        queue = preamble?.steps ?? []
        advance(framer)
        return .willMarkReady
    }

    private func advance(_ framer: NWProtocolFramer.Instance) {
        while !queue.isEmpty {
            let step = queue.removeFirst()
            switch step {
            case .write(let bytes):
                framer.writeOutput(data: Data(bytes))
            case .read(let n, let next):
                pendingRead = (n, next)
                deliver(framer)
                return
            }
        }
        if pendingRead == nil {
            framer.markReady()
            framer.passThroughInput()
            framer.passThroughOutput()
        }
    }

    private func deliver(_ framer: NWProtocolFramer.Instance) {
        guard let (n, next) = pendingRead, inbox.count >= n else { return }
        let bytes = Array(inbox.prefix(n))
        inbox.removeFirst(n)
        pendingRead = nil
        do {
            queue = try next(bytes) + queue
            advance(framer)
        } catch {
            preamble?.refusal = error
            framer.markFailed(error: .posix(.ECONNREFUSED))
        }
    }

    func handleInput(framer: NWProtocolFramer.Instance) -> Int {
        while true {
            var chunk: Data?
            let ok = framer.parseInput(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { buffer, _ in
                guard let buffer, buffer.count > 0 else { return 0 }
                chunk = Data(buffer)
                return buffer.count
            }
            guard ok, let chunk else { break }
            inbox.append(contentsOf: chunk)
            deliver(framer)
        }
        return 0
    }

    func handleOutput(framer: NWProtocolFramer.Instance, message: NWProtocolFramer.Message, messageLength: Int, isComplete: Bool) {
        try? framer.writeOutputNoCopy(length: messageLength)
    }

    func wakeup(framer: NWProtocolFramer.Instance) {}
    func stop(framer: NWProtocolFramer.Instance) -> Bool { true }
    func cleanup(framer: NWProtocolFramer.Instance) {}
}

/// Hands the preamble to the framer instances of the connection being opened.
/// Openers hold `lock` until their connection is ready, so only one preamble is pending at a time.
/// Every instance gets it: Network.framework may race several attempts (IPv6 / IPv4 for
/// "localhost"), each with its own framer running the preamble on its own socket.
enum PreambleRegistry {
    nonisolated(unsafe) private static var pending: TLSPreamble?
    private static let valueLock = NSLock()
    static let lock = NSLock()
    static func set(_ p: TLSPreamble?) {
        valueLock.lock()
        pending = p
        valueLock.unlock()
    }
    static func current() -> TLSPreamble? {
        valueLock.lock()
        defer { valueLock.unlock() }
        return pending
    }
}
