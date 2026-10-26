import Foundation
import Network

/// This Mac's Tailscale address, which the phone uses to reach it from anywhere: an IPv4 address
/// in 100.64.0.0/10 on a utun interface. `defaults write dev.longarm.mac internetHost <address>`
/// stands in for it, to try internet connections without Tailscale.
enum Tailscale {
    static func address() -> String? {
        if let override = UserDefaults.standard.string(forKey: "internetHost"), !override.isEmpty { return override }
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return nil }
        defer { freeifaddrs(head) }
        var cursor = head
        while let ifa = cursor?.pointee {
            defer { cursor = ifa.ifa_next }
            guard String(cString: ifa.ifa_name).hasPrefix("utun"), ifa.ifa_flags & UInt32(IFF_UP) != 0,
                  let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let ip = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            let bytes = withUnsafeBytes(of: ip) { Array($0) }
            guard bytes[0] == 100, bytes[1] & 0xC0 == 64 else { continue }
            return bytes.map(String.init).joined(separator: ".")
        }
        return nil
    }

    /// Whether a connection comes in over Tailscale (100.64.0.0/10 or fd7a:115c:a1e0::/48).
    static func isTailscale(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let ip):
            let bytes = Array(ip.rawValue)
            return bytes[0] == 100 && bytes[1] & 0xC0 == 64
        case .ipv6(let ip):
            let bytes = Array(ip.rawValue)
            if let v4 = ip.asIPv4 { return isTailscale(.hostPort(host: .ipv4(v4), port: 0)) }
            return bytes.starts(with: [0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0])
        default:
            return false
        }
    }
}
