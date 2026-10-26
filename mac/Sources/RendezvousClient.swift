import Foundation

/// This Mac's connection to the rendezvous server (`server/` in this repository) while internet
/// connections are on: it signs in with the Mac's `DeviceKey`, tells the server which paired
/// phones may reach it, and passes WebRTC connection setup to and from them (`InternetLink`). It
/// never carries the screen or input. Reconnects by itself.
final class RendezvousClient: NSObject, URLSessionWebSocketDelegate {
    enum Status: Equatable {
        case off
        case connecting
        case online
        case failed(String)
    }

    struct Turn {
        let urls: [String]
        let username: String
        let credential: String
    }

    var onStatus: ((Status) -> Void)?
    /// A message from a phone (still to be checked: see `SignedSignal`).
    var onSignal: ((_ from: String, _ data: [String: Any]) -> Void)?
    private(set) var status = Status.off
    /// Relay credentials, fresh from the server.
    private(set) var turn: Turn?

    private let key: DeviceKey
    private let allowed: () -> [String]
    private var url: URL?
    private var task: URLSessionWebSocketTask?
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
    private var backoff: TimeInterval = 1
    private var retry: DispatchWorkItem?
    private var pinger: Timer?

    init(key: DeviceKey, allowed: @escaping () -> [String]) {
        self.key = key
        self.allowed = allowed
    }

    func start(url: URL) {
        guard url != self.url || status == .off else { return }
        stop()
        self.url = url
        connect()
    }

    func stop() {
        url = nil
        retry?.cancel()
        pinger?.invalidate()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        turn = nil
        set(.off)
    }

    /// Sends [data] (a sealed `SignedSignal`) to the phone [to].
    func send(to: String, data: [String: Any]) {
        send(["type": "signal", "to": to, "data": data])
    }

    /// The paired phones changed: only these may reach the Mac.
    func updateAllowList() {
        if status == .online { send(["type": "allow", "ids": allowed()]) }
    }

    // MARK: - Connection

    private func connect() {
        guard let url else { return }
        set(.connecting)
        let task = session.webSocketTask(with: url)
        task.maximumMessageSize = 64 * 1024
        self.task = task
        task.resume()
        receive(on: task)
    }

    private func receive(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self, task === self.task else { return }
            switch result {
            case .failure(let error):
                self.lost(task, reason: error.localizedDescription)
            case .success(let message):
                if case .string(let text) = message,
                   let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
                    self.handle(object)
                }
                self.receive(on: task)
            }
        }
    }

    private func handle(_ message: [String: Any]) {
        switch message["type"] as? String {
        case "challenge":
            guard let nonce = message["nonce"] as? String,
                  let signature = try? key.sign(Data("longarm-rendezvous-v1\n\(nonce)\nmac".utf8)) else { return }
            send(["type": "hello", "role": "mac", "key": key.publicKey.base64EncodedString(),
                  "sig": signature.base64EncodedString(), "allow": allowed()])
        case "ready":
            readTurn(message["turn"])
            backoff = 1
            set(.online)
            pinger?.invalidate()
            pinger = Timer.scheduledTimer(withTimeInterval: 25, repeats: true) { [weak self] _ in
                guard let task = self?.task else { return }
                task.sendPing { error in
                    if error != nil { DispatchQueue.main.async { self?.lost(task, reason: "the server stopped answering") } }
                }
            }
            // Relay credentials last an hour: refresh well before.
            Timer.scheduledTimer(withTimeInterval: 40 * 60, repeats: false) { [weak self] _ in self?.send(["type": "turn"]) }
        case "turn":
            readTurn(message["turn"])
        case "signal":
            if let from = message["from"] as? String, let data = message["data"] as? [String: Any] { onSignal?(from, data) }
        case "error":
            DebugLog.write("rendezvous: \(message["code"] as? String ?? "error")")
        default:
            break
        }
    }

    private func readTurn(_ value: Any?) {
        guard let turn = value as? [String: Any], let urls = turn["urls"] as? [String],
              let username = turn["username"] as? String, let credential = turn["credential"] as? String else { return }
        self.turn = Turn(urls: urls, username: username, credential: credential)
    }

    private func lost(_ task: URLSessionWebSocketTask, reason: String) {
        guard task === self.task, url != nil else { return }
        self.task = nil
        pinger?.invalidate()
        let code = task.closeCode.rawValue
        DebugLog.write("rendezvous: disconnected (\(code == 0 ? reason : "code \(code)"))")
        // Another Longarm signed in as this Mac (4001), or the server refused us (4002): don't fight it.
        if code == 4001 || code == 4002 { backoff = 60 }
        set(code == 4002 ? .failed("The internet server refused this Mac") : .failed("Can't reach the internet server"))
        let retry = DispatchWorkItem { [weak self] in self?.connect() }
        self.retry = retry
        DispatchQueue.main.asyncAfter(deadline: .now() + backoff, execute: retry)
        backoff = min(backoff * 2, 60)
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        lost(webSocketTask, reason: "closed")
    }

    private func send(_ message: [String: Any]) {
        guard let task, let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        task.send(.string(String(decoding: data, as: UTF8.self))) { _ in }
    }

    private func set(_ status: Status) {
        guard status != self.status else { return }
        self.status = status
        onStatus?(status)
    }
}

/// Connection setup between a phone and its Mac, signed end to end with their `DeviceKey`s so the
/// rendezvous server can pass it along but not forge or redirect it. A sealed message is
/// {payload: JSON text, sig: base64}; the payload names its kind, both devices and the time.
enum SignedSignal {
    private static func signed(_ payload: String) -> Data { Data("longarm-signal-v1\n\(payload)".utf8) }

    static func seal(_ fields: [String: Any], from: String, to: String, key: DeviceKey) -> [String: Any]? {
        var payload = fields
        payload["from"] = from
        payload["to"] = to
        payload["ts"] = Int(Date().timeIntervalSince1970 * 1000)
        guard let json = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: json, encoding: .utf8),
              let signature = try? key.sign(signed(text)) else { return nil }
        return ["payload": text, "sig": signature.base64EncodedString()]
    }

    /// The payload, if [publicKey] signed it, it's from [from] to [me], and it's recent.
    static func open(_ data: [String: Any], from: String, to me: String, publicKey: Data) -> [String: Any]? {
        guard let text = data["payload"] as? String,
              let signature = (data["sig"] as? String).flatMap({ Data(base64Encoded: $0) }),
              DeviceKey.isValid(signature, of: signed(text), by: publicKey),
              let payload = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              payload["from"] as? String == from, payload["to"] as? String == me,
              let ts = payload["ts"] as? Double,
              abs(Date().timeIntervalSince1970 - ts / 1000) < 10 * 60 else { return nil }
        return payload
    }
}
