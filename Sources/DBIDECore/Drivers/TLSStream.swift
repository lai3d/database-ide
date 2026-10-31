import Foundation
import Security

/// Blocking byte stream used by the wire-protocol drivers (plain TCP or TLS on top of it).
protocol ByteStream: AnyObject, Sendable {
    func write(_ bytes: [UInt8]) throws
    func read(_ count: Int) throws -> [UInt8]
    func close()
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
    /// Host name to send (SNI) and verify; defaults to the host connected to (differs behind an SSH tunnel).
    public var serverName: String?

    public init(mode: SSLMode = .prefer, rootCertificatePath: String? = nil, serverName: String? = nil) {
        self.mode = mode
        self.rootCertificatePath = rootCertificatePath
        self.serverName = serverName
    }

    public static let disabled = TLSOptions(mode: .disable)
}

/// Certificate / error helpers shared by the TLS code.
enum TLSStream {
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

    static func describe(_ status: OSStatus) -> String {
        let text = SecCopyErrorMessageString(status, nil) as String? ?? ""
        return text.isEmpty ? "OSStatus \(status)" : "\(text) [\(status)]"
    }
}

/// Thrown by a preamble when the server declines TLS (so "prefer" can fall back to plain).
struct TLSRefused: Error, LocalizedError {
    var message: String
    var errorDescription: String? { message }
}
