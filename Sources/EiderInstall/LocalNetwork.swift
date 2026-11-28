import Darwin
import Foundation

/// An IPv4 address of one of this device's network interfaces.
public struct DeviceAddress: Sendable, Hashable, CustomStringConvertible {
    public let interface: String
    /// Four bytes, network order.
    public let bytes: [UInt8]

    public init(interface: String, bytes: [UInt8]) {
        self.interface = interface
        self.bytes = bytes
    }

    /// Dotted quad, as it goes into a URL and a certificate's subjectAltName.
    public var description: String { bytes.map(String.init).joined(separator: ".") }
}

/// Which address the install server answers on, and which connections it answers.
///
/// Measured on an iPhone 17 Pro, iOS 27.3, 2026-11-28 (device syslog): appstored refuses a
/// manifest served from loopback before it connects at all:
/// `The manifest URL isn't external: https://127.0.0.1:<port>/<token>/manifest.plist`
/// (ASDErrorDomain 850 "Invalid manifest URL"), and later the same day refused one served at the
/// iPhone's own Wi-Fi address with the same message. It did fetch the IPA from the iPhone's
/// Wi-Fi address when a manifest on another host (the Mac, 192.168.1.117) named it there, so
/// the manifest comes from a `ManifestServer` and this server, on the device's own Wi-Fi/LAN
/// address, serves only the IPA and answers only connections that come from the device itself.
public enum LocalNetwork {
    /// One interface address as getifaddrs reports it.
    public struct InterfaceAddress: Sendable, Equatable {
        public let interface: String
        /// 4 bytes for IPv4, 16 for IPv6.
        public let bytes: [UInt8]
        public let isUp: Bool
        public let isLoopback: Bool

        public init(interface: String, bytes: [UInt8], isUp: Bool = true, isLoopback: Bool = false) {
            self.interface = interface
            self.bytes = bytes
            self.isUp = isUp
            self.isLoopback = isLoopback
        }
    }

    /// The private IPv4 ranges an install address may come from, as (network, prefix length).
    /// 100.64/10 covers carrier-grade NAT; the iPhone's own hotspot hands out 172.20.10.x.
    static let privateRanges: [(network: [UInt8], prefix: Int)] = [
        ([10, 0, 0, 0], 8),
        ([172, 16, 0, 0], 12),
        ([192, 168, 0, 0], 16),
        ([100, 64, 0, 0], 10),
    ]

    public static let noAddressMessage =
        "Connect to Wi-Fi to install: iOS will not take an install link served from this iPhone's internal address."

    /// Every address of every interface, IPv4 and IPv6.
    public static func interfaceAddresses() -> [InterfaceAddress] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var result: [InterfaceAddress] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let address = entry.ifa_addr else { continue }
            let bytes: [UInt8]
            switch Int32(address.pointee.sa_family) {
            case AF_INET:
                bytes = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    withUnsafeBytes(of: $0.pointee.sin_addr) { Array($0) }
                }
            case AF_INET6:
                bytes = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                    withUnsafeBytes(of: $0.pointee.sin6_addr) { Array($0) }
                }
            default:
                continue
            }
            result.append(InterfaceAddress(
                interface: String(cString: entry.ifa_name), bytes: bytes,
                isUp: entry.ifa_flags & UInt32(IFF_UP) != 0,
                isLoopback: entry.ifa_flags & UInt32(IFF_LOOPBACK) != 0))
        }
        return result
    }

    /// The address to serve an install from right now, or nil without Wi-Fi or another private
    /// network.
    public static func installAddress() -> DeviceAddress? {
        installAddress(from: interfaceAddresses())
    }

    /// An up, non-loopback IPv4 address in a private range: en0 (Wi-Fi) first, then the
    /// hotspot bridge and other Ethernet-like interfaces, then anything else (a VPN tunnel).
    static func installAddress(from addresses: [InterfaceAddress]) -> DeviceAddress? {
        let candidates = addresses.filter { $0.isUp && !$0.isLoopback && $0.bytes.count == 4 && isPrivate($0.bytes) }
        func rank(_ interface: String) -> Int {
            if interface == "en0" { return 0 }
            if interface.hasPrefix("bridge") || interface.hasPrefix("en") { return 1 }
            return 2
        }
        let best = candidates.enumerated().min { lhs, rhs in
            (rank(lhs.element.interface), lhs.offset) < (rank(rhs.element.interface), rhs.offset)
        }?.element
        return best.map { DeviceAddress(interface: $0.interface, bytes: $0.bytes) }
    }

    static func isPrivate(_ bytes: [UInt8]) -> Bool {
        bytes.count == 4 && privateRanges.contains { contains(network: $0.network, prefix: $0.prefix, bytes) }
    }

    static func contains(network: [UInt8], prefix: Int, _ bytes: [UInt8]) -> Bool {
        guard network.count == bytes.count else { return false }
        var remaining = prefix
        for (lhs, rhs) in zip(network, bytes) where remaining > 0 {
            let bits = min(8, remaining)
            let mask = UInt8(truncatingIfNeeded: 0xFF << (8 - bits))
            if lhs & mask != rhs & mask { return false }
            remaining -= bits
        }
        return true
    }

    /// The mask form name constraints use: network bytes followed by the netmask.
    static func constraintBytes(network: [UInt8], prefix: Int) -> [UInt8] {
        let mask = UInt32.max << (32 - prefix)
        return network + withUnsafeBytes(of: mask.bigEndian) { Array($0) }
    }

    /// Whether a connection from `remote` comes from this device: a loopback address, or an
    /// address one of its own interfaces holds. Everything else is another machine on the
    /// network and is refused before a byte is read.
    static func isOwnAddress(_ remote: [UInt8], ownAddresses: [InterfaceAddress]) -> Bool {
        let remote = unmapped(remote)
        if remote.count == 4, remote[0] == 127 { return true }
        if remote == [UInt8](repeating: 0, count: 15) + [1] { return true }
        return ownAddresses.contains { unmapped($0.bytes) == remote }
    }

    /// An IPv4-mapped IPv6 address (::ffff:a.b.c.d) as its four IPv4 bytes.
    private static func unmapped(_ bytes: [UInt8]) -> [UInt8] {
        let prefix = [UInt8](repeating: 0, count: 10) + [0xFF, 0xFF]
        if bytes.count == 16, Array(bytes.prefix(12)) == prefix { return Array(bytes.suffix(4)) }
        return bytes
    }
}
