import CommonCrypto
import CryptoKit
import Foundation
import Security

/// The code a phone must give to join over the internet, on top of the pairing token: the owner
/// sets it on the Mac and types it on the phone. Kept in the Keychain as a salted PBKDF2 hash.
/// Five wrong codes in a row lock internet joins for 15 minutes.
///
/// After the right code the phone gets a ticket, so stepping away briefly doesn't mean typing it
/// again: the ticket lets it back in until 10 minutes pass without it being used (connected, or
/// sending input). Tickets live only in this Mac's memory, as hashes; a new code, Reset Pairing or
/// quitting Longarm cancels them all.
final class JoinCode {
    enum Check {
        case accepted
        case wrong(triesLeft: Int)
        case locked(until: Date)
        case notSet
    }

    static let lengths = 6...12
    static let ticketIdle: TimeInterval = 10 * 60
    private static let account = "internet-join-code"
    private static let rounds: UInt32 = 100_000
    private static let triesBeforeLock = 5
    private static let lockDuration: TimeInterval = 15 * 60

    private var wrongTries = 0
    private var lockedUntilDate: Date?
    private var tickets: [Data: Date] = [:]   // hash of the ticket → when it was last used

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
        cancelTickets()
    }

    enum Outcome {
        case admitted(ticket: String)
        case refused(String, needsCode: Bool)   // needsCode: the ticket ran out, which isn't a wrong code
    }

    /// A phone joining over the internet, with the code you typed or its ticket from last time.
    func attempt(code: String?, ticket: String?) -> Outcome {
        if let ticket, code == nil {
            return admits(ticket: ticket)
                ? .admitted(ticket: ticket)
                : .refused("It's been more than 10 minutes. Enter the join code again.", needsCode: true)
        }
        switch check(code ?? "") {
        case .accepted:
            return .admitted(ticket: issueTicket())
        case .wrong(let triesLeft):
            return .refused("Wrong code. \(triesLeft) \(triesLeft == 1 ? "try" : "tries") left before joining locks for 15 minutes.", needsCode: false)
        case .locked(let until):
            return .refused("Too many wrong codes. Try again after \(until.formatted(date: .omitted, time: .shortened)).", needsCode: false)
        case .notSet:
            return .refused("No join code is set on the Mac.", needsCode: false)
        }
    }

    // MARK: - Tickets

    /// A new ticket for a phone that just gave the right code.
    private func issueTicket() -> String {
        let ticket = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }.hex
        tickets[Self.digest(ticket)] = Date()
        return ticket
    }

    /// Whether [ticket] still lets a phone in; using it counts as activity.
    func admits(ticket: String) -> Bool {
        let key = Self.digest(ticket)
        guard let lastUsed = tickets[key], Date().timeIntervalSince(lastUsed) < Self.ticketIdle else {
            tickets[key] = nil
            return false
        }
        tickets[key] = Date()
        return true
    }

    /// The phone holding [ticket] is still at it (input, or just leaving).
    func used(ticket: String) {
        let key = Self.digest(ticket)
        if tickets[key] != nil { tickets[key] = Date() }
    }

    func cancelTickets() {
        tickets.removeAll()
    }

    private static func digest(_ ticket: String) -> Data {
        Data(SHA256.hash(data: Data(ticket.utf8)))
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
