import CryptoKit
import Foundation
import Security

/// Everything a phone needs to find and trust this Mac: a stable id, a shared token, and a
/// self-signed TLS identity whose fingerprint the phone pins. Stored in Application Support.
final class Pairing {
    let macId: String
    let identity: SecIdentity
    let fingerprint: String   // SHA-256 of the DER certificate, lowercase hex
    private(set) var token: String

    private let directory: URL
    private static let p12Password = "longarm"

    init() throws {
        directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Longarm", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        macId = try Self.loadOrCreate(directory.appendingPathComponent("id")) { UUID().uuidString }
        token = try Self.loadOrCreate(directory.appendingPathComponent("token"), make: Self.randomToken)

        let p12 = directory.appendingPathComponent("identity.p12")
        if !FileManager.default.fileExists(atPath: p12.path) { try Self.generateIdentity(at: p12) }
        (identity, fingerprint) = try Self.loadIdentity(p12)
    }

    /// New token: every paired phone has to scan the QR code again.
    func resetToken() throws {
        token = Self.randomToken()
        try Self.writePrivate(token, to: directory.appendingPathComponent("token"))
    }

    /// With `internet`, the phone can also connect over Tailscale (see `LinkServer`).
    func link(host: String, port: UInt16, internet: (host: String, port: UInt16)?, macName: String) -> String {
        var components = URLComponents()
        components.scheme = "longarm"
        components.host = "pair"
        components.queryItems = [
            URLQueryItem(name: "h", value: host),
            URLQueryItem(name: "p", value: String(port)),
            URLQueryItem(name: "t", value: token),
            URLQueryItem(name: "f", value: fingerprint),
            URLQueryItem(name: "id", value: macId),
            URLQueryItem(name: "n", value: macName),
        ]
        if let internet {
            components.queryItems! += [URLQueryItem(name: "ih", value: internet.host), URLQueryItem(name: "ip", value: String(internet.port))]
        }
        return components.string!
    }

    func isValid(authorization: String) -> Bool {
        let expected = Data("Bearer \(token)".utf8), given = Data(authorization.utf8)
        guard expected.count == given.count else { return false }
        return zip(expected, given).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    // MARK: - Storage

    private static func randomToken() -> String {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }.map { String(format: "%02x", $0) }.joined()
    }

    private static func loadOrCreate(_ url: URL, make: () -> String) throws -> String {
        if let existing = try? String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           !existing.isEmpty { return existing }
        let value = make()
        try writePrivate(value, to: url)
        return value
    }

    private static func writePrivate(_ value: String, to url: URL) throws {
        try value.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    // MARK: - TLS identity

    private static func generateIdentity(at p12: URL) throws {
        let dir = p12.deletingLastPathComponent()
        let key = dir.appendingPathComponent("key.pem"), cert = dir.appendingPathComponent("cert.pem")
        defer {
            try? FileManager.default.removeItem(at: key)
            try? FileManager.default.removeItem(at: cert)
        }
        try run("/usr/bin/openssl", ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-sha256", "-days", "3650",
                                     "-subj", "/CN=Longarm", "-keyout", key.path, "-out", cert.path])
        try run("/usr/bin/openssl", ["pkcs12", "-export", "-inkey", key.path, "-in", cert.path,
                                     "-out", p12.path, "-passout", "pass:\(p12Password)"])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: p12.path)
    }

    private static func loadIdentity(_ p12: URL) throws -> (SecIdentity, String) {
        let options: [String: Any] = [kSecImportExportPassphrase as String: p12Password,
                                      kSecImportToMemoryOnly as String: true]
        var items: CFArray?
        let status = SecPKCS12Import(try Data(contentsOf: p12) as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess,
              let entry = (items as? [[String: Any]])?.first,
              let value = entry[kSecImportItemIdentity as String] else {
            throw LongarmError("Could not load TLS identity (OSStatus \(status))")
        }
        let identity = value as! SecIdentity
        var certificate: SecCertificate?
        SecIdentityCopyCertificate(identity, &certificate)
        guard let certificate else { throw LongarmError("TLS identity has no certificate") }
        let der = SecCertificateCopyData(certificate) as Data
        return (identity, SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined())
    }

    private static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw LongarmError("\(tool) \(arguments.first ?? "") failed") }
    }
}

struct LongarmError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
