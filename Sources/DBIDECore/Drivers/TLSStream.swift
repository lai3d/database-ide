import Foundation
import Security

/// Blocking byte stream used by the wire-protocol drivers (plain TCP or TLS on top of it).
protocol ByteStream: AnyObject, Sendable {
    func write(_ bytes: [UInt8]) throws
    func read(_ count: Int) throws -> [UInt8]
}

extension TCPSocket: ByteStream {}

/// How a connection uses TLS (same meaning as libpq's `sslmode`).
public enum SSLMode: String, Codable, Sendable, CaseIterable {
    /// Never use TLS.
    case disable
    /// Use TLS when the server supports it; certificate not verified.
    case prefer
    /// Require TLS; certificate not verified.
    case require
    /// Require TLS and a certificate chain trusted by the system or the given root CA.
    case verifyCA = "verify-ca"
    /// Like verify-ca, and the certificate must match the host name.
    case verifyFull = "verify-full"

    public var title: String {
        switch self {
        case .disable: "Disable"
        case .prefer: "Prefer"
        case .require: "Require"
        case .verifyCA: "Verify CA"
        case .verifyFull: "Verify Full"
        }
    }

    var requiresTLS: Bool { self != .disable && self != .prefer }
}

public struct TLSOptions: Sendable, Hashable {
    public var mode: SSLMode
    /// PEM file with one or more root certificates; when set, only these are trusted.
    public var rootCertificatePath: String?

    public init(mode: SSLMode = .prefer, rootCertificatePath: String? = nil) {
        self.mode = mode
        self.rootCertificatePath = rootCertificatePath
    }

    public static let disabled = TLSOptions(mode: .disable)
}

/// TLS client over an already-connected TCP socket, so the drivers can do their
/// plaintext negotiation (PostgreSQL SSLRequest, MySQL SSL request packet) first.
/// Uses SecureTransport (TLS 1.2), which accepts arbitrary I/O callbacks.
final class TLSStream: ByteStream, @unchecked Sendable {
    private let socket: TCPSocket
    private let context: SSLContext
    private var plain: [UInt8] = []
    private var plainIndex = 0
    private(set) var negotiatedDescription = ""

    init(socket: TCPSocket, host: String, options: TLSOptions) throws {
        self.socket = socket
        guard let ctx = SSLCreateContext(nil, .clientSide, .streamType) else {
            throw DatabaseError("Cannot create TLS context")
        }
        context = ctx
        SSLSetIOFuncs(ctx, tlsReadCallback, tlsWriteCallback)
        SSLSetConnection(ctx, Unmanaged.passUnretained(self).toOpaque())
        SSLSetProtocolVersionMin(ctx, .tlsProtocol12)
        SSLSetSessionOption(ctx, .breakOnServerAuth, true)
        if !Self.isIPAddress(host) {
            SSLSetPeerDomainName(ctx, host, host.utf8.count)
        }
        try handshake(host: host, options: options)
    }

    deinit { SSLClose(context) }

    private func handshake(host: String, options: TLSOptions) throws {
        while true {
            let status = SSLHandshake(context)
            switch status {
            case noErr:
                var version = SSLProtocol.sslProtocolUnknown
                SSLGetNegotiatedProtocolVersion(context, &version)
                var cipher: SSLCipherSuite = 0
                SSLGetNegotiatedCipher(context, &cipher)
                negotiatedDescription = "\(version == .tlsProtocol12 ? "TLSv1.2" : "TLS") (cipher 0x\(String(cipher, radix: 16, uppercase: true)))"
                return
            case errSSLWouldBlock:
                continue
            case errSSLPeerAuthCompleted:
                try verifyPeer(host: host, options: options)
            default:
                throw DatabaseError("TLS handshake failed (\(Self.describe(status)))")
            }
        }
    }

    private func verifyPeer(host: String, options: TLSOptions) throws {
        guard options.mode == .verifyCA || options.mode == .verifyFull else { return }
        var trustRef: SecTrust?
        guard SSLCopyPeerTrust(context, &trustRef) == noErr, let trust = trustRef else {
            throw DatabaseError("TLS: server sent no certificate")
        }
        let policy = SecPolicyCreateSSL(true, options.mode == .verifyFull ? host as CFString : nil)
        SecTrustSetPolicies(trust, policy)
        if let path = options.rootCertificatePath, !path.isEmpty {
            let anchors = try Self.loadCertificates((path as NSString).expandingTildeInPath)
            SecTrustSetAnchorCertificates(trust, anchors as CFArray)
            SecTrustSetAnchorCertificatesOnly(trust, true)
        }
        var error: CFError?
        if !SecTrustEvaluateWithError(trust, &error) {
            let reason = (error as Error?)?.localizedDescription ?? "untrusted"
            throw DatabaseError("TLS certificate verification failed: \(reason)")
        }
    }

    static func loadCertificates(_ path: String) throws -> [SecCertificate] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            if let der = FileManager.default.contents(atPath: path), let c = SecCertificateCreateWithData(nil, der as CFData) {
                return [c]
            }
            throw DatabaseError("Cannot read root certificate file \(path)")
        }
        var certs: [SecCertificate] = []
        var current: String?
        for line in text.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("-----BEGIN CERTIFICATE") {
                current = ""
            } else if line.hasPrefix("-----END CERTIFICATE") {
                if let b64 = current, let der = Data(base64Encoded: b64),
                    let cert = SecCertificateCreateWithData(nil, der as CFData)
                {
                    certs.append(cert)
                }
                current = nil
            } else if current != nil {
                current! += line.trimmingCharacters(in: .whitespaces)
            }
        }
        if certs.isEmpty { throw DatabaseError("No certificates found in \(path)") }
        return certs
    }

    private static func isIPAddress(_ host: String) -> Bool {
        var v4 = in_addr(), v6 = in6_addr()
        return inet_pton(AF_INET, host, &v4) == 1 || inet_pton(AF_INET6, host, &v6) == 1
    }

    static func describe(_ status: OSStatus) -> String {
        let text = SecCopyErrorMessageString(status, nil) as String? ?? ""
        return text.isEmpty ? "OSStatus \(status)" : "\(text) [\(status)]"
    }

    // MARK: I/O used by SecureTransport

    fileprivate func rawRead(_ buffer: UnsafeMutableRawPointer, _ length: UnsafeMutablePointer<Int>) -> OSStatus {
        let wanted = length.pointee
        do {
            let bytes = try socket.readSome(wanted)
            bytes.withUnsafeBytes { buffer.copyMemory(from: $0.baseAddress!, byteCount: bytes.count) }
            length.pointee = bytes.count
            return bytes.count < wanted ? errSSLWouldBlock : noErr
        } catch {
            length.pointee = 0
            return errSSLClosedAbort
        }
    }

    fileprivate func rawWrite(_ buffer: UnsafeRawPointer, _ length: UnsafeMutablePointer<Int>) -> OSStatus {
        do {
            try socket.write(Array(UnsafeRawBufferPointer(start: buffer, count: length.pointee)))
            return noErr
        } catch {
            length.pointee = 0
            return errSSLClosedAbort
        }
    }

    // MARK: ByteStream

    func write(_ bytes: [UInt8]) throws {
        var offset = 0
        while offset < bytes.count {
            var processed = 0
            let status = bytes[offset...].withUnsafeBytes {
                SSLWrite(context, $0.baseAddress, $0.count, &processed)
            }
            offset += processed
            if status == errSSLWouldBlock { continue }
            guard status == noErr else { throw DatabaseError("TLS write failed (\(Self.describe(status)))") }
        }
    }

    func read(_ count: Int) throws -> [UInt8] {
        while plain.count - plainIndex < count {
            if plainIndex > 0 {
                plain.removeFirst(plainIndex)
                plainIndex = 0
            }
            var chunk = [UInt8](repeating: 0, count: 32 * 1024)
            var processed = 0
            let status = chunk.withUnsafeMutableBytes { SSLRead(context, $0.baseAddress!, $0.count, &processed) }
            plain.append(contentsOf: chunk[0..<processed])
            switch status {
            case noErr, errSSLWouldBlock: continue
            case errSSLClosedGraceful, errSSLClosedNoNotify: throw DatabaseError("Server closed the connection")
            default: throw DatabaseError("TLS read failed (\(Self.describe(status)))")
            }
        }
        defer { plainIndex += count }
        return Array(plain[plainIndex..<plainIndex + count])
    }
}

private func tlsReadCallback(
    _ connection: SSLConnectionRef, _ data: UnsafeMutableRawPointer, _ length: UnsafeMutablePointer<Int>
) -> OSStatus {
    Unmanaged<TLSStream>.fromOpaque(connection).takeUnretainedValue().rawRead(data, length)
}

private func tlsWriteCallback(
    _ connection: SSLConnectionRef, _ data: UnsafeRawPointer, _ length: UnsafeMutablePointer<Int>
) -> OSStatus {
    Unmanaged<TLSStream>.fromOpaque(connection).takeUnretainedValue().rawWrite(data, length)
}
