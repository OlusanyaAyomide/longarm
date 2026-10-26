import CommonCrypto
import Foundation
import Security

/// The code a phone must give to join over the internet, on top of the pairing token: the owner
/// sets it on the Mac and types it on the phone each time. Kept in the Keychain as a salted
/// PBKDF2 hash. Five wrong codes in a row lock internet joins for 15 minutes.
final class JoinCode {
    enum Check {
        case accepted
        case wrong(triesLeft: Int)
        case locked(until: Date)
        case notSet
    }

    static let lengths = 6...12
    private static let account = "internet-join-code"
    private static let rounds: UInt32 = 100_000
    private static let triesBeforeLock = 5
    private static let lockDuration: TimeInterval = 15 * 60

    private var wrongTries = 0
    private var lockedUntilDate: Date?

    var isSet: Bool { Keychain.read(Self.account) != nil }

    /// While wrong codes have locked internet joins.
    var lockedUntil: Date? {
        guard let lockedUntilDate, lockedUntilDate > Date() else { return nil }
        return lockedUntilDate
    }

    /// 6 to 12 digits: easy to type on a phone, and too many to guess five at a time.
    static func isAcceptable(_ code: String) -> Bool {
        lengths.contains(code.count) && code.allSatisfy { ("0"..."9").contains($0) }
    }

    func set(_ code: String) {
        var salt = Data(count: 16)
        _ = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        Keychain.save("\(salt.hex):\(Self.hash(code, salt: salt).hex)", account: Self.account)
        wrongTries = 0
        lockedUntilDate = nil
    }

    func check(_ code: String) -> Check {
        if let lockedUntil { return .locked(until: lockedUntil) }
        guard let stored = Keychain.read(Self.account)?.split(separator: ":"), stored.count == 2,
              let salt = Data(hex: String(stored[0])), let expected = Data(hex: String(stored[1])) else { return .notSet }
        let given = Self.hash(code, salt: salt)
        if zip(given, expected).reduce(0, { $0 | ($1.0 ^ $1.1) }) == 0 && given.count == expected.count {
            wrongTries = 0
            return .accepted
        }
        wrongTries += 1
        guard wrongTries >= Self.triesBeforeLock else { return .wrong(triesLeft: Self.triesBeforeLock - wrongTries) }
        wrongTries = 0
        let until = Date().addingTimeInterval(Self.lockDuration)
        lockedUntilDate = until
        DebugLog.write("internet joins locked after \(Self.triesBeforeLock) wrong codes")
        return .locked(until: until)
    }

    private static func hash(_ code: String, salt: Data) -> Data {
        var derived = Data(count: 32)
        let password = Array(code.utf8).map { Int8(bitPattern: $0) }
        derived.withUnsafeMutableBytes { out in
            salt.withUnsafeBytes { saltBytes in
                _ = CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), password, password.count,
                                         saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                         CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), rounds,
                                         out.bindMemory(to: UInt8.self).baseAddress, 32)
            }
        }
        return derived
    }
}

private extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }

    init?(hex: String) {
        guard hex.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
