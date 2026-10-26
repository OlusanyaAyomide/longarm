import Foundation
import Network

/// Whether a connection comes from this Mac's own network: loopback (USB through adb reverse), or
/// an address on the same subnet as one of its network interfaces. VPN interfaces (utun, ipsec,
/// ppp) don't count, so a connection over Tailscale or another VPN is not "home".
enum LocalNetwork {
    static func isLocal(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        let remote: [UInt8]
        switch host {
        case .ipv4(let ip): remote = Array(ip.rawValue)
        case .ipv6(let ip): remote = ip.asIPv4.map { Array($0.rawValue) } ?? Array(ip.rawValue)
        default: return false
        }
        if remote.count == 4 && remote[0] == 127 { return true }
        if remote == Array(IPv6Address.loopback.rawValue) { return true }

        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return false }
        defer { freeifaddrs(head) }
        var cursor = head
        while let ifa = cursor?.pointee {
            defer { cursor = ifa.ifa_next }
            let name = String(cString: ifa.ifa_name)
            guard !["utun", "ipsec", "ppp", "lo"].contains(where: name.hasPrefix), ifa.ifa_flags & UInt32(IFF_UP) != 0,
                  let address = bytes(ifa.ifa_addr), let mask = bytes(ifa.ifa_netmask),
                  address.count == remote.count, mask.count == remote.count else { continue }
            if zip(zip(address, remote), mask).allSatisfy({ ($0.0 & $1) == ($0.1 & $1) }) { return true }
        }
        return false
    }

    private static func bytes(_ address: UnsafeMutablePointer<sockaddr>?) -> [UInt8]? {
        guard let address else { return nil }
        switch Int32(address.pointee.sa_family) {
        case AF_INET:
            return address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { withUnsafeBytes(of: $0.pointee.sin_addr) { Array($0) } }
        case AF_INET6:
            return address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { withUnsafeBytes(of: $0.pointee.sin6_addr) { Array($0) } }
        default:
            return nil
        }
    }
}
