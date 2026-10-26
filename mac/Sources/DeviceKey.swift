import CryptoKit
import Foundation

/// This Mac's long-term identity for internet connections: a P-256 key in the Secure Enclave (its
/// wrapped form kept in the Keychain), so it can sign but never be copied off this Mac. The phone
/// learns the public half at home, over the paired link, and checks every connection offer
/// against it; the rendezvous server knows the Mac by its id (`identity.ts` there).
final class DeviceKey {
    private static let account = "device-key"

    let publicKey: Data   // SPKI DER
    let id: String        // SHA-256 of `publicKey`, base64url
    private let signer: (Data) throws -> Data

    init() throws {
        if SecureEnclave.isAvailable {
            let key: SecureEnclave.P256.Signing.PrivateKey
            if let stored = Keychain.read(Self.account).flatMap({ Data(base64Encoded: $0) }),
               let existing = try? SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: stored) {
                key = existing
            } else {
                key = try SecureEnclave.P256.Signing.PrivateKey()
                Keychain.save(key.dataRepresentation.base64EncodedString(), account: Self.account)
            }
            publicKey = key.publicKey.derRepresentation
            signer = { try key.signature(for: $0).derRepresentation }
        } else {   // e.g. a virtual machine
            let key: P256.Signing.PrivateKey
            if let stored = Keychain.read(Self.account).flatMap({ Data(base64Encoded: $0) }),
               let existing = try? P256.Signing.PrivateKey(rawRepresentation: stored) {
                key = existing
            } else {
                key = P256.Signing.PrivateKey()
                Keychain.save(key.rawRepresentation.base64EncodedString(), account: Self.account)
            }
            publicKey = key.publicKey.derRepresentation
            signer = { try key.signature(for: $0).derRepresentation }
        }
        id = Self.id(of: publicKey)
    }

    /// ECDSA with SHA-256, DER-encoded.
    func sign(_ data: Data) throws -> Data { try signer(data) }

    static func id(of publicKey: Data) -> String {
        Data(SHA256.hash(data: publicKey)).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Whether [signature] is [publicKey]'s over [data].
    static func isValid(_ signature: Data, of data: Data, by publicKey: Data) -> Bool {
        guard let key = try? P256.Signing.PublicKey(derRepresentation: publicKey),
              let signature = try? P256.Signing.ECDSASignature(derRepresentation: signature) else { return false }
        return key.isValidSignature(signature, for: data)
    }
}

/// The phones that may reach this Mac over the internet: each one's public key, learned over the
/// home link (which only a paired phone can open). Reset Pairing forgets them all.
final class PairedPhones {
    struct Phone: Codable {
        let id: String
        let key: Data   // SPKI DER
        var name: String
    }

    private(set) var phones: [Phone] = []
    var onChange: (() -> Void)?
    private let file: URL

    init() {
        file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Longarm/phones.json")
        phones = (try? JSONDecoder().decode([Phone].self, from: Data(contentsOf: file))) ?? []
    }

    var ids: [String] { phones.map(\.id) }

    func key(of id: String) -> Data? { phones.first { $0.id == id }?.key }

    /// Adds (or renames) a phone from its public key; false unless it's a P-256 key.
    @discardableResult
    func add(key: Data, name: String) -> Bool {
        guard (try? P256.Signing.PublicKey(derRepresentation: key)) != nil else { return false }
        let id = DeviceKey.id(of: key)
        if let index = phones.firstIndex(where: { $0.id == id }) {
            guard phones[index].name != name else { return true }
            phones[index].name = name
        } else {
            phones.append(Phone(id: id, key: key, name: name))
            DebugLog.write("phone \(name) can now connect over the internet")
        }
        save()
        return true
    }

    func forgetAll() {
        phones = []
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(phones) {
            try? data.write(to: file, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        onChange?()
    }
}
