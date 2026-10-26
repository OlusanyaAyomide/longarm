import Foundation
import Network

/// TLS WebSocket server the phone connects to. Only a phone holding the pairing token gets in (see
/// `Pairing`); the phone pins this Mac's certificate. Each way of connecting is switched on in the
/// menu and has its own listener:
/// - home: the local network (and USB through adb reverse), advertised over Bonjour as _longarm._tcp;
///   connections arriving over Tailscale are turned away.
/// - internet: only on this Mac's Tailscale address, and a phone must also give the join code
///   (see `JoinCode`) before it gets anything.
///
/// Messages are JSON with a `type`. The link's own: hello {mac, macId, needsCode, internet {host,
/// port}} to the phone and hello {device} back; join {code} from an internet phone, answered with
/// join {ok, ticket} or join {ok: false, error, needsCode}; a phone coming back sends join {ticket}
/// instead (see `JoinCode`); internet {host, port} when the internet address changes. The rest are listed
/// in `RemoteControl`. Video frames go to the phone and microphone audio comes back as binary messages.
final class LinkServer {
    static let serviceType = "_longarm._tcp"

    enum Network: String {
        case home, internet
    }

    /// Display names of the connected phones.
    var onPhonesChanged: (([String]) -> Void)?
    /// A listener stopped working (with why) or started again (nil).
    var onListenerProblem: ((Network, String?) -> Void)?
    /// Any other message, with a way to answer just that phone. Returns false if not handled.
    var onMessage: (([String: Any], _ reply: ([String: Any]) -> Void) -> Bool)?
    /// Binary messages from a phone (its microphone, see `RemoteControl`).
    var onBinary: ((Data) -> Void)?
    /// Messages sent to a phone right after it connects (the current state).
    var greeting: () -> [[String: Any]] = { [] }

    private struct Phone {
        let connection: NWConnection
        let network: Network
        var name = "Phone"
        var joined: Bool   // over the internet: once it gave the join code (or a ticket)
        var ticket: String?
    }

    /// The address and port internet connections come to, while that listener is on.
    private(set) var internet: (host: String, port: UInt16)?

    private let ports: [Network: UInt16]
    private let pairing: Pairing
    private let joinCode: JoinCode
    private let macName: String
    private var listeners: [Network: NWListener] = [:]
    private var phones: [ObjectIdentifier: Phone] = [:]
    private var framesInFlight: Set<ObjectIdentifier> = []
    private var waitingFrames: [ObjectIdentifier: [Data]] = [:]
    private var needKeyFrame: Set<ObjectIdentifier> = []   // phones that missed frames: they wait for a key frame
    private var frameStats = (since: Date(), sent: 0, skipped: 0, wait: 0.0)

    init(ports: [Network: UInt16], pairing: Pairing, joinCode: JoinCode, macName: String) {
        self.ports = ports
        self.pairing = pairing
        self.joinCode = joinCode
        self.macName = macName
    }

    /// Starts or stops listening on the local network; stopping drops the phones connected that way.
    func setHome(_ on: Bool) throws {
        guard on != (listeners[.home] != nil) else { return }
        stopListening(.home)
        guard on else { return }
        let listener = try NWListener(using: parameters(), on: NWEndpoint.Port(rawValue: ports[.home]!)!)
        listener.service = NWListener.Service(name: macName, type: Self.serviceType, domain: nil,
                                              txtRecord: NWTXTRecord(["id": pairing.macId]).data)
        startListening(listener, .home)
    }

    /// Listens for internet connections on `host` (the Tailscale address), or stops with nil.
    func setInternet(host: String?) throws {
        guard host != internet?.host else { return }
        stopListening(.internet)
        guard let host else { return }
        let port = ports[.internet]!
        let parameters = parameters()
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
        startListening(try NWListener(using: parameters), .internet)
        internet = (host, port)
        // Phones at home learn where to find the Mac when they're away.
        broadcast(["type": "internet", "host": host, "port": Int(port)])
    }

    private func startListening(_ listener: NWListener, _ network: Network) {
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.onListenerProblem?(network, nil)
            case .failed(let error): self?.onListenerProblem?(network, error.localizedDescription)
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection, network) }
        listener.start(queue: .main)
        listeners[network] = listener
    }

    private func stopListening(_ network: Network) {
        listeners.removeValue(forKey: network)?.cancel()
        if network == .internet { internet = nil }
        disconnect(network)
        onListenerProblem?(network, nil)
    }

    private func parameters() -> NWParameters {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, sec_identity_create(pairing.identity)!)
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)

        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10
        tcp.keepaliveInterval = 5
        tcp.keepaliveCount = 3

        let webSocket = NWProtocolWebSocket.Options()
        webSocket.autoReplyPing = true
        // Reject the upgrade unless the phone presents the pairing token.
        webSocket.setClientRequestHandler(.main) { [pairing] _, headers in
            let authorized = headers.contains {
                $0.name.caseInsensitiveCompare("Authorization") == .orderedSame && pairing.isValid(authorization: $0.value)
            }
            return NWProtocolWebSocket.Response(status: authorized ? .accept : .reject, subprotocol: nil)
        }

        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)
        parameters.allowLocalEndpointReuse = true
        return parameters
    }

    func broadcast(_ message: [String: Any]) {
        guard let data = Self.encode(message) else { return }
        for phone in phones.values where phone.joined { send(data, to: phone.connection) }
    }

    /// Video can't skip frames freely: each one builds on the last. So a few frames may wait while
    /// one goes out, and if the link falls further behind, that phone skips ahead to the next key
    /// frame. Returns true when a key frame is needed for that.
    static let maxWaitingFrames = 3

    /// Sends a video frame (binary, H.264, see `ScreenCapture`) to every phone.
    func broadcastFrame(_ data: Data, keyFrame: Bool) -> Bool {
        var wantKeyFrame = false
        for (id, phone) in phones where phone.joined {
            if keyFrame {
                needKeyFrame.remove(id)
                frameStats.skipped += waitingFrames[id]?.count ?? 0
                waitingFrames[id] = nil   // the key frame starts afresh; older ones would only delay it
            } else if needKeyFrame.contains(id) {
                frameStats.skipped += 1
                continue
            }
            if !framesInFlight.contains(id) {
                sendFrame(data, to: phone.connection)
            } else if (waitingFrames[id]?.count ?? 0) < Self.maxWaitingFrames {
                waitingFrames[id, default: []].append(data)
            } else {
                frameStats.skipped += 1 + (waitingFrames[id]?.count ?? 0)
                waitingFrames[id] = nil
                needKeyFrame.insert(id)
                wantKeyFrame = true
            }
        }
        let elapsed = Date().timeIntervalSince(frameStats.since)
        if elapsed >= 5 {
            DebugLog.write(String(format: "video link: %.1f/s sent, %.1f/s skipped (link busy), %.0f ms until handed to the network",
                                  Double(frameStats.sent) / elapsed, Double(frameStats.skipped) / elapsed,
                                  frameStats.sent > 0 ? frameStats.wait / Double(frameStats.sent) * 1000 : 0))
            frameStats = (Date(), 0, 0, 0)
        }
        return wantKeyFrame
    }

    /// Drop every phone, e.g. after the pairing token was reset.
    func disconnectAll() {
        for phone in phones.values { phone.connection.cancel() }
        phones.removeAll()
        notifyPhonesChanged()
    }

    /// Drop the phones connected one way, e.g. internet ones after the join code changed.
    func disconnect(_ network: Network) {
        for phone in phones.values where phone.network == network { drop(phone.connection) }
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection, _ network: Network) {
        if network == .home && Tailscale.isTailscale(connection.endpoint) {
            DebugLog.write("turned away \(connection.endpoint): over Tailscale, but not to the internet listener")
            return connection.cancel()
        }
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return connection.cancel() }
            switch state {
            case .ready:   // TLS and the authorized WebSocket upgrade are done
                let id = ObjectIdentifier(connection)
                self.phones[id] = Phone(connection: connection, network: network, joined: network == .home)
                var hello: [String: Any] = ["type": "hello", "mac": self.macName, "macId": self.pairing.macId,
                                            "needsCode": network == .internet]
                if let internet = self.internet { hello["internet"] = ["host": internet.host, "port": Int(internet.port)] }
                self.send(hello, to: connection)
                if network == .home {
                    self.welcome(connection)
                } else {   // nothing until it gives the code, and not for long
                    DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
                        if self?.phones[id]?.joined == false { self?.drop(connection) }
                    }
                }
                self.receive(on: connection)
            case .failed:   // includes upgrades rejected for a bad token
                connection.cancel()
            case .cancelled:
                self.drop(connection)
            default:
                break
            }
        }
        connection.start(queue: .main)
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self else { return }
            let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            if error != nil || metadata?.opcode == .close || (data == nil && metadata == nil) {
                self.drop(connection)
                return
            }
            if metadata?.opcode == .binary, let data { self.onBinary?(data) }
            if metadata?.opcode == .text, let data,
               let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                self.handle(message, from: connection)
            }
            self.receive(on: connection)
        }
    }

    private func welcome(_ connection: NWConnection) {
        notifyPhonesChanged()
        for message in greeting() { send(message, to: connection) }
    }

    private func handle(_ message: [String: Any], from connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        guard let phone = phones[id] else { return }
        switch message["type"] as? String {
        case "hello":
            if let name = message["device"] as? String, !name.isEmpty {
                phones[id]?.name = name
                if phone.joined { notifyPhonesChanged() }
            }
        case "join" where !phone.joined:
            join(phone, code: message["code"] as? String, ticket: message["ticket"] as? String)
        default:
            guard phone.joined else { return }
            if let ticket = phone.ticket { joinCode.used(ticket: ticket) }
            _ = onMessage?(message) { [weak self] reply in self?.send(reply, to: connection) }
        }
    }

    /// An internet phone gives the join code, or the ticket it got for it: it's in, or told why
    /// not and dropped. A ticket that has run out isn't a wrong code; the phone just asks for it.
    private func join(_ phone: Phone, code: String?, ticket: String?) {
        let id = ObjectIdentifier(phone.connection)
        let letIn = { (ticket: String) in
            self.phones[id]?.joined = true
            self.phones[id]?.ticket = ticket
            self.send(["type": "join", "ok": true, "ticket": ticket], to: phone.connection)
            self.welcome(phone.connection)
        }
        if let ticket, code == nil {
            if joinCode.admits(ticket: ticket) {
                DebugLog.write("\(phone.name) back over the internet with its ticket")
                return letIn(ticket)
            }
            return refuse(phone, "It's been more than 10 minutes. Enter the join code again.", needsCode: true)
        }
        let refusal: String
        switch joinCode.check(code ?? "") {
        case .accepted:
            DebugLog.write("\(phone.name) joined over the internet")
            return letIn(joinCode.issueTicket())
        case .wrong(let triesLeft):
            refusal = "Wrong code. \(triesLeft) \(triesLeft == 1 ? "try" : "tries") left before joining locks for 15 minutes."
        case .locked(let until):
            refusal = "Too many wrong codes. Try again after \(until.formatted(date: .omitted, time: .shortened))."
        case .notSet:
            refusal = "No join code is set on the Mac."
        }
        refuse(phone, refusal, needsCode: false)
    }

    private func refuse(_ phone: Phone, _ refusal: String, needsCode: Bool) {
        DebugLog.write("\(phone.name) not let in over the internet: \(refusal)")
        let data = Self.encode(["type": "join", "ok": false, "error": refusal, "needsCode": needsCode])!
        let context = NWConnection.ContentContext(identifier: "message", metadata: [NWProtocolWebSocket.Metadata(opcode: .text)])
        phone.connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { [weak self] _ in
            self?.drop(phone.connection)
        })
    }

    private func drop(_ connection: NWConnection) {
        guard let phone = phones.removeValue(forKey: ObjectIdentifier(connection)) else { return }
        if let ticket = phone.ticket { joinCode.used(ticket: ticket) }   // the 10 minutes start when it leaves
        framesInFlight.remove(ObjectIdentifier(connection))
        waitingFrames[ObjectIdentifier(connection)] = nil
        needKeyFrame.remove(ObjectIdentifier(connection))
        connection.cancel()
        notifyPhonesChanged()
    }

    private func notifyPhonesChanged() {
        onPhonesChanged?(phones.values.filter(\.joined).map { $0.network == .internet ? "\($0.name) (internet)" : $0.name }.sorted())
    }

    // MARK: - Sending

    private func send(_ message: [String: Any], to connection: NWConnection) {
        if let data = Self.encode(message) { send(data, to: connection) }
    }

    private func send(_ data: Data, to connection: NWConnection) {
        let context = NWConnection.ContentContext(identifier: "message",
                                                  metadata: [NWProtocolWebSocket.Metadata(opcode: .text)])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { [weak self] error in
            if error != nil { self?.drop(connection) }
        })
    }

    private func sendFrame(_ data: Data, to connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        framesInFlight.insert(id)
        let started = Date()
        let context = NWConnection.ContentContext(identifier: "frame",
                                                  metadata: [NWProtocolWebSocket.Metadata(opcode: .binary)])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.framesInFlight.remove(id)
            self.frameStats.sent += 1
            self.frameStats.wait += Date().timeIntervalSince(started)
            if error != nil { return self.drop(connection) }
            if self.phones[id] != nil, let next = self.waitingFrames[id]?.first {
                self.waitingFrames[id]?.removeFirst()
                self.sendFrame(next, to: connection)
            }
        })
    }

    private static func encode(_ message: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: message)
    }
}
