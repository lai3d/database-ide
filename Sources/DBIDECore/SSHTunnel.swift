import Darwin
import Foundation

/// SSH settings of a data source. Authentication uses the SSH agent or a key file
/// (passphrase-protected keys must be loaded in the agent; password auth isn't supported).
public struct SSHConfig: Codable, Sendable, Hashable {
    public var enabled = false
    public var host = ""
    public var port = 22
    public var user = ""
    /// Private key file; empty = agent / default keys from ~/.ssh.
    public var keyPath = ""

    public init(enabled: Bool = false, host: String = "", port: Int = 22, user: String = "", keyPath: String = "") {
        self.enabled = enabled
        self.host = host
        self.port = port
        self.user = user
        self.keyPath = keyPath
    }

    public var destination: String { user.isEmpty ? host : "\(user)@\(host)" }
}

/// Local port forwards through the system `ssh` binary, shared between connections
/// to the same target and restarted when the ssh process has died.
public final class SSHTunnels: @unchecked Sendable {
    public static let shared = SSHTunnels()

    /// Extra `-o` options (tests use a private known_hosts file).
    public var extraOptions: [String] = []

    private struct Key: Hashable {
        var ssh: SSHConfig
        var remoteHost: String
        var remotePort: Int
    }

    private final class Tunnel {
        let process: Process
        let localPort: Int
        init(process: Process, localPort: Int) {
            self.process = process
            self.localPort = localPort
        }
    }

    private let lock = NSLock()
    private var tunnels: [Key: Tunnel] = [:]

    /// Returns a local port that forwards to `remoteHost:remotePort` as seen from the SSH host.
    public func localPort(ssh: SSHConfig, remoteHost: String, remotePort: Int, timeout: TimeInterval = 15) throws -> Int {
        let key = Key(ssh: ssh, remoteHost: remoteHost, remotePort: remotePort)
        lock.lock()
        defer { lock.unlock() }
        if let t = tunnels[key], t.process.isRunning { return t.localPort }
        tunnels[key] = nil
        let t = try start(key, timeout: timeout)
        tunnels[key] = t
        return t.localPort
    }

    public func closeAll() {
        lock.lock()
        defer { lock.unlock() }
        for t in tunnels.values where t.process.isRunning { t.process.terminate() }
        tunnels = [:]
    }

    private func start(_ key: Key, timeout: TimeInterval) throws -> Tunnel {
        let port = try Self.freeLocalPort()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        var args = [
            "-N", "-T",
            "-L", "127.0.0.1:\(port):\(key.remoteHost):\(key.remotePort)",
            "-p", String(key.ssh.port),
            "-o", "BatchMode=yes",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=30",
            "-o", "ConnectTimeout=\(Int(timeout))",
            "-o", "StrictHostKeyChecking=accept-new",
        ]
        if !key.ssh.keyPath.isEmpty {
            args += ["-i", (key.ssh.keyPath as NSString).expandingTildeInPath, "-o", "IdentitiesOnly=yes"]
        }
        for o in extraOptions { args += ["-o", o] }
        args.append(key.ssh.destination)
        p.arguments = args
        let errPipe = Pipe()
        p.standardError = errPipe
        p.standardOutput = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { throw DatabaseError("Cannot start ssh: \(error.localizedDescription)") }

        // Ready when the forwarded port accepts connections; fail if ssh exits first.
        let deadline = Date().addingTimeInterval(timeout + 2)
        while Date() < deadline {
            if !p.isRunning {
                let msg = String(decoding: errPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                throw DatabaseError("SSH tunnel to \(key.ssh.destination) failed: \(msg.isEmpty ? "ssh exited with \(p.terminationStatus)" : msg)")
            }
            if Self.canConnect(port: port) { return Tunnel(process: p, localPort: port) }
            usleep(100_000)
        }
        p.terminate()
        throw DatabaseError("SSH tunnel to \(key.ssh.destination) timed out")
    }

    static func freeLocalPort() throws -> Int {
        let s = socket(AF_INET, SOCK_STREAM, 0)
        guard s >= 0 else { throw DatabaseError("Cannot allocate a local port") }
        defer { close(s) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(s, $0, len) == 0 && getsockname(s, $0, &len) == 0
            }
        }
        guard ok else { throw DatabaseError("Cannot allocate a local port") }
        return Int(UInt16(bigEndian: addr.sin_port))
    }

    private static func canConnect(port: Int) -> Bool {
        (try? TCPSocket(host: "127.0.0.1", port: port, timeout: 0.5)) != nil
    }
}
