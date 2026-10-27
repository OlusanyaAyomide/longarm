import CoreMedia
import CryptoKit
import Foundation
import LiveKitWebRTC

/// Phones connecting over the internet: one WebRTC peer connection each, set up through the
/// rendezvous server (`RendezvousClient`) with offers signed by the phone's key (`PairedPhones`,
/// `SignedSignal`). It's direct when the two networks allow it, otherwise through the TURN relay;
/// either way end-to-end encrypted. Each carries the screen as a video track, and the same
/// messages as the home link (`LinkServer`) over a data channel, but nothing gets through until
/// the phone gives the join code or its ticket (`JoinCode`).
///
/// A phone that drops off keeps its place for a minute, so it can come back (an ICE restart, or a
/// fresh offer) without the session ending; after that it's closed.
///
/// A phone paired away from home introduces itself first (`enroll`): proof that it has the pairing
/// link, an HMAC with the pairing token over its id, the Mac's id and the time. The token itself
/// never travels. If it checks out the phone joins the paired phones and gets enrolled back.
///
/// Phone → Mac signals: offer {session, sdp}, candidate {session, candidate, sdpMid, sdpMLineIndex},
/// bye {session}. Mac → phone: answer {session, sdp}, candidate {…}, bye {session}. On the data
/// channel the Mac sends hello {mac, macId, needsCode: true}, the phone join {code | ticket}, the
/// Mac join {ok, ticket} or join {ok: false, error, needsCode}.
final class InternetLink: NSObject {
    static let comebackTime: TimeInterval = 60
    static let longestSide = 1920   // the encoder scales down further when the link needs it

    /// Display names of the phones in a session.
    var onPhonesChanged: (([String]) -> Void)?
    var onMessage: (([String: Any], _ reply: @escaping ([String: Any]) -> Void) -> Bool)?
    var onBinary: ((Data) -> Void)?
    var greeting: () -> [[String: Any]] = { [] }
    var macName = "Mac"
    var macId = ""
    /// The pairing token, which a phone proves it has to enroll from afar.
    var pairingToken: () -> String? = { nil }

    private let key: DeviceKey
    private let pairedPhones: PairedPhones
    private let joinCode: JoinCode
    private let rendezvous: RendezvousClient
    private let factory: LKRTCPeerConnectionFactory
    private let videoSource: LKRTCVideoSource
    private let capturer: LKRTCVideoCapturer
    private let videoTrack: LKRTCVideoTrack
    private var sessions: [String: Session] = [:]   // by phone id

    // The last screen frame, re-sent while the screen is still: the encoder needs input to send a
    // key frame when the phone asks for one, and to sharpen a picture that stopped changing.
    private let frameLock = NSLock()
    private var lastFrame: (pixels: CVPixelBuffer, at: Date)?
    private var repeater: Timer?

    init(key: DeviceKey, pairedPhones: PairedPhones, joinCode: JoinCode, rendezvous: RendezvousClient) {
        self.key = key
        self.pairedPhones = pairedPhones
        self.joinCode = joinCode
        self.rendezvous = rendezvous
        LKRTCInitializeSSL()
        factory = LKRTCPeerConnectionFactory(encoderFactory: LKRTCDefaultVideoEncoderFactory(),
                                             decoderFactory: LKRTCDefaultVideoDecoderFactory())
        videoSource = factory.videoSource(forScreenCast: true)
        capturer = LKRTCVideoCapturer(delegate: videoSource)
        videoTrack = factory.videoTrack(with: videoSource, trackId: "screen")
        super.init()
    }

    var hasSessions: Bool { !sessions.isEmpty }

    /// A screen frame (any thread). Only sent while some phone is in a session.
    func deliver(_ pixels: CVPixelBuffer) {
        frameLock.lock()
        lastFrame = (pixels, Date())
        frameLock.unlock()
        send(pixels)
    }

    private func send(_ pixels: CVPixelBuffer) {
        let width = CVPixelBufferGetWidth(pixels), height = CVPixelBufferGetHeight(pixels)
        let scale = min(1, Double(Self.longestSide) / Double(max(width, height)))
        videoSource.adaptOutputFormat(toWidth: Int32(Double(width) * scale) & ~1, height: Int32(Double(height) * scale) & ~1, fps: 30)
        let frame = LKRTCVideoFrame(buffer: LKRTCCVPixelBuffer(pixelBuffer: pixels), rotation: ._0,
                                    timeStampNs: Int64(CACurrentMediaTime() * 1_000_000_000))
        videoSource.capturer(capturer, didCapture: frame)
    }

    func broadcast(_ message: [String: Any]) {
        for session in sessions.values where session.joined { session.send(message) }
    }

    func disconnectAll() {
        for session in sessions.values { close(session, tellPhone: true) }
    }

    // MARK: - Signals from phones

    func handleSignal(from phoneId: String, data: [String: Any]) {
        guard let phoneKey = pairedPhones.key(of: phoneId),
              let signal = SignedSignal.open(data, from: phoneId, to: key.id, publicKey: phoneKey),
              let sessionId = signal["session"] as? String else {
            return DebugLog.write("internet: ignored a signal that isn't signed by a paired phone")
        }
        switch signal["kind"] as? String {
        case "offer":
            guard let sdp = signal["sdp"] as? String else { return }
            let session: Session
            if let existing = sessions[phoneId], existing.id == sessionId {
                session = existing   // an ICE restart: same session, new paths
            } else {
                if let old = sessions[phoneId] { close(old, tellPhone: false) }
                guard let fresh = makeSession(phoneId: phoneId, id: sessionId) else { return }
                session = fresh
            }
            answer(sdp, in: session)
        case "candidate":
            guard let session = sessions[phoneId], session.id == sessionId,
                  let candidate = signal["candidate"] as? String else { return }
            session.addRemote(LKRTCIceCandidate(sdp: candidate, sdpMLineIndex: Int32(signal["sdpMLineIndex"] as? Int ?? 0),
                                                sdpMid: signal["sdpMid"] as? String))
        case "bye":
            if let session = sessions[phoneId], session.id == sessionId { close(session, tellPhone: false) }
        default:
            break
        }
    }

    /// A newly paired phone, introducing itself over the internet. `data`: proof (base64), ts (ms), name.
    func enroll(from phoneId: String, key: Data, data: [String: Any]) {
        guard DeviceKey.id(of: key) == phoneId, let token = pairingToken(),
              let proof = (data["proof"] as? String).flatMap({ Data(base64Encoded: $0) }),
              let ts = data["ts"] as? Double, abs(Date().timeIntervalSince1970 - ts / 1000) < 10 * 60 else {
            return DebugLog.write("internet: ignored an introduction without a valid proof")
        }
        let message = Data("longarm-enroll-v1\n\(phoneId)\n\(self.key.id)\n\(Int64(ts))".utf8)
        guard HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: message, using: SymmetricKey(data: Data(token.utf8))) else {
            return DebugLog.write("internet: an introduction's proof didn't match the pairing (an old link?)")
        }
        let name = (data["name"] as? String).flatMap { $0.isEmpty ? nil : String($0.prefix(60)) } ?? "Phone"
        pairedPhones.add(key: key, name: name)   // lists it with the server too (AppDelegate)
        DebugLog.write("internet: \(name) paired from afar")
        guard let sealed = SignedSignal.seal(["kind": "enrolled", "session": ""], from: self.key.id, to: phoneId, key: self.key) else { return }
        rendezvous.send(to: phoneId, data: sealed)
    }

    private func makeSession(phoneId: String, id: String) -> Session? {
        let config = LKRTCConfiguration()
        var servers = [LKRTCIceServer(urlStrings: ["stun:stun.cloudflare.com:3478", "stun:stun.l.google.com:19302"])]
        if let turn = rendezvous.turn {
            servers.append(LKRTCIceServer(urlStrings: turn.urls, username: turn.username, credential: turn.credential))
        }
        config.iceServers = servers
        config.sdpSemantics = .unifiedPlan
        config.bundlePolicy = .maxBundle
        config.rtcpMuxPolicy = .require
        config.continualGatheringPolicy = .gatherContinually   // switch to a better path if one shows up
        let session = Session(link: self, phoneId: phoneId, id: id,
                              name: pairedPhones.phones.first { $0.id == phoneId }?.name ?? "Phone")
        let constraints = LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let connection = factory.peerConnection(with: config, constraints: constraints, delegate: session) else { return nil }
        session.connection = connection
        sessions[phoneId] = session
        DebugLog.write("internet: \(session.name) is connecting")
        return session
    }

    private func answer(_ sdp: String, in session: Session) {
        guard let connection = session.connection else { return }
        connection.setRemoteDescription(LKRTCSessionDescription(type: .offer, sdp: sdp)) { [weak self] error in
            DispatchQueue.main.async {
                guard let self, error == nil else { return DebugLog.write("internet: bad offer (\(error?.localizedDescription ?? ""))") }
                session.remoteDescriptionSet()
                // The phone only receives video: send the screen on its video transceiver.
                for transceiver in connection.transceivers where transceiver.mediaType == .video {
                    transceiver.sender.track = self.videoTrack
                    transceiver.setDirection(.sendOnly, error: nil)
                    let parameters = transceiver.sender.parameters
                    parameters.degradationPreference = NSNumber(value: LKRTCDegradationPreference.maintainResolution.rawValue)
                    for encoding in parameters.encodings { encoding.maxBitrateBps = NSNumber(value: 6_000_000) }
                    transceiver.sender.parameters = parameters
                }
                let constraints = LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
                connection.answer(for: constraints) { answer, error in
                    guard let answer else { return DebugLog.write("internet: no answer (\(error?.localizedDescription ?? ""))") }
                    connection.setLocalDescription(answer) { _ in
                        DispatchQueue.main.async {
                            self.signal(session, ["kind": "answer", "sdp": answer.sdp])
                        }
                    }
                }
            }
        }
    }

    fileprivate func signal(_ session: Session, _ fields: [String: Any]) {
        var fields = fields
        fields["session"] = session.id
        guard let sealed = SignedSignal.seal(fields, from: key.id, to: session.phoneId, key: key) else { return }
        rendezvous.send(to: session.phoneId, data: sealed)
    }

    // MARK: - Sessions

    fileprivate func join(_ session: Session, code: String?, ticket: String?) {
        switch joinCode.attempt(code: code, ticket: ticket) {
        case .admitted(let ticket):
            DebugLog.write("internet: \(session.name) joined")
            session.joined = true
            session.ticket = ticket
            session.send(["type": "join", "ok": true, "ticket": ticket])
            for message in greeting() { session.send(message) }
            startRepeating()
            notifyPhonesChanged()
        case .refused(let reason, let needsCode):
            DebugLog.write("internet: \(session.name) not let in: \(reason)")
            session.send(["type": "join", "ok": false, "error": reason, "needsCode": needsCode])
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.close(session, tellPhone: false) }
        }
    }

    fileprivate func received(_ message: [String: Any], in session: Session) {
        switch message["type"] as? String {
        case "hello":
            if let name = message["device"] as? String, !name.isEmpty { session.name = name }
        case "join" where !session.joined:
            join(session, code: message["code"] as? String, ticket: message["ticket"] as? String)
        default:
            guard session.joined else { return }
            if let ticket = session.ticket { joinCode.used(ticket: ticket) }
            _ = onMessage?(message) { [weak session] reply in session?.send(reply) }
        }
    }

    fileprivate func receivedBinary(_ data: Data, in session: Session) {
        if session.joined { onBinary?(data) }
    }

    fileprivate func close(_ session: Session, tellPhone: Bool) {
        guard sessions[session.phoneId] === session else { return }
        if tellPhone { signal(session, ["kind": "bye"]) }
        sessions[session.phoneId] = nil
        if let ticket = session.ticket { joinCode.used(ticket: ticket) }   // the 10 minutes start when it leaves
        session.end()
        DebugLog.write("internet: \(session.name)'s session ended")
        if sessions.isEmpty { stopRepeating() }
        notifyPhonesChanged()
    }

    private func notifyPhonesChanged() {
        onPhonesChanged?(sessions.values.filter(\.joined).map { "\($0.name) (internet)" }.sorted())
    }

    private func startRepeating() {
        guard repeater == nil else { return }
        repeater = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.frameLock.lock()
            let still = self.lastFrame.flatMap { Date().timeIntervalSince($0.at) > 0.5 ? $0.pixels : nil }
            self.frameLock.unlock()
            if let still { self.send(still) }
        }
    }

    private func stopRepeating() {
        repeater?.invalidate()
        repeater = nil
        frameLock.lock()
        lastFrame = nil
        frameLock.unlock()
    }
}

/// One phone's peer connection. WebRTC calls its delegate methods on its own thread; everything
/// here hops to the main queue.
private final class Session: NSObject, LKRTCPeerConnectionDelegate, LKRTCDataChannelDelegate {
    let phoneId: String
    let id: String
    var name: String
    var connection: LKRTCPeerConnection?
    var joined = false
    var ticket: String?
    private weak var link: InternetLink?
    private var channel: LKRTCDataChannel?
    private var pendingCandidates: [LKRTCIceCandidate] = []
    private var hasRemoteDescription = false
    private var comeback: DispatchWorkItem?

    init(link: InternetLink, phoneId: String, id: String, name: String) {
        self.link = link
        self.phoneId = phoneId
        self.id = id
        self.name = name
    }

    func send(_ message: [String: Any]) {
        guard let channel, channel.readyState == .open, let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        channel.sendData(LKRTCDataBuffer(data: data, isBinary: false))
    }

    func remoteDescriptionSet() {
        hasRemoteDescription = true
        for candidate in pendingCandidates { connection?.add(candidate) { _ in } }
        pendingCandidates = []
    }

    func addRemote(_ candidate: LKRTCIceCandidate) {
        if hasRemoteDescription { connection?.add(candidate) { _ in } } else { pendingCandidates.append(candidate) }
    }

    func end() {
        comeback?.cancel()
        channel?.close()
        connection?.close()
        connection = nil
    }

    // MARK: LKRTCPeerConnectionDelegate

    func peerConnection(_ peerConnection: LKRTCPeerConnection, didGenerate candidate: LKRTCIceCandidate) {
        DispatchQueue.main.async {
            self.link?.signal(self, ["kind": "candidate", "candidate": candidate.sdp, "sdpMid": candidate.sdpMid ?? "",
                                     "sdpMLineIndex": Int(candidate.sdpMLineIndex)])
        }
    }

    func peerConnection(_ peerConnection: LKRTCPeerConnection, didOpen dataChannel: LKRTCDataChannel) {
        DispatchQueue.main.async {
            self.channel = dataChannel
            dataChannel.delegate = self
            if dataChannel.readyState == .open { self.channelOpened() }
        }
    }

    func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCIceConnectionState) {
        DispatchQueue.main.async {
            switch newState {
            case .connected, .completed:
                self.comeback?.cancel()
                self.comeback = nil
            case .disconnected, .failed:
                // Give the phone a minute to come back (it restarts ICE, or sends a fresh offer).
                guard self.comeback == nil else { return }
                DebugLog.write("internet: lost \(self.name), waiting for it to come back")
                let comeback = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.link?.close(self, tellPhone: true)
                }
                self.comeback = comeback
                DispatchQueue.main.asyncAfter(deadline: .now() + InternetLink.comebackTime, execute: comeback)
            default:
                break
            }
        }
    }

    func peerConnection(_ peerConnection: LKRTCPeerConnection, didChangeLocalCandidate local: LKRTCIceCandidate,
                        remoteCandidate remote: LKRTCIceCandidate, lastReceivedMs: Int32, changeReason reason: String) {
        let relayed = local.sdp.contains(" typ relay") || remote.sdp.contains(" typ relay")
        DispatchQueue.main.async {
            DebugLog.write("internet: \(self.name) connected \(relayed ? "through the relay" : "directly")")
            self.send(["type": "path", "relay": relayed])
        }
    }

    func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange stateChanged: LKRTCSignalingState) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didAdd stream: LKRTCMediaStream) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didRemove stream: LKRTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: LKRTCPeerConnection) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCIceGatheringState) {}
    func peerConnection(_ peerConnection: LKRTCPeerConnection, didRemove candidates: [LKRTCIceCandidate]) {}

    // MARK: LKRTCDataChannelDelegate

    func dataChannelDidChangeState(_ dataChannel: LKRTCDataChannel) {
        DispatchQueue.main.async {
            if dataChannel.readyState == .open { self.channelOpened() }
        }
    }

    func dataChannel(_ dataChannel: LKRTCDataChannel, didReceiveMessageWith buffer: LKRTCDataBuffer) {
        let data = buffer.data, binary = buffer.isBinary
        DispatchQueue.main.async {
            guard let link = self.link else { return }
            if binary { return link.receivedBinary(data, in: self) }
            if let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { link.received(message, in: self) }
        }
    }

    private var greeted = false

    private func channelOpened() {
        guard !greeted, let link else { return }
        greeted = true
        send(["type": "hello", "mac": link.macName, "macId": link.macId, "needsCode": true])
        // Nothing until it gives the code, and not for long.
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self, !self.joined else { return }
            self.link?.close(self, tellPhone: true)
        }
    }
}
