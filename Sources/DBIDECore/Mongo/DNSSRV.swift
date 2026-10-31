import Foundation
import dnssd

/// DNS SRV / TXT lookups for `mongodb+srv://` cluster names (via dnssd).
enum DNSSRV {
    struct Resolved {
        var hosts: [(String, Int)]
        var options: [String: String]
    }

    static func resolveMongoSRV(_ name: String) throws -> Resolved {
        let srv = try query("_mongodb._tcp." + name, type: UInt16(kDNSServiceType_SRV))
        var hosts: [(priority: Int, weight: Int, host: String, port: Int)] = []
        for rdata in srv {
            var r = ByteReader(rdata)
            let priority = Int(try r.uintBE(2)), weight = Int(try r.uintBE(2)), port = Int(try r.uintBE(2))
            var labels: [String] = []
            while let len = r.peek(), len > 0 {
                _ = try r.u8()
                labels.append(String(decoding: try r.take(Int(len)), as: UTF8.self))
            }
            let host = labels.joined(separator: ".")
            // Security rule from the spec: hosts must share the parent domain of the SRV name.
            let parent = name.split(separator: ".").dropFirst().joined(separator: ".")
            guard host.hasSuffix("." + parent) || host == parent else { continue }
            hosts.append((priority, weight, host, port))
        }
        guard !hosts.isEmpty else { throw DatabaseError("No SRV records for \(name)") }
        var options: [String: String] = [:]
        if let txt = try? query(name, type: UInt16(kDNSServiceType_TXT)) {
            for rdata in txt {
                var i = 0
                while i < rdata.count {
                    let len = Int(rdata[i])
                    let s = String(decoding: rdata[(i + 1)..<min(rdata.count, i + 1 + len)], as: UTF8.self)
                    for pair in s.split(separator: "&") {
                        let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                        if kv.count == 2 { options[kv[0]] = kv[1] }
                    }
                    i += 1 + len
                }
            }
        }
        return Resolved(hosts: hosts.sorted { ($0.priority, -$0.weight) < ($1.priority, -$1.weight) }.map { ($0.host, $0.port) }, options: options)
    }

    private final class Box: @unchecked Sendable {
        var records: [[UInt8]] = []
        var error: DNSServiceErrorType = 0
    }

    /// Synchronous record query with a 5 s timeout.
    static func query(_ name: String, type: UInt16) throws -> [[UInt8]] {
        let box = Box()
        var ref: DNSServiceRef?
        let ctx = Unmanaged.passUnretained(box).toOpaque()
        let err = DNSServiceQueryRecord(
            &ref, 0, 0, name, type, UInt16(kDNSServiceClass_IN),
            { _, flags, _, errorCode, _, _, _, rdlen, rdata, _, context in
                let box = Unmanaged<Box>.fromOpaque(context!).takeUnretainedValue()
                if errorCode != kDNSServiceErr_NoError {
                    box.error = errorCode
                    return
                }
                if let rdata { box.records.append(Array(UnsafeRawBufferPointer(start: rdata, count: Int(rdlen)))) }
                _ = flags
            }, ctx)
        guard err == kDNSServiceErr_NoError, let ref else { throw DatabaseError("DNS query failed for \(name) (\(err))") }
        defer { DNSServiceRefDeallocate(ref) }
        let fd = DNSServiceRefSockFD(ref)
        let deadline = Date().addingTimeInterval(5)
        // Process replies until none arrive for 300 ms (after the first) or the deadline passes.
        while Date() < deadline {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let wait: Int32 = box.records.isEmpty ? Int32(max(1, deadline.timeIntervalSinceNow * 1000)) : 300
            if poll(&pfd, 1, wait) <= 0 { break }
            if DNSServiceProcessResult(ref) != kDNSServiceErr_NoError { break }
            if box.error != 0 { break }
        }
        if box.records.isEmpty { throw DatabaseError("No DNS records for \(name)") }
        return box.records
    }
}

extension ByteReader {
    mutating func uintBE(_ size: Int) throws -> UInt64 {
        try take(size).reduce(0) { $0 << 8 | UInt64($1) }
    }
}
