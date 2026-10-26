import Foundation
import Network

/// TLS WebSocket server the phone connects to at home: on the local network (and USB through adb
/// reverse), advertised over Bonjour as _longarm._tcp. Only a phone holding the pairing token gets
/// in (see `Pairing`), the phone pins this Mac's certificate, and connections from outside the
/// local network (a VPN, say) are turned away. Away from home, phones connect over WebRTC instead
/// (`InternetLink`).
///
/// Messages are JSON with a `type`. The link's own: hello {mac, macId, key, rendezvous} to the
/// phone (the Mac's internet identity and server, see `DeviceKey`) and hello {device} back, then
/// phone-key {key} from the phone so it can connect over the internet later. The rest are listed in
/// `RemoteControl`. Video frames go to the phone and microphone audio comes back as binary messages.
final class LinkServer {
    static let serviceType = "_longarm._tcp"

    /// Display names of the connected phones.
    var onPhonesChanged: (([String]) -> Void)?
    /// The listener stopped working (with why) or started again (nil).
    var onListenerProblem: ((String?) -> Void)?
    /// A phone told us its internet key (SPKI DER), with its name.
    var onPhoneKey: ((Data, String) -> Void)?
    /// Added to every hello: what the phone needs to connect over the internet later.
    var helloExtras: () -> [String: Any] = { [:] }
    /// Any other message, with a way to answer just that phone. Returns false if not handled.
    var onMessage: (([String: Any], _ reply: ([String: Any]) -> Void) -> Bool)?
    /// Binary messages from a phone (its microphone, see `RemoteControl`).
    var onBinary: ((Data) -> Void)?
    /// Messages sent to a phone right after it connects (the current state).
    var greeting: () -> [[String: Any]] = { [] }

    private struct Phone {
        let connection: NWConnection
        var name = "Phone"
    }

    let port: UInt16
    private let pairing: Pairing
    private let macName: String
    private var listener: NWListener?
    private var phones: [ObjectIdentifier: Phone] = [:]
    private var framesInFlight: Set<ObjectIdentifier> = []
    private var waitingFrames: [ObjectIdentifier: [Data]] = [:]
    private var needKeyFrame: Set<ObjectIdentifier> = []   // phones that missed frames: they wait for a key frame
    private var frameStats = (since: Date(), sent: 0, skipped: 0, wait: 0.0)

    init(port: UInt16, pairing: Pairing, macName: String) {
        self.port = port
        self.pairing = pairing
        self.macName = macName
    }

    /// Starts or stops listening; stopping drops the connected phones.
    func setListening(_ on: Bool) throws {
        guard on != (listener != nil) else { return }
        listener?.cancel()
        listener = nil
        disconnectAll()
        onListenerProblem?(nil)
        guard on else { return }
        let listener = try NWListener(using: parameters(), on: NWEndpoint.Port(rawValue: port)!)
        listener.service = NWListener.Service(name: macName, type: Self.serviceType, domain: nil,
                                              txtRecord: NWTXTRecord(["id": pairing.macId]).data)
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.onListenerProblem?(nil)
            case .failed(let error): self?.onListenerProblem?(error.localizedDescription)
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: .main)
        self.listener = listener
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
        for phone in phones.values { send(data, to: phone.connection) }
    }

    /// Video can't skip frames freely: each one builds on the last. So a few frames may wait while
    /// one goes out, and if the link falls further behind, that phone skips ahead to the next key
    /// frame. Returns true when a key frame is needed for that.
    static let maxWaitingFrames = 3

    /// Sends a video frame (binary, H.264, see `ScreenCapture`) to every phone.
    func broadcastFrame(_ data: Data, keyFrame: Bool) -> Bool {
        var wantKeyFrame = false
        for (id, phone) in phones {
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

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        guard LocalNetwork.isLocal(connection.endpoint) else {
            DebugLog.write("turned away \(connection.endpoint): not on this Mac's network")
            return connection.cancel()
        }
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return connection.cancel() }
            switch state {
            case .ready:   // TLS and the authorized WebSocket upgrade are done
                self.phones[ObjectIdentifier(connection)] = Phone(connection: connection)
                self.notifyPhonesChanged()
                self.send(["type": "hello", "mac": self.macName, "macId": self.pairing.macId].merging(self.helloExtras()) { $1 },
                          to: connection)
                for message in self.greeting() { self.send(message, to: connection) }
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

    private func handle(_ message: [String: Any], from connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        switch message["type"] as? String {
        case "hello":
            if let name = message["device"] as? String, !name.isEmpty {
                phones[id]?.name = name
                notifyPhonesChanged()
            }
        case "phone-key":
            if let key = (message["key"] as? String).flatMap({ Data(base64Encoded: $0) }) {
                onPhoneKey?(key, phones[id]?.name ?? "Phone")
            }
        default:
            _ = onMessage?(message) { [weak self] reply in self?.send(reply, to: connection) }
        }
    }

    private func drop(_ connection: NWConnection) {
        guard phones.removeValue(forKey: ObjectIdentifier(connection)) != nil else { return }
        framesInFlight.remove(ObjectIdentifier(connection))
        waitingFrames[ObjectIdentifier(connection)] = nil
        needKeyFrame.remove(ObjectIdentifier(connection))
        connection.cancel()
        notifyPhonesChanged()
    }

    private func notifyPhonesChanged() {
        onPhonesChanged?(phones.values.map(\.name).sorted())
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
